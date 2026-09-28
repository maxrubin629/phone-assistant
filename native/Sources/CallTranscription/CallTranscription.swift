import AVFAudio
import CoreMedia
import Foundation
import Speech

public enum TranscribedSpeaker: String, Sendable {
    case caller, user
}

public struct TranscribedLine: Sendable, Equatable {
    public let speaker: TranscribedSpeaker
    public let text: String
    /// When the speech started, on the call's clock.
    public let at: Date
    public init(speaker: TranscribedSpeaker, text: String, at: Date) {
        self.speaker = speaker; self.text = text; self.at = at
    }
}

/// Transcribes the caller and the user's microphone as two separate streams, on
/// device, so each line is labeled by where its audio came from rather than
/// guessed from a mix. Audio arrives from the call's audio worker; `append`
/// copies and hands off, never blocking it. Unavailable before macOS 26, for an
/// unsupported language, or until that language's speech model is installed.
public final class CallTranscription: @unchecked Sendable {
    public static let sampleRate: Double = 24000
    /// Frames buffered per stream before the oldest are dropped (about 10 s).
    static let maximumPendingInputs = 500

    public let startedAt: Date
    private let streams: [TranscribedSpeaker: AnyObject]
    private let queue = DispatchQueue(label: "com.codexcall.transcription", qos: .utility)
    private let lock = NSLock()
    private var cursor: Int64 = 0
    private var finished = false

    private init(startedAt: Date, streams: [TranscribedSpeaker: AnyObject]) {
        self.startedAt = startedAt; self.streams = streams
    }

    /// Returns nil when on-device transcription can't run for this call. If the
    /// language is supported but its model isn't installed, asks the system to
    /// install it in the background so a later call can use it.
    public static func start(locale: Locale = .current,
                             onLine: @escaping @Sendable (TranscribedLine) -> Void) async -> CallTranscription? {
        guard #available(macOS 26.0, *) else { return nil }
        guard let session = await SpeechStreams.start(locale: locale) else { return nil }
        let startedAt = Date()
        let transcription = CallTranscription(startedAt: startedAt, streams: session.mapValues { $0 as AnyObject })
        for (speaker, stream) in session {
            stream.deliver { text, seconds in
                onLine(TranscribedLine(speaker: speaker, text: text, at: startedAt.addingTimeInterval(seconds)))
            }
        }
        return transcription
    }

    /// One tick of call audio at 24 kHz mono. A nil source wasn't authorized for
    /// the assistant this tick; its time still advances so later lines line up.
    public func append(caller: [Float]?, microphone: [Float]?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let start = cursor
        cursor += Int64(max(caller?.count ?? 0, microphone?.count ?? 0, 480))
        lock.unlock()
        guard #available(macOS 26.0, *) else { return }
        let streams = self.streams
        queue.async {
            if let caller, !caller.isEmpty { (streams[.caller] as? SpeechStream)?.feed(caller, at: start) }
            if let microphone, !microphone.isEmpty { (streams[.user] as? SpeechStream)?.feed(microphone, at: start) }
        }
    }

    /// True only for the first caller; later audio is ignored.
    private func markFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = !finished
        finished = true
        return first
    }

    /// Flushes pending speech into final lines. Bounded so ending a call never hangs.
    public func finish(timeout: TimeInterval = 4) async {
        guard markFinished(), #available(macOS 26.0, *) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in queue.async { continuation.resume() } }
        let streams = self.streams.values.compactMap { $0 as? SpeechStream }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await withTaskGroup(of: Void.self) { inner in
                for stream in streams { inner.addTask { await stream.finish() } }
            } }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await group.next()
            group.cancelAll()
        }
        for stream in streams { await stream.cancel() }
    }
}

@available(macOS 26.0, *)
enum SpeechStreams {
    static func start(locale requested: Locale) async -> [TranscribedSpeaker: SpeechStream]? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return nil }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            requestInstall(locale)
            return nil
        }
        var streams: [TranscribedSpeaker: SpeechStream] = [:]
        for speaker in [TranscribedSpeaker.caller, .user] {
            // Two same-language transcribers share one engine; if the system's
            // conservative limit still refuses the second, retry past it once.
            var stream = await SpeechStream.start(locale: locale, ignoresResourceLimits: false)
            if stream == nil, #available(macOS 27.0, *) {
                stream = await SpeechStream.start(locale: locale, ignoresResourceLimits: true)
            }
            if let stream {
                streams[speaker] = stream
            } else {
                for stream in streams.values { await stream.cancel() }
                return nil
            }
        }
        return streams
    }

    private static func requestInstall(_ locale: Locale) {
        Task.detached(priority: .background) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            try? await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall()
        }
    }
}

/// One analyzer and transcriber for one source. `feed` runs on the owning
/// CallTranscription's serial queue.
@available(macOS 26.0, *)
final class SpeechStream: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private var results: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, input: AsyncStream<AnalyzerInput>.Continuation,
                 converter: AVAudioConverter, sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        self.analyzer = analyzer; self.transcriber = transcriber; self.input = input
        self.converter = converter; self.sourceFormat = sourceFormat; self.targetFormat = targetFormat
    }

    static func start(locale: Locale, ignoresResourceLimits: Bool) async -> SpeechStream? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CallTranscription.sampleRate,
                                         channels: 1, interleaved: false) else { return nil }
        // Final results only: lines are written once, never revised.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: source),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        let (sequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(CallTranscription.maximumPendingInputs))
        let options: SpeechAnalyzer.Options
        if ignoresResourceLimits, #available(macOS 27.0, *) {
            options = .init(priority: .utility, modelRetention: .lingering, ignoresResourceLimits: true)
        } else {
            options = .init(priority: .utility, modelRetention: .lingering)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        do {
            try await analyzer.prepareToAnalyze(in: target)
            try await analyzer.start(inputSequence: sequence)
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            return nil
        }
        return SpeechStream(analyzer: analyzer, transcriber: transcriber, input: continuation,
                            converter: converter, sourceFormat: source, targetFormat: target)
    }

    func deliver(_ handler: @escaping @Sendable (String, TimeInterval) -> Void) {
        let transcriber = self.transcriber
        results = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let seconds = result.range.start.seconds
                    guard !text.isEmpty, seconds.isFinite else { continue }
                    handler(text, seconds)
                }
            } catch {
                // A failed analyzer ends only this stream's lines; the call continues.
            }
        }
    }

    /// Converts one tick to the analyzer's format and queues it at its call time.
    func feed(_ samples: [Float], at frame: Int64) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 32) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        let time = CMTime(value: frame, timescale: CMTimeScale(CallTranscription.sampleRate))
        input.yield(AnalyzerInput(buffer: output, bufferStartTime: time))
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        results?.cancel()
    }
}

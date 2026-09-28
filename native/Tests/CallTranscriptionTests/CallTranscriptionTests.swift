import AVFAudio
import CallTranscription
import Foundation
import XCTest

/// End to end through the real on-device recognizer: synthesized speech is fed
/// as caller audio and as microphone audio, and each line must come back with
/// the source it was fed on. Skips when this Mac can't run on-device
/// transcription for English (older macOS, or the model isn't installed).
final class CallTranscriptionTests: XCTestCase {
    func testEachSourceIsTranscribedAndLabeledSeparately() async throws {
        let collected = LineCollector()
        guard let session = await CallTranscription.start(locale: Locale(identifier: "en-US"), onLine: { collected.add($0) }) else {
            throw XCTSkip("On-device English transcription isn't available on this Mac.")
        }
        let caller = try await Self.speech("The earliest appointment we have is Tuesday morning at nine thirty.")
        let user = try await Self.speech("Please book the Tuesday appointment for Sam Lee.")
        let silence = [Float](repeating: 0, count: 24000)
        // Caller speaks, a pause, then the user speaks while the caller is silent.
        feed(session, caller: caller + silence, microphone: nil)
        feed(session, caller: silence + silence, microphone: silence + user)
        feed(session, caller: silence, microphone: silence)
        await session.finish(timeout: 30)

        let lines = collected.lines
        let callerText = lines.filter { $0.speaker == .caller }.map(\.text).joined(separator: " ").lowercased()
        let userText = lines.filter { $0.speaker == .user }.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(callerText.contains("tuesday"), "caller lines: \(callerText)")
        XCTAssertTrue(userText.contains("sam"), "user lines: \(userText)")
        XCTAssertFalse(callerText.contains("sam lee"), "user speech leaked into caller lines: \(callerText)")
        let firstCaller = try XCTUnwrap(lines.first { $0.speaker == .caller })
        let firstUser = try XCTUnwrap(lines.first { $0.speaker == .user })
        XCTAssertLessThan(firstCaller.at, firstUser.at, "lines should keep the order they were spoken")
    }

    private func feed(_ session: CallTranscription, caller: [Float]?, microphone: [Float]?) {
        let count = max(caller?.count ?? 0, microphone?.count ?? 0)
        var index = 0
        while index < count {
            let end = min(index + 480, count)
            session.append(caller: caller.map { Array($0[min(index, $0.count)..<min(end, $0.count)]) },
                           microphone: microphone.map { Array($0[min(index, $0.count)..<min(end, $0.count)]) })
            index = end
        }
    }

    /// Renders text with the system voice to 24 kHz mono float samples.
    private static func speech(_ text: String) async throws -> [Float] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        let samples = LineCollector.Samples()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var converter: AVAudioConverter?
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !finished { finished = true; done.resume() }
                    return
                }
                if converter == nil { converter = AVAudioConverter(from: pcm.format, to: target) }
                let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * 24000 / pcm.format.sampleRate) + 64)!
                var supplied = false
                _ = converter?.convert(to: out, error: nil) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return pcm
                }
                samples.append(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
            }
        }
        let result = samples.all
        guard result.count > 24000 else { throw XCTSkip("The system voice produced no audio.") }
        return result
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TranscribedLine] = []
    func add(_ line: TranscribedLine) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [TranscribedLine] { lock.lock(); defer { lock.unlock() }; return stored }

    final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Float] = []
        func append(_ values: [Float]) { lock.lock(); stored += values; lock.unlock() }
        var all: [Float] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

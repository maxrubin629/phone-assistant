import Darwin
import Foundation

/// Local diagnostics for one operator-led Phone test. Stores scalar levels and
/// lifecycle events only; never stores audio, model content, or call identity.
public struct PhoneTestReport: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case advancedTest, phoneBridge }
    public static let sampleLimit = 150
    /// First 75 meter windows (normally 15 seconds), retained for this run
    /// even after the recent window rolls forward.
    public static let startupSampleLimit = 75
    public static let eventLimit = 20
    public struct Readback: Codable, Equatable, Sendable {
        public let frames: UInt64
        public let zeroFrames: UInt64
        public let unavailableBlocks: UInt64
        public let peak: Double?
        public let rms: Double?
    }
    public struct Sample: Codable, Equatable, Sendable {
        public let time: Date
        public let elapsed: TimeInterval
        public let muted: Bool
        public let microphonePeak: Double
        public let callerPeak: Double
        public let renderedPhonePeak: Double
        public let renderedPhoneRMS: Double
        public let renderedPhoneFrames: UInt64
        public let microphoneCaptureFrames: UInt64
        public let callerCaptureFrames: UInt64
        public let microphoneOutputUnderrunFrames: UInt64
        public let agentOutputUnderrunFrames: UInt64
        public let droppedFrames: UInt64
        public let renderedPhoneDroppedTelemetryBlocks: UInt64
        /// Optional for old reports; nil levels mean no delivered input frames.
        public let phoneReadback: Readback?
        public let invalidScalarCount: Int
    }
    public struct Event: Codable, Equatable, Sendable {
        public let time: Date
        public let elapsed: TimeInterval
        public let state: String
        public let detail: String?
    }
    public private(set) var schemaVersion = 1
    public private(set) var id = UUID()
    public private(set) var startedAt: Date
    public private(set) var origin: Origin?
    public private(set) var nativePlayback: Bool
    public private(set) var microphoneEnabled: Bool
    public private(set) var microphoneGain: Double
    public private(set) var callerGain: Double
    public private(set) var liveTuning: CallAudioTuning?
    public private(set) var state = "starting"
    public private(set) var failureDetail: String?
    public private(set) var samples: [Sample] = []
    /// Missing in older reports. Stores scalar summaries, never PCM.
    public private(set) var startupSamples: [Sample]?
    public private(set) var events: [Event] = []

    public init(nativePlayback: Bool, microphoneEnabled: Bool, microphoneGain: Double, callerGain: Double,
                origin: Origin = .advancedTest) {
        startedAt = Date()
        self.origin = origin
        startupSamples = []
        self.nativePlayback = nativePlayback; self.microphoneEnabled = microphoneEnabled
        self.microphoneGain = Self.finiteLevel(microphoneGain)
        self.callerGain = Self.finiteLevel(callerGain)
        event("starting", now: startedAt)
    }
    public var isFinalized: Bool { state == "stopped" || state == "failed" }
    private func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }
    private static func finiteLevel(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }

    public mutating func append(meters: CallAudioMeters, muted: Bool, now: Date = Date()) {
        guard state == "starting" || state == "running" else { return }
        var values = [Double(meters.microphone), Double(meters.caller),
                      Double(meters.renderedPhonePeak), Double(meters.renderedPhoneRMS)]
        let hasReadback = meters.phoneReadbackFrames > 0
        if hasReadback { values += [Double(meters.phoneReadbackPeak), Double(meters.phoneReadbackRMS)] }
        let readback = Readback(frames: meters.phoneReadbackFrames,
            zeroFrames: meters.phoneReadbackZeroFrames, unavailableBlocks: meters.phoneReadbackUnavailableBlocks,
            peak: hasReadback ? Self.finiteLevel(Double(meters.phoneReadbackPeak)) : nil,
            rms: hasReadback ? Self.finiteLevel(Double(meters.phoneReadbackRMS)) : nil)
        let sample = Sample(time: now, elapsed: elapsed(at: now), muted: muted,
            microphonePeak: Self.finiteLevel(values[0]), callerPeak: Self.finiteLevel(values[1]),
            renderedPhonePeak: Self.finiteLevel(values[2]), renderedPhoneRMS: Self.finiteLevel(values[3]),
            renderedPhoneFrames: meters.renderedPhoneFrames,
            microphoneCaptureFrames: meters.microphoneCaptureFrames, callerCaptureFrames: meters.callerCaptureFrames,
            microphoneOutputUnderrunFrames: meters.microphoneOutputUnderrunFrames,
            agentOutputUnderrunFrames: meters.agentOutputUnderrunFrames,
            droppedFrames: meters.droppedFrames,
            renderedPhoneDroppedTelemetryBlocks: meters.renderedPhoneDroppedTelemetryBlocks,
            phoneReadback: readback,
            invalidScalarCount: values.filter { !$0.isFinite || $0 < 0 }.count)
        if let count = startupSamples?.count, count < Self.startupSampleLimit { startupSamples?.append(sample) }
        samples.append(sample)
        if samples.count > Self.sampleLimit { samples.removeFirst(samples.count - Self.sampleLimit) }
    }
    public mutating func event(_ state: String, detail: String? = nil, now: Date = Date()) {
        let next = String(state.prefix(48))
        let detail = detail.map { String($0.prefix(500)) }
        // Cleanup remains useful after failure, but cannot erase that failure
        // or permit a delayed running callback to reopen the report.
        if isFinalized && !["stopping", "stopped", "failed", "error"].contains(next) { return }
        if self.state == "stopping" && ["starting", "running"].contains(next) { return }
        events.append(Event(time: now, elapsed: elapsed(at: now), state: next, detail: detail))
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
        if next == "failed" || next == "error" {
            self.state = "failed"
            if failureDetail == nil { failureDetail = detail }
        } else if self.state != "failed", ["starting", "running", "stopping", "stopped"].contains(next) {
            if self.state != "stopping" || next == "stopped" { self.state = next }
        }
    }
    public mutating func setMicrophoneGain(_ gain: Double, now: Date = Date()) {
        guard !isFinalized, state != "stopping", gain.isFinite else { return }
        microphoneGain = min(4, max(0, gain))
        event("microphoneVolume", detail: String(format: "%.0f%%", microphoneGain * 100), now: now)
    }
    public mutating func setLiveTuning(_ value: CallAudioTuning, now: Date = Date()) {
        guard !isFinalized, state != "stopping" else { return }
        let value = value.normalized()
        liveTuning = value; microphoneGain = value[.microphoneToCaller]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let detail = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
        event("liveControls", detail: detail, now: now)
    }
    public mutating func setNativePlayback(_ enabled: Bool, now: Date = Date()) {
        guard !isFinalized, state != "stopping" else { return }
        nativePlayback = enabled
        event("callerPlayback", detail: enabled ? "Phone playback" : "App playback", now: now)
    }
    public var summary: String {
        let prefix = "Latest Phone test: \(state)."
        guard let last = samples.last else { return prefix + " No meter samples collected." }
        let peak = String(format: "%.3f", last.renderedPhonePeak)
        return prefix + " \(samples.count) samples; last local output peak \(peak); microphone underruns \(last.microphoneOutputUnderrunFrames) frames."
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
    fileprivate func validate() throws {
        func validTime(_ time: Date, _ elapsed: TimeInterval) -> Bool {
            time.timeIntervalSinceReferenceDate.isFinite && elapsed.isFinite && elapsed >= 0
        }
        func validLevel(_ value: Double) -> Bool { value.isFinite && value >= 0 }
        func validSample(_ sample: Sample) -> Bool {
            guard validTime(sample.time, sample.elapsed), (0...6).contains(sample.invalidScalarCount),
                  [sample.microphonePeak, sample.callerPeak, sample.renderedPhonePeak, sample.renderedPhoneRMS].allSatisfy(validLevel)
            else { return false }
            guard let readback = sample.phoneReadback else { return true }
            guard readback.zeroFrames <= readback.frames else { return false }
            if readback.frames == 0 { return readback.peak == nil && readback.rms == nil }
            return readback.peak.map(validLevel) == true && readback.rms.map(validLevel) == true
        }
        guard schemaVersion == 1, samples.count <= Self.sampleLimit, events.count <= Self.eventLimit,
              liveTuning.map({ $0 == $0.normalized() }) ?? true,
              (startupSamples?.count ?? 0) <= Self.startupSampleLimit,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              ["starting", "running", "stopping", "stopped", "failed"].contains(state),
              failureDetail == nil || state == "failed",
              failureDetail.map({ $0.count <= 500 }) ?? true,
              events.allSatisfy({ validTime($0.time, $0.elapsed) && $0.state.count <= 48 && ($0.detail.map { $0.count <= 500 } ?? true) }),
              samples.allSatisfy(validSample), (startupSamples ?? []).allSatisfy(validSample),
              validLevel(microphoneGain), validLevel(callerGain) else { throw PhoneTestReportStorage.Failure.invalidReport }
        if state != "failed", let phase = events.last(where: { ["starting", "running", "stopping", "stopped", "failed", "error"].contains($0.state) }) {
            guard phase.state == state else { throw PhoneTestReportStorage.Failure.invalidReport }
        }
    }
}

/// Keeps only the latest report. Call off the audio callback/worker; a storage
/// failure is diagnostic-only and must never stop a call.
public enum PhoneTestReportStorage {
    public static let maximumBytes = 256 * 1024
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CodexCall/Diagnostics/latest-phone-test.json")
    }
    /// Keep everyday calls separate from Advanced tests, including queued writes
    /// from one screen while the other starts. Old test reports remain readable.
    public static var bridgeURL: URL {
        defaultURL.deletingLastPathComponent().appendingPathComponent("latest-phone-bridge.json")
    }
    public enum Failure: Error, LocalizedError {
        case invalidReport, oversizedReport
        public var errorDescription: String? {
            switch self {
            case .invalidReport: return "The saved Phone test report is invalid."
            case .oversizedReport: return "The saved Phone test report exceeds its size limit."
            }
        }
    }
    private static func systemError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    public static func save(_ report: PhoneTestReport, to url: URL = defaultURL) throws {
        guard url.isFileURL else { throw Failure.invalidReport }
        let data = try report.encoded()
        guard data.count <= maximumBytes else { throw Failure.oversizedReport }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".phone-test-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw systemError() }
        var open = true
        defer {
            if open { Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw systemError() }
        try data.withUnsafeBytes { bytes in
            var position = 0
            while position < bytes.count {
                let result = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: position), bytes.count - position)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw systemError() }
                position += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw systemError() }
        let closeResult = Darwin.close(descriptor); open = false
        guard closeResult == 0 else { throw systemError() }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw systemError() }
    }

    public static func load(from url: URL = defaultURL) throws -> PhoneTestReport? {
        guard url.isFileURL else { throw Failure.invalidReport }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw systemError()
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw systemError() }
        guard attributes.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidReport }
        guard attributes.st_size <= maximumBytes else { throw Failure.oversizedReport }
        // Bound the read itself too, in case another writer grows the file.
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while data.count <= maximumBytes {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, maximumBytes + 1 - data.count))
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw systemError() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes else { throw Failure.oversizedReport }
        let report = try JSONDecoder().decode(PhoneTestReport.self, from: data)
        try report.validate()
        return report
    }
}

import Foundation

public enum CallAudioMode: String, Codable, CaseIterable, Sendable {
    case agent, join, takeOver, privateAside
    public var routes: CallAudioRoutes {
        switch self {
        case .agent: return [.agentToCaller, .callerToAgent, .callerToUser, .agentToUser]
        case .join: return .all
        case .takeOver: return [.microphoneToCaller, .callerToUser]
        case .privateAside: return [.microphoneToAgent, .callerToUser, .agentToUser]
        }
    }
}
public struct CallAudioRoutes: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let microphoneToCaller = Self(rawValue: 1 << 0)
    public static let agentToCaller = Self(rawValue: 1 << 1)
    public static let callerToAgent = Self(rawValue: 1 << 2)
    public static let microphoneToAgent = Self(rawValue: 1 << 3)
    public static let callerToUser = Self(rawValue: 1 << 4)
    public static let agentToUser = Self(rawValue: 1 << 5)
    public static let all = Self(rawValue: 63)
}
public enum CallAudioAudience: String, Codable, Sendable { case caller, owner }
public struct CallAudioConfiguration: Equatable, Sendable {
    public var virtualOutputUID: String
    public var microphoneUID: String?
    public var monitorOutputUID: String?
    public var microphoneEnabled: Bool
    public var mode: CallAudioMode
    /// True owns caller play-through. False leaves Phone's output untouched.
    public var manageCallerListening: Bool
    public var phoneRouting: PhoneRouting?
    public var requirePhoneInput: Bool
    var effectiveRoutes: CallAudioRoutes { phoneRouting?.routes ?? mode.routes }
    var usesMicrophone: Bool {
        microphoneEnabled && !effectiveRoutes.intersection([.microphoneToCaller, .microphoneToAgent]).isEmpty
    }
    var needsListeningDevice: Bool {
        if let phoneRouting {
            return phoneRouting.listener.includesUser && (manageCallerListening || phoneRouting.speaker.includesAgent)
        }
        return manageCallerListening || monitorOutputUID != nil || mode == .privateAside
    }
    public init(virtualOutputUID: String, microphoneUID: String? = nil,
                monitorOutputUID: String? = nil, microphoneEnabled: Bool = false,
                mode: CallAudioMode = .agent, manageCallerListening: Bool = true,
                phoneRouting: PhoneRouting? = nil, requirePhoneInput: Bool = false) {
        self.virtualOutputUID = virtualOutputUID; self.microphoneUID = microphoneUID
        self.monitorOutputUID = monitorOutputUID; self.microphoneEnabled = microphoneEnabled
        self.mode = mode; self.manageCallerListening = manageCallerListening
        self.phoneRouting = phoneRouting; self.requirePhoneInput = requirePhoneInput
    }
}
public struct CallAudioPacket: Sendable {
    public let pcm16: Data
    public let epoch: String
    public let startSample: UInt64
    public let sampleRate = 24000
}
public enum CallAudioStatus: Equatable, Sendable {
    case stopped, starting, ready, failed(String)
}
public struct CallAudioMeters: Sendable {
    /// Worker observation time, before UI delivery. Capture/output windows are
    /// asynchronously clocked; this timestamp does not imply sample alignment.
    public var measuredAt: Date
    public var caller: Float
    public var microphone: Float
    public var agent: Float
    public var droppedFrames: UInt64
    /// Sum of cumulative microphone/agent shortages while their caller routes
    /// are enabled. An unused source, caller mute and startup mute add none.
    public var outputUnderrunFrames: UInt64
    public var microphoneOutputUnderrunFrames: UInt64
    public var agentOutputUnderrunFrames: UInt64
    /// Capture frames drained by the worker during this meter interval. Peaks
    /// above cover this whole interval rather than only its final worker tick.
    public var microphoneCaptureFrames: UInt64
    public var callerCaptureFrames: UInt64
    /// Actual post-mix callback window, including silence, since the previous
    /// meter read. This is local virtual-output evidence, not caller reception.
    public var renderedPhonePeak: Float
    public var renderedPhoneRMS: Float
    public var renderedPhoneFrames: UInt64
    /// Cumulative dropped/unmeasurable scalar telemetry blocks. A positive
    /// interval delta means that interval's peak/RMS/frame count is incomplete.
    public var renderedPhoneDroppedTelemetryBlocks: UInt64
    /// Existing duplex callback's virtual input, before Phone processing.
    /// Zero frames means unavailable; zero samples with frames means silence.
    /// Input/output callback windows are not sample-aligned.
    public var phoneReadbackPeak: Float
    public var phoneReadbackRMS: Float
    public var phoneReadbackFrames: UInt64
    public var phoneReadbackZeroFrames: UInt64
    public var phoneReadbackUnavailableBlocks: UInt64
    public init(caller: Float = 0, microphone: Float = 0, agent: Float = 0,
                droppedFrames: UInt64 = 0, outputUnderrunFrames: UInt64 = 0,
                microphoneOutputUnderrunFrames: UInt64 = 0, agentOutputUnderrunFrames: UInt64 = 0,
                microphoneCaptureFrames: UInt64 = 0, callerCaptureFrames: UInt64 = 0,
                renderedPhonePeak: Float = 0, renderedPhoneRMS: Float = 0,
                renderedPhoneFrames: UInt64 = 0, renderedPhoneDroppedTelemetryBlocks: UInt64 = 0,
                phoneReadbackPeak: Float = 0, phoneReadbackRMS: Float = 0,
                phoneReadbackFrames: UInt64 = 0, phoneReadbackZeroFrames: UInt64 = 0,
                phoneReadbackUnavailableBlocks: UInt64 = 0,
                measuredAt: Date = Date()) {
        self.measuredAt = measuredAt
        self.caller = caller; self.microphone = microphone; self.agent = agent
        self.droppedFrames = droppedFrames; self.outputUnderrunFrames = outputUnderrunFrames
        self.microphoneOutputUnderrunFrames = microphoneOutputUnderrunFrames
        self.agentOutputUnderrunFrames = agentOutputUnderrunFrames
        self.microphoneCaptureFrames = microphoneCaptureFrames; self.callerCaptureFrames = callerCaptureFrames
        self.renderedPhonePeak = renderedPhonePeak; self.renderedPhoneRMS = renderedPhoneRMS
        self.renderedPhoneFrames = renderedPhoneFrames
        self.renderedPhoneDroppedTelemetryBlocks = renderedPhoneDroppedTelemetryBlocks
        self.phoneReadbackPeak = phoneReadbackPeak; self.phoneReadbackRMS = phoneReadbackRMS
        self.phoneReadbackFrames = phoneReadbackFrames; self.phoneReadbackZeroFrames = phoneReadbackZeroFrames
        self.phoneReadbackUnavailableBlocks = phoneReadbackUnavailableBlocks
    }
}

/// Worker-owned capture interval. Zero-valued samples still advance frames;
/// an absent callback does not. No audio is retained between worker ticks.
struct CaptureMeterWindow {
    private(set) var peak: Float = 0
    private(set) var frames: UInt64 = 0
    mutating func observe(_ samples: [Float]) {
        frames += UInt64(samples.count)
        for sample in samples where sample.isFinite { peak = max(peak, abs(sample)) }
    }
    mutating func reset() { peak = 0; frames = 0 }
}
public struct CallAudioError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Pure attribution policy; never broadens an ambiguous helper to system audio.
public struct CallAudioProcess: Equatable, Sendable {
    public var id: UInt32
    public var bundleID: String
    public var runningOutput: Bool
    public init(id: UInt32, bundleID: String, runningOutput: Bool) {
        self.id = id; self.bundleID = bundleID; self.runningOutput = runningOutput
    }
}
public enum CallAudioAttribution {
    public static func select(processes: [CallAudioProcess], phoneRunning: Bool,
                              faceTimeRunning: Bool) throws -> UInt32 {
        guard phoneRunning else { throw CallAudioError("Phone must be open with active audio before connecting audio.") }
        guard !faceTimeRunning else { throw CallAudioError("Phone and FaceTime share an audio helper. Quit FaceTime before connecting audio.") }
        let candidates = processes.filter {
            $0.runningOutput && ["com.apple.mobilephone", "com.apple.avconferenced"].contains($0.bundleID)
        }
        guard !candidates.isEmpty else {
            throw CallAudioError("Start or answer a call in Phone, then connect again.")
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw CallAudioError("Phone's audio cannot be isolated right now. Close other calling apps and try again.")
        }
        return candidate.id
    }
}

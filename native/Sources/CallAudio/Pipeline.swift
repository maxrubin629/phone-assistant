import Foundation

enum AudioBufferHealth {
    static func validate(overflowFrames: UInt64, workerDelay: TimeInterval,
                         captureBacklog: TimeInterval = 0) throws {
        guard overflowFrames == 0 else { throw CallAudioError("Audio queue overflowed. Audio stopped to avoid delayed or incomplete speech.") }
        guard workerDelay.isFinite, workerDelay >= 0, workerDelay <= 0.5 else {
            throw CallAudioError("Audio processing fell more than 500 ms behind. Audio stopped instead of replaying stale capture.")
        }
        guard captureBacklog.isFinite, captureBacklog >= 0, captureBacklog <= 0.5 else {
            throw CallAudioError("Captured audio is more than 500 ms behind its destination. Audio stopped; reconnect the selected devices.")
        }
    }
}

/// Pure generation/sequence policy, exercised without opening any device.
struct StreamGate {
    private(set) var epoch: String = ""
    private var lastSequence: UInt64?
    mutating func transition(to epoch: String) { self.epoch = epoch; lastSequence = nil }
    mutating func accept(epoch: String, sequence: UInt64) throws {
        guard !epoch.isEmpty, epoch == self.epoch else { throw CallAudioError("Discarded audio from a stale or disconnected epoch.") }
        if let lastSequence, sequence <= lastSequence { throw CallAudioError("Discarded duplicate or reordered agent audio.") }
        lastSequence = sequence
    }
}

/// A deterministic frame boundary shared by production and injected-sink tests.
/// Raw caller and microphone channels remain distinct until authorized routes
/// are applied; caller audio can never enter the Phone-send mix through here.
enum ModelFrameMixer {
    static func render(caller: [Float], microphone: [Float], frames: Int,
                       routes: CallAudioRoutes, callerGain: Float, microphoneGain: Float,
                       deliver: (Data) -> Void) {
        var mixed = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            if routes.contains(.callerToAgent), index < caller.count {
                let sample = caller[index] * callerGain
                if sample.isFinite { mixed[index] += sample }
            }
            if routes.contains(.microphoneToAgent), index < microphone.count {
                let sample = microphone[index] * microphoneGain
                if sample.isFinite { mixed[index] += sample }
            }
        }
        deliver(PCM24.encode(mixed))
    }
}

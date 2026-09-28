import CoreAudio
import CallAudioDSP
import Foundation

/// Requests system-audio access using a tap of this process only. The pilot is
/// written only to our virtual output; no physical speaker or microphone opens.
/// A successful tap allocation is not treated as permission: sampled pilot
/// energy must actually arrive before this reports success.
public final class AudioAccessProbe: @unchecked Sendable {
    private let controls = AudioControls()
    private let revision: UInt64
    private var output: OutputIO?
    private var input: InputIO?
    private var tap: CallerTap?
    public private(set) var cleanupFailed = false
    public init() { revision = cab_controls_revision(controls.pointer) }
    public func cancel() { cab_controls_cancel(controls.pointer) }

    public func run(timeout: TimeInterval = 45) throws -> Bool {
        guard cab_controls_revision(controls.pointer) == revision else { throw CallAudioError("Audio access check cancelled before starting.") }
        let device = try CallHardware.sendDevice("com.codexcall.audio.send.device")
        let processes = try CallHardware.list(kAudioHardwarePropertyProcessObjectList)
        let activeCall = processes.contains { id in
            let bundle = try? CallHardware.string(id, kAudioProcessPropertyBundleID)
            return ["com.apple.mobilephone", "com.apple.avconferenced", "com.apple.FaceTime"].contains(bundle ?? "") &&
                (try? CallHardware.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1
        }
        guard !activeCall else { throw CallAudioError("End the active Phone or FaceTime audio session before checking permissions.") }
        let mic = try AudioRing(generation: 1), pilot = try AudioRing(generation: 1)
        let captured = try AudioRing(generation: 1)
        let output = try OutputIO(device: device, kind: .phone, first: mic, second: pilot, controls: controls)
        self.output = output
        var result = false
        var originalError: Error?
        do {
            cab_controls_set_routes(controls.pointer, UInt32(CAB_ROUTE_AGENT_TO_CALLER))
            cab_controls_set_send_muted(controls.pointer, false)
            guard cab_controls_enable_if_revision(controls.pointer, revision) else { throw CallAudioError("Audio access check cancelled.") }
            try output.start()
            var pid = getpid(), process: AudioObjectID = 0
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = CallHardware.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            try CallHardware.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Locate permission-check audio process")
            guard process != kAudioObjectUnknown else { throw CallAudioError("Permission-check audio process is unavailable.") }
            let ownTap = CallerTap(process: process); self.tap = ownTap
            try ownTap.start(manageListening: false)
            let ownInput = try InputIO(device: ownTap.device, ring: captured); self.input = ownInput
            try ownInput.start()
            let until = ProcessInfo.processInfo.systemUptime + min(60, max(1, timeout))
            var phase = 0, signalFrames = 0
            while ProcessInfo.processInfo.systemUptime < until {
                guard cab_controls_revision(controls.pointer) == revision else { throw CallAudioError("Audio access check cancelled.") }
                let queued = cab_ring_queued_frames(pilot.pointer)
                if queued < 1920 {
                    let tone = (0..<960).map { Float(0.01 * sin(2 * Double.pi * 997 * Double(phase + $0) / 48000)) }
                    _ = pilot.write(tone, generation: 1); phase += tone.count
                }
                let samples = captured.read(8192, generation: 1)
                signalFrames += samples.filter { abs($0) > 0.001 }.count
                if signalFrames > Int(ownInput.format.mSampleRate * 0.1) { result = true; break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        } catch { originalError = error }
        try cleanup()
        if let originalError { throw originalError }
        return result
    }

    /// Call on the same worker after run returns. Failed owners stay retained so
    /// setup and application quit can retry cleanup instead of losing the error.
    public func cleanup() throws {
        cab_controls_cancel(controls.pointer)
        var cleanup: [String] = []
        do { try output?.close(); output = nil } catch { cleanup.append(error.localizedDescription) }
        do { try input?.close(); input = nil } catch { cleanup.append(error.localizedDescription) }
        do { try tap?.close(); tap = nil } catch { cleanup.append(error.localizedDescription) }
        cleanupFailed = !cleanup.isEmpty
        if !cleanup.isEmpty { throw CallAudioError("Audio check cleanup needs attention: " + cleanup.joined(separator: "; ")) }
    }
}

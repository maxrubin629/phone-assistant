import AppKit
import CallAudio
import Foundation

struct LiveHardwareLevel: Identifiable {
    let id: String
    let title: String
    let uid: String
    let input: Bool
    let level: HardwareAudioLevel?
}

extension PhoneBridgeStore {
    func setLevel(_ value: Double, path: CallAudioTuning.Path) {
        guard !busy, value.isFinite else { return }
        var next = tuning; next[path] = value; applyTuning(next)
    }
    func setPathMuted(_ value: Bool, path: CallAudioTuning.Path) {
        var next = tuning; next.setMuted(value, path: path); applyTuning(next)
    }
    func applyTuning(_ value: CallAudioTuning) {
        guard !busy else { return }
        tuning = value.normalized()
        runtime.setLiveTuning(tuning)
        UserDefaults.standard.set(microphoneGain, forKey: "phoneBridgeMicrophoneGain")
        if active { diagnosticReport?.setLiveTuning(tuning); saveDiagnosticReport() }
    }
    func chooseDevices(microphone: String, monitor: String) async {
        guard !busy else { return }
        guard await applyLiveRouteChange({ try $0.setPhysicalSelections(
            microphoneUID: microphone.isEmpty ? nil : microphone, monitorUID: monitor.isEmpty ? nil : monitor) }) else { return }
        selectedMicrophoneUID = microphone; selectedMonitorUID = monitor
        diagnosticReport?.event("deviceChoice", detail: "Microphone/output selection changed")
        saveDiagnosticReport(force: true)
        await refreshLiveControls()
    }
    func chooseNativePlayback(_ enabled: Bool) async {
        guard !busy, !enabled || routing.listener.includesUser else { return }
        guard await applyLiveRouteChange({ try $0.setNativeCallerPlayback(enabled) }) else { return }
        nativeCallerPlayback = enabled
        diagnosticReport?.setNativePlayback(enabled)
        saveDiagnosticReport(force: true)
    }
    func refreshLiveControls() async {
        guard !refreshingControls else { return }
        refreshingControls = true
        defer { refreshingControls = false }
        let micUID = selectedMicrophoneUID, monitorUID = selectedMonitorUID
        do {
            let result = try await control { _ -> ([AudioDevice], [LiveHardwareLevel]) in
                let devices = try Devices.list()
                let mic = micUID.isEmpty ? Devices.defaultDevice(input: true, from: devices) : devices.first { $0.uid == micUID }
                let monitor = monitorUID.isEmpty ? Devices.defaultDevice(input: false, from: devices) : devices.first { $0.uid == monitorUID }
                var specifications: [(String, String, String, Bool)] = []
                if let mic, mic.isPhysical { specifications.append(("mic", "Mac microphone · " + mic.name, mic.uid, true)) }
                if let monitor, monitor.isPhysical { specifications.append(("speakers", "Mac listening output · " + monitor.name, monitor.uid, false)) }
                specifications += [("virtualInput", "Phone Assistant input", ApplicationAudioRuntime.sendDeviceUID, true),
                                   ("virtualOutput", "Internal Phone feed", ApplicationAudioRuntime.feedDeviceUID, false)]
                return (devices, specifications.map { id, title, uid, input in
                    LiveHardwareLevel(id: id, title: title, uid: uid, input: input, level: try? HardwareAudioLevel.read(uid: uid, input: input))
                })
            }
            availableDevices = result.0; hardwareLevels = result.1
        } catch { controlMessage = error.localizedDescription }
    }
    func setHardware(_ row: LiveHardwareLevel, volume: Double? = nil, mute: Bool? = nil) async {
        guard !busy else { return }
        do {
            try await control { _ in
                if let volume { try HardwareAudioLevel.setVolume(volume, uid: row.uid, input: row.input) }
                if let mute { try HardwareAudioLevel.setMuted(mute, uid: row.uid, input: row.input) }
            }
            controlMessage = "Hardware setting applied."
            diagnosticReport?.event("hardwareControl", detail: row.id + (volume.map { " volume \(Int(($0 * 100).rounded()))%" } ?? " mute \(mute == true)"))
            saveDiagnosticReport()
            await refreshLiveControls()
        } catch { controlMessage = error.localizedDescription }
    }
    func markAudioFade() {
        diagnosticReport?.event("userMarkedFade", detail: "User marked the remote audio becoming quiet")
        saveDiagnosticReport(force: true)
        controlMessage = "Marked this moment in the local diagnostics."
    }
    func copyAudioDiagnostics() {
        guard let report = diagnosticReport, let data = try? report.encoded() else {
            controlMessage = "No connection report yet."; return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        controlMessage = "Copied level measurements and control changes. No recording or API key."
    }
}

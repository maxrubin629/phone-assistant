import AppKit
import CallAudio
import SwiftUI

struct PhoneLiveControlsView: View {
    @ObservedObject var bridge: PhoneBridgeStore
    @ObservedObject var assistant: AssistantStore
    private enum Section: String, CaseIterable { case levels = "Levels", processing = "Processing", devices = "Devices", routing = "Routing", hardware = "Hardware" }
    @State private var section = Section.levels
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bridge.active ? "Connected. Changes apply immediately." : "Disconnected. Levels and device choices apply when you connect.")
                    if !bridge.devices.isEmpty { Text(bridge.devices).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Toggle("Mute Caller Sending", isOn: Binding(get: { bridge.muted }, set: bridge.setMuted))
                    .toggleStyle(.button).disabled(!bridge.active)
            }
            meters
            Picker("Controls", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading) {
                    switch section {
                    case .levels: levels
                    case .processing: processing
                    case .devices: devices
                    case .routing: routingSection
                    case .hardware: hardware
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            HStack {
                Button("Mark Fade Now") { bridge.markAudioFade() }.disabled(!bridge.active)
                Button("Copy Diagnostics") { bridge.copyAudioDiagnostics() }
                Spacer()
                Button("Reset Levels and Limiter") { bridge.applyTuning(.init()) }.disabled(bridge.busy)
            }
            Text(bridge.controlMessage.isEmpty ? "No audio is recorded." : bridge.controlMessage)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !bridge.error.isEmpty { Text(bridge.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(20).frame(minWidth: 780, minHeight: 620)
            .task {
                while !Task.isCancelled {
                    await bridge.refreshLiveControls()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
    }
    private var meters: some View {
        GroupBox("Signal levels") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    signal("Microphone", peak: Double(bridge.liveMeters.microphone), rms: nil,
                           frames: bridge.liveMeters.microphoneCaptureFrames)
                    signal("Outgoing mix", peak: Double(bridge.liveMeters.renderedPhonePeak),
                           rms: Double(bridge.liveMeters.renderedPhoneRMS), frames: bridge.liveMeters.renderedPhoneFrames)
                    signal("Virtual input readback", peak: Double(bridge.liveMeters.phoneReadbackPeak),
                           rms: Double(bridge.liveMeters.phoneReadbackRMS), frames: bridge.liveMeters.phoneReadbackFrames)
                    signal("Caller", peak: Double(bridge.liveMeters.caller), rms: nil,
                           frames: bridge.liveMeters.callerCaptureFrames)
                }
                Text("Mic shortages \(bridge.liveMeters.microphoneOutputUnderrunFrames) frames · dropped measurements \(bridge.liveMeters.renderedPhoneDroppedTelemetryBlocks)")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private func signal(_ title: String, peak: Double, rms: Double?, frames: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            ProgressView(value: frames > 0 ? min(1, max(0, peak)) : 0)
                .accessibilityLabel(title + " level")
            Text(frames == 0 ? "No frames" : "Peak " + decibels(peak) + " dBFS")
                .font(.caption2).monospacedDigit()
            if let rms { Text(frames == 0 ? "RMS unavailable" : "RMS " + decibels(rms) + " dBFS").font(.caption2).monospacedDigit() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func decibels(_ value: Double) -> String {
        value > 0 && value.isFinite ? String(format: "%.1f", 20 * log10(value)) : "−∞"
    }
    private var levels: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Separate levels for each destination").font(.headline)
            Text("Routes not used by the current mode are dimmed. 100% is unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(CallAudioTuning.Path.allCases, id: \.self) { path in
                let unavailable = !bridge.routing.routes.contains(path.route)
                    || (bridge.nativeCallerPlayback && path == .callerToUser)
                HStack(spacing: 10) {
                    Text(path.title).frame(width: 205, alignment: .leading)
                    Slider(value: Binding(get: { bridge.tuning[path] }, set: { bridge.setLevel($0, path: path) }), in: 0...4, step: 0.05)
                        .accessibilityLabel(path.title + " volume")
                    Text("\(Int((bridge.tuning[path] * 100).rounded()))%")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                    Button("100%") { bridge.setLevel(1, path: path) }.accessibilityLabel("Reset " + path.title)
                    Toggle("Mute", isOn: Binding(get: { bridge.tuning.isMuted(path) }, set: { bridge.setPathMuted($0, path: path) }))
                        .toggleStyle(.checkbox).accessibilityLabel("Mute " + path.title)
                }.disabled(bridge.busy || unavailable)
            }
            if bridge.nativeCallerPlayback {
                Text("Phone is handling caller playback, so Caller → my speakers is inactive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var processing: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Outgoing peak limiter") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable peak limiter", isOn: Binding(get: { bridge.tuning.limiterEnabled }, set: {
                        var next = bridge.tuning; next.limiterEnabled = $0; bridge.applyTuning(next)
                    }))
                    Text("When off, peaks above full scale are clipped.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Ceiling").frame(width: 95, alignment: .leading)
                        Slider(value: Binding(get: { bridge.tuning.limiterCeiling }, set: {
                            var next = bridge.tuning; next.limiterCeiling = $0; bridge.applyTuning(next)
                        }), in: 0.1...0.999).accessibilityLabel("Limiter ceiling")
                        Text(String(format: "%.1f%%", bridge.tuning.limiterCeiling * 100)).monospacedDigit().frame(width: 70)
                    }.disabled(!bridge.tuning.limiterEnabled)
                    HStack {
                        Text("Release").frame(width: 95, alignment: .leading)
                        Slider(value: Binding(get: { bridge.tuning.limiterReleaseMS }, set: {
                            var next = bridge.tuning; next.limiterReleaseMS = $0; bridge.applyTuning(next)
                        }), in: 10...1000, step: 10).accessibilityLabel("Limiter release milliseconds")
                        Text("\(Int(bridge.tuning.limiterReleaseMS)) ms").monospacedDigit().frame(width: 70)
                    }.disabled(!bridge.tuning.limiterEnabled)
                    Button("Reset Limiter") {
                        var next = bridge.tuning; next.limiterEnabled = true; next.limiterCeiling = 0.98; next.limiterReleaseMS = 80
                        bridge.applyTuning(next)
                    }
                }.padding(10)
            }.disabled(bridge.busy)
            GroupBox("Caller playback comparison") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Let Phone handle caller playback", isOn: Binding(get: { bridge.nativeCallerPlayback }, set: {
                        enabled in Task { await bridge.chooseNativePlayback(enabled) }
                    })).disabled(bridge.busy || !bridge.routing.listener.includesUser)
                    Text("On: Phone plays the caller through its own output. Off: the caller plays through this app. Switching briefly pauses audio; the call stays connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            Text("This app adds no noise gate, gain control or echo cancellation; Phone and macOS may.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// Custom combinations beyond the notch's presets. Never silently mapped to a preset.
    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Who speaks and listens").font(.headline)
            routingPicker("Caller hears", speaker: true)
            routingPicker("Caller is heard by", speaker: false)
            Text(CallExperienceMode(routing: bridge.routing)?.detail ?? "Custom routing. The notch shows no preset as selected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func routingPicker(_ title: String, speaker: Bool) -> some View {
        Picker(title, selection: Binding(get: { speaker ? bridge.routing.speaker : bridge.routing.listener }, set: { next in
            let routing = speaker ? PhoneRouting(speaker: next, listener: bridge.routing.listener)
                : PhoneRouting(speaker: bridge.routing.speaker, listener: next)
            Task { await bridge.changeRouting(routing, profile: assistant.preferences) }
        })) {
            ForEach(PhoneParticipant.allCases, id: \.self) { Text($0.title).tag($0) }
        }.disabled(bridge.busy).frame(maxWidth: 360)
    }
    private var devices: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Device overrides for this session").font(.headline)
            devicePicker("Microphone", selection: bridge.selectedMicrophoneUID, input: true) { uid in
                await bridge.chooseDevices(microphone: uid, monitor: bridge.selectedMonitorUID)
            }
            devicePicker("App listening output", selection: bridge.selectedMonitorUID, input: false) { uid in
                await bridge.chooseDevices(microphone: bridge.selectedMicrophoneUID, monitor: uid)
            }
            Text("Automatic follows your Mac, including AirPods. A named device stays selected until you change it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Follow Mac for Both") { Task { await bridge.chooseDevices(microphone: "", monitor: "") } }.disabled(bridge.busy)
                Button("Refresh Devices") { Task { await bridge.refreshLiveControls() } }
                Button("Open Sound Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
            Text("Phone's microphone is selected automatically when connecting. Choose speakers or headphones in Phone for native playback.").font(.caption)
        }
    }
    private func devicePicker(_ label: String, selection: String, input: Bool, choose: @escaping (String) async -> Void) -> some View {
        let choices = bridge.availableDevices.filter { $0.isPhysical && (input ? $0.input : $0.output) }
        return Picker(label, selection: Binding(get: { selection }, set: { value in Task { await choose(value) } })) {
            Text("Automatic · follow Mac").tag("")
            ForEach(choices, id: \.uid) { Text($0.name).tag($0.uid) }
            if !selection.isEmpty && !choices.contains(where: { $0.uid == selection }) { Text("Selected device unavailable").tag(selection) }
        }.disabled(bridge.busy)
    }
    private var hardware: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Device hardware controls").font(.headline)
            Text("These change the device itself, so other apps are affected too.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(bridge.hardwareLevels) { row in
                GroupBox(row.title) {
                    HStack {
                        if let volume = row.level?.volume {
                            Slider(value: Binding(get: { volume }, set: { value in
                                Task { await bridge.setHardware(row, volume: value) }
                            }), in: 0...1, step: 0.01).accessibilityLabel(row.title + " hardware volume")
                                .disabled(bridge.busy || row.level?.volumeWritable != true)
                            Text("\(Int((volume * 100).rounded()))%") .monospacedDigit().frame(width: 50)
                        } else { Text("Volume unavailable").foregroundStyle(.secondary); Spacer() }
                        if let muted = row.level?.muted {
                            Toggle("Mute", isOn: Binding(get: { muted }, set: { value in
                                Task { await bridge.setHardware(row, mute: value) }
                            })).toggleStyle(.checkbox).accessibilityLabel("Mute " + row.title)
                                .disabled(bridge.busy || row.level?.muteWritable != true)
                        }
                    }.padding(8)
                }
            }
            Button("Refresh Hardware Levels") { Task { await bridge.refreshLiveControls() } }
        }
    }
}

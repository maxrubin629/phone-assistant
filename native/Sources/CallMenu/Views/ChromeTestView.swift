import SwiftUI
import CallAudio

struct RoutingView: View {
    @ObservedObject var test: RoutingStore
    @ObservedObject var kit: PhoneKitStore
    let callActive: Bool
    let showSetup: () -> Void
    var openLiveControls: (() -> Void)? = nil
    private var locked: Bool { test.active || test.busy || callActive }

    var body: some View {
        Form {
            if let openLiveControls {
                Section {
                    LabeledContent {
                        Button("Open…", action: openLiveControls)
                    } label: {
                        Text("Live audio controls")
                        Text("Levels, devices and routing for the current call.")
                    }
                }
            }
            Section {
                Picker("Application", selection: Binding(get: { test.preferences.applicationID }, set: test.chooseApplication)) {
                    Text("Choose an application").tag("")
                    Text("Phone").tag(RoutingPreferences.phoneSourceID)
                    if !test.preferences.applicationID.isEmpty && !test.isPhoneTest && test.selectedApplication == nil {
                        Text("Unavailable: " + test.preferences.applicationName).tag(test.preferences.applicationID)
                    }
                    ForEach(test.sources) { source in
                        Text(source.name + (source.audioProcessIDs.isEmpty ? " · play audio first" : "")).tag(source.id)
                    }
                }.disabled(locked)
                Toggle("Include microphone", isOn: $test.preferences.microphoneEnabled).disabled(locked)
                Picker("Microphone", selection: Binding(get: { test.preferences.microphoneUID }, set: test.chooseMicrophone)) {
                    Text("Automatic · Follow Mac input").tag("")
                    if !test.preferences.microphoneUID.isEmpty && !test.devices.contains(where: { $0.uid == test.preferences.microphoneUID }) {
                        Text("Unavailable: " + test.preferences.microphoneName).tag(test.preferences.microphoneUID)
                    }
                    ForEach(test.devices.filter { $0.isPhysical && $0.input }) { Text($0.name).tag($0.uid) }
                }.disabled(locked || !test.preferences.microphoneEnabled)
                if test.preferences.microphoneEnabled && !kit.microphoneAuthorized {
                    Button("Enable Microphone in Audio Setup", action: showSetup)
                }
                HStack {
                    Spacer()
                    Button("Chrome + Microphone Preset") { test.useChromePreset() }.disabled(locked)
                    Button("Refresh") { test.refresh(); kit.refresh() }.disabled(locked)
                }
            } header: {
                Text("Test source")
            } footer: {
                FormFooter(test.isPhoneTest
                     ? "Start or answer a call in Phone first. Start selects Phone's microphone automatically. Keep Phone's output on speakers or headphones."
                     : "Includes all audio from that app, including its tabs. Use a separate app for the call. Automatic devices follow macOS, including changes during a call.")
            }
            Section {
                if !test.isPhoneTest { Toggle("Send application", isOn: $test.preferences.sourceToCaller) }
                Toggle("Send microphone", isOn: $test.preferences.microphoneToCaller)
                    .disabled(!test.preferences.microphoneEnabled)
            } header: {
                Text("To the caller · Phone Assistant")
            } footer: {
                FormFooter(test.isPhoneTest
                     ? "Only your microphone is sent. The caller's voice is never sent back to them."
                     : "Choose Phone Assistant as the microphone in your calling app.")
            }.disabled(locked)
            Section {
                if test.isPhoneTest {
                    Toggle("Let Phone handle caller playback", isOn: $test.preferences.usesNativePhonePlayback)
                }
                Picker("Listening output", selection: Binding(get: { test.preferences.monitorUID }, set: test.chooseMonitor)) {
                    Text("Automatic · Follow Mac output").tag("")
                    if !test.preferences.monitorUID.isEmpty && !test.devices.contains(where: { $0.uid == test.preferences.monitorUID }) {
                        Text("Unavailable: " + test.preferences.monitorName).tag(test.preferences.monitorUID)
                    }
                    ForEach(test.devices.filter { $0.isPhysical && $0.output }) { Text($0.name).tag($0.uid) }
                }.disabled(test.isPhoneTest && test.preferences.usesNativePhonePlayback)
                Toggle(test.isPhoneTest ? "Hear caller" : "Hear application", isOn: $test.preferences.listenToSource)
                    .disabled(test.isPhoneTest && test.preferences.usesNativePhonePlayback)
                if !test.isPhoneTest {
                    Toggle("Hear microphone", isOn: $test.preferences.listenToMicrophone)
                        .disabled(!test.preferences.microphoneEnabled)
                }
            } header: {
                Text("To you")
            } footer: {
                FormFooter(test.isPhoneTest
                     ? (test.preferences.usesNativePhonePlayback
                        ? "Phone controls the caller's listening output and volume. Stop before changing this."
                        : "The caller plays through this output while the test runs. Headphones prevent your microphone picking up the caller.")
                     : "Use headphones to hear your microphone without feedback. Call playback stays with your calling app.")
            }.disabled(locked)
            Section("Levels") {
                level(test.isPhoneTest ? "Caller listening volume" : "Application volume", value: $test.preferences.sourceGain, peak: test.sourcePeak)
                    .disabled(test.isPhoneTest && test.preferences.usesNativePhonePlayback)
                level("Microphone volume", value: $test.preferences.microphoneGain, peak: test.microphonePeak)
            }
            if test.isPhoneTest {
                Section {
                    LabeledContent("Rendered to Phone Assistant", value: "peak \(levelText(test.outputPeak)) · RMS \(levelText(test.outputRMS))")
                    LabeledContent("Microphone underruns", value: "\(test.underrunFrames) frames")
                    LabeledContent("Capture overflows", value: "\(test.droppedFrames)")
                    if test.active && test.outputFrames == 0 {
                        Text("No output measurements in the latest interval.").foregroundStyle(.secondary)
                    }
                    if test.telemetryDrops > 0 {
                        Text("Some output measurements were dropped. The trace may be incomplete.").foregroundStyle(.orange)
                    }
                    if !test.diagnosticSummary.isEmpty { Text(test.diagnosticSummary).foregroundStyle(.secondary) }
                    if !test.diagnosticError.isEmpty { Text(test.diagnosticError).foregroundStyle(.orange) }
                    HStack { Spacer(); Button("Copy Diagnostics") { test.copyPhoneDiagnostics() }.disabled(!test.hasPhoneDiagnostics) }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    FormFooter("Only the latest test's signal levels and status are saved. No audio, transcript or API key. These measurements don't prove what the caller hears.")
                }
            }
            Section {
                LabeledContent {
                    Label(test.active ? "Running" : "Stopped", systemImage: test.active ? "circle.fill" : "circle")
                        .foregroundStyle(test.active ? Color.green : .secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(test.status).fixedSize(horizontal: false, vertical: true)
                        if !test.deviceStatus.isEmpty { Text(test.deviceStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let availability = test.availability { Text(availability).foregroundStyle(.secondary) }
                if test.selectedApplication?.audioProcessIDs.isEmpty == true {
                    Text("Play audio in the selected app so it creates an audio process. Shared system renderers are not captured.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !test.error.isEmpty { Text(test.error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                ProgressView(value: Double(min(1, max(0, test.outputPeak))))
                    .accessibilityLabel(test.isPhoneTest ? "Rendered outgoing audio" : "Caller mix estimate")
                HStack {
                    if !kit.ready { Button("Open Audio Setup", action: showSetup) }
                    Spacer()
                    Toggle("Mute Sending", isOn: Binding(get: { test.muted }, set: { test.setMuted($0) }))
                        .toggleStyle(.button).disabled(!test.active || test.busy)
                    Button("Stop") { test.stop() }.disabled(!test.canStop)
                    Button(test.busy ? "Working…" : "Start Test") { Task { await test.start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!test.canStart || !kit.ready || kit.busy || kit.needsAudioCleanup || callActive)
                }
            } header: {
                Text("Audio test")
            } footer: {
                FormFooter(test.isPhoneTest
                     ? "For troubleshooting, without the assistant. Stop restores Phone's playback and microphone. No call is placed, and nothing is sent to the assistant."
                     : "For troubleshooting, without the assistant. The app's own playback is muted while routing; Stop restores it. No call is placed.")
            }
        }
        .formStyle(.grouped)
        .onAppear { test.beginDiscovery() }
        .onDisappear { test.endDiscovery(); if test.canStop { test.stop() } }
    }
    private func level(_ title: String, value: Binding<Double>, peak: Float) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                Slider(value: value, in: 0...4).accessibilityLabel(title)
                ProgressView(value: Double(min(1, max(0, peak)))).accessibilityLabel(title + " level")
            }.frame(width: 240)
        } label: {
            Text(title)
            Text(String(Int((value.wrappedValue * 100).rounded())) + "%").monospacedDigit()
        }
    }
    private func levelText(_ value: Float) -> String {
        value > 0 && value.isFinite ? String(format: "%.1f dBFS", 20 * log10(Double(value))) : "silent"
    }
}

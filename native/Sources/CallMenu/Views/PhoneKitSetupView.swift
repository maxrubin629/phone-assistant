import SwiftUI
import CallAutomation

/// Audio setup as a checklist. Used by Settings and the first onboarding step.
struct PhoneKitSetupView: View {
    @State private var phoneControlAuthorized = PhoneAutomationPermission.authorized
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var kit: PhoneKitStore
    let routingActive: Bool

    var body: some View {
        Form {
            Section {
                requirement("Phone Assistant Audio Bridge", icon: "cable.connector", complete: kit.ready,
                    detail: kit.ready ? "Installed and ready." : "Connects your microphone and assistant audio to Phone. Needs administrator approval; Mac audio briefly reconnects.",
                    note: kit.ready ? nil : kit.message) {
                    Button(kit.busy && !kit.checkingAudio ? "Enabling…" : (kit.status?.updateAvailable == true ? "Update" : "Enable")) { kit.install() }
                        .disabled(kit.busy || kit.needsAudioCleanup || routingActive || kit.status?.bundledValid != true)
                }
                requirement("System audio access", icon: "waveform", complete: kit.audioVerified,
                    detail: kit.audioVerified ? "Captures caller audio. Your screen is never captured." : kit.audioMessage) {
                    if kit.needsAudioCleanup {
                        Button("Retry Cleanup") { Task { _ = await kit.stopAudioAndWait() } }.disabled(kit.busy)
                    } else if kit.checkingAudio {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { kit.cancelAudioCheck() }
                        }
                    } else {
                        HStack(spacing: 10) {
                            Button("Privacy Settings") { kit.openAudioSettings() }.buttonStyle(.link)
                            Button("Enable") { kit.requestAudio() }
                                .disabled(!kit.ready || kit.busy || routingActive)
                        }
                    }
                }
                requirement("Automatic Phone microphone", icon: "cursorarrow.click", complete: phoneControlAuthorized,
                    detail: "Selects Phone Assistant as Phone's microphone when you connect, and restores your choice after.",
                    note: phoneControlAuthorized ? nil : "Turn on Phone Assistant in \(PhoneAutomationPermission.settingsPaneName).") {
                    Button("Allow") { PhoneAutomationPermission.request() }.disabled(routingActive)
                }
            } header: {
                Text("Required")
            }
            Section {
                requirement("Microphone", icon: "mic", complete: kit.microphoneAuthorized,
                    detail: kit.microphoneAuthorized ? "You can speak when you join a call." : "Needed only when you join or take over a call.") {
                    Button(kit.microphoneDenied ? "Review" : "Allow") { Task { await kit.requestMicrophone() } }
                        .disabled(kit.busy || routingActive)
                }
            } header: {
                Text("Optional")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !kit.error.isEmpty {
                        Label(kit.error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if routingActive { FormFooter("Audio is in use. Disconnect before changing setup.") }
                    HStack {
                        Spacer()
                        Button("Refresh Status") { refresh() }.disabled(kit.busy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { phoneControlAuthorized = PhoneAutomationPermission.authorized }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { phoneControlAuthorized = PhoneAutomationPermission.authorized }
        }
    }

    private func refresh() { kit.refresh(); phoneControlAuthorized = PhoneAutomationPermission.authorized }

    private func requirement<Action: View>(_ title: String, icon: String, complete: Bool, detail: String, note: String? = nil,
                                           @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium))
                .foregroundStyle(complete ? Color.green : Color.accentColor)
                .frame(width: 28, height: 28)
                .background((complete ? Color.green : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            if complete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                    .accessibilityLabel("Ready")
            } else {
                action()
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }
}

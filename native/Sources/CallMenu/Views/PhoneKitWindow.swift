import CallAutomation
import CallPreferences
import SwiftUI

/// Onboarding, then call history. Live call control is the notch; diagnostics live
/// in Settings. Both follow the system appearance and use standard controls.
struct PhoneKitWindow: View {
    @ObservedObject var kit: PhoneKitStore
    @ObservedObject var chrome: RoutingStore
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var bridge: PhoneBridgeStore
    @ObservedObject var history: CallHistoryStore
    @Environment(\.scenePhase) private var phase
    @State private var phoneControlAuthorized = PhoneAutomationPermission.authorized

    var body: some View {
        Group {
            if assistant.preferences.setupCompleted {
                CallHistoryView(history: history)
            } else {
                onboarding.frame(minWidth: 680, minHeight: 600)
            }
        }
            .onAppear { kit.refresh(); phoneControlAuthorized = PhoneAutomationPermission.authorized }
            .onChange(of: phase) { _, value in
                if value == .active { kit.refresh(); phoneControlAuthorized = PhoneAutomationPermission.authorized }
            }
            .onDisappear { if chrome.canStop { chrome.stop() }; kit.cancelAudioCheck() }
    }

    private var step: SetupStep { assistant.preferences.setupStep }
    private var stepIndex: Int { [SetupStep.permissions, .assistant, .introduction].firstIndex(of: step) ?? 0 }

    private var onboarding: some View {
        VStack(spacing: 0) {
            heading.padding(.top, 28).padding(.bottom, 4)
            Group {
                switch step {
                case .permissions:
                    PhoneKitSetupView(kit: kit, routingActive: chrome.canStop || bridge.canStop)
                case .assistant:
                    AssistantPreferencesView(preferences: $assistant.preferences)
                case .introduction:
                    AssistantIntroductionView(preferences: $assistant.preferences)
                }
            }
            .frame(maxWidth: 600)
            if step == .introduction {
                // Disclosed once, before the first call, rather than discovered in Settings.
                Label(history.preferences.saveTranscripts
                      ? "Calls are transcribed and kept on this Mac for \(history.preferences.retention == .forever ? "as long as you like" : "30 days"). You can change this in Settings → History."
                      : "Call transcripts aren't saved. You can change this in Settings → History.",
                      systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.bottom, 12)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Welcome")
    }

    private var heading: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(SiriPalette.iconGradient)
                .frame(height: 52)
                .accessibilityHidden(true)
            Text(title).font(.title.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
    }

    private var symbol: String {
        switch step {
        case .permissions: return "waveform"
        case .assistant: return "person.wave.2"
        case .introduction: return "text.bubble"
        }
    }
    private var title: String {
        switch step {
        case .permissions: return "Connect to Phone"
        case .assistant: return "Meet your assistant"
        case .introduction: return "How it introduces itself"
        }
    }
    private var subtitle: String {
        switch step {
        case .permissions: return "Allow the audio bridge and permissions once. Nothing else to download."
        case .assistant: return "Give your assistant a name and a voice for calls Codex makes."
        case .introduction: return "Choose what the other person hears first."
        }
    }

    private var permissionsReady: Bool {
        kit.ready && kit.audioVerified && phoneControlAuthorized && !kit.busy && !kit.needsAudioCleanup
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Step \(stepIndex + 1) of 3").foregroundStyle(.secondary)
            if let hint {
                Text("· " + hint.trimmingCharacters(in: CharacterSet(charactersIn: "."))).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if step != .permissions {
                Button("Back") { assistant.preferences.setupStep = step == .introduction ? .assistant : .permissions }
            }
            if step == .introduction && !kit.ready {
                Button("Review Audio") { assistant.preferences.setupStep = .permissions }
            }
            switch step {
            case .permissions:
                Button("Continue") { assistant.preferences.setupStep = .assistant }
                    .buttonStyle(.borderedProminent).disabled(!permissionsReady)
                    .keyboardShortcut(.defaultAction)
            case .assistant:
                Button("Continue") { assistant.preferences.setupStep = .introduction }
                    .buttonStyle(.borderedProminent)
                    .disabled(assistant.preferences.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            case .introduction:
                Button("Finish Setup") { assistant.preferences.completeSetup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(assistant.preferences.validationMessage != nil || !kit.ready || kit.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var hint: String? {
        switch step {
        case .permissions: return permissionsReady ? nil : "Finish the required items"
        case .assistant: return assistant.preferences.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give your assistant a name." : nil
        case .introduction:
            if let message = assistant.preferences.validationMessage { return message }
            return kit.ready ? nil : "Phone Assistant Audio Bridge needs attention."
        }
    }
}

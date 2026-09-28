import CallPreferences
import SwiftUI

struct AssistantPreferencesView: View {
    @Binding var preferences: AssistantPreferences
    var body: some View {
        Form {
            Section("Identity") {
                TextField("Assistant name", text: $preferences.name, prompt: Text("Alex"))
                TextField("Your name", text: $preferences.ownerName, prompt: Text("Optional"))
            }
            Section {
                Picker("Speaking style", selection: $preferences.voiceStyle) {
                    ForEach(VoiceStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Pace", selection: $preferences.pace) {
                    ForEach(SpeakingPace.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Voice")
            } footer: {
                FormFooter("Changes apply from the next call.")
            }
        }.formStyle(.grouped)
    }
}

struct AssistantIntroductionView: View {
    @Binding var preferences: AssistantPreferences
    var body: some View {
        Form {
            Section {
                Picker("Introduction", selection: $preferences.introduction) {
                    ForEach(IntroductionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.radioGroup).labelsHidden()
                    .accessibilityLabel("Introduction style")
                if preferences.introduction == .custom {
                    TextField("Custom introduction", text: $preferences.customIntroduction,
                              prompt: Text("Hi, I'm calling on Sam's behalf…"), axis: .vertical)
                        .lineLimit(3...6).labelsHidden()
                }
            } header: {
                Text("Opening line")
            } footer: {
                FormFooter("If asked, the assistant says it's an AI. It never claims to be you.")
            }
            Section("Preview") {
                Text(preferences.introductionPreview.isEmpty ? "Write an introduction above." : preferences.introductionPreview)
                    .foregroundStyle(preferences.introductionPreview.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            }
        }.formStyle(.grouped)
    }
}

/// Settings shows identity, voice and introduction as one pane; onboarding
/// keeps them as separate steps.
struct AssistantSettingsView: View {
    @Binding var preferences: AssistantPreferences
    var body: some View {
        Form {
            Section("Identity") {
                TextField("Assistant name", text: $preferences.name, prompt: Text("Alex"))
                TextField("Your name", text: $preferences.ownerName, prompt: Text("Optional"))
            }
            Section {
                Picker("Speaking style", selection: $preferences.voiceStyle) {
                    ForEach(VoiceStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Pace", selection: $preferences.pace) {
                    ForEach(SpeakingPace.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Voice")
            }
            Section {
                Picker("Introduction", selection: $preferences.introduction) {
                    ForEach(IntroductionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if preferences.introduction == .custom {
                    TextField("Custom introduction", text: $preferences.customIntroduction,
                              prompt: Text("Hi, I'm calling on Sam's behalf…"), axis: .vertical)
                        .lineLimit(3...6).labelsHidden()
                }
                LabeledContent("Preview") {
                    Text(preferences.introductionPreview.isEmpty ? "Write an introduction above." : preferences.introductionPreview)
                        .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Opening line")
            } footer: {
                FormFooter("Changes apply from the next call. If asked, the assistant says it's an AI and never claims to be you.")
            }
        }.formStyle(.grouped)
    }
}

/// Grouped-form footers read left-aligned, like System Settings.
struct FormFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

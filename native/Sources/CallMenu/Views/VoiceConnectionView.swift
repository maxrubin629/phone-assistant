import SwiftUI

/// The voice key and the Codex tool connection, together in one Settings tab.
struct ConnectionsSettingsView: View {
    @ObservedObject var bridge: PhoneBridgeStore
    var body: some View {
        Form {
            APIKeySection(bridge: bridge)
            CodexConnectionSection()
        }.formStyle(.grouped)
    }
}

struct APIKeySection: View {
    @ObservedObject var bridge: PhoneBridgeStore
    @State private var newKey = ""

    private var trimmedKey: String { newKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            LabeledContent("Status") {
                if bridge.keyAvailable {
                    Label(bridge.keySaved ? "Saved in Keychain" : "Added until you quit", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Not added").foregroundStyle(.secondary)
                }
            }
            SecureField(bridge.keyAvailable ? "Replace key" : "API key", text: $newKey, prompt: Text("sk-…"))
                .disabled(bridge.canStop)
                .onSubmit { useKey() }
            HStack {
                Spacer()
                if bridge.keyAvailable {
                    Button("Remove") { bridge.removeAPIKey(); newKey = "" }.disabled(bridge.canStop)
                }
                Button(bridge.keyAvailable ? "Replace Key" : "Use Key", action: useKey)
                    .buttonStyle(.borderedProminent).disabled(trimmedKey.isEmpty || bridge.canStop)
            }
        } header: {
            Text("OpenAI API key")
        } footer: {
            FormFooter(bridge.canStop
                ? "Disconnect call audio to change the key."
                : "Needed for the assistant's voice. Stored in your Keychain on this Mac. Just me works without a key.")
        }
        .onDisappear { newKey = "" }
    }

    private func useKey() {
        guard !trimmedKey.isEmpty, !bridge.canStop else { return }
        bridge.setAPIKey(trimmedKey)
        newKey = ""
    }
}

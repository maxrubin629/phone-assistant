import CallHistory
import SwiftUI

struct HistorySettingsView: View {
    @ObservedObject var history: CallHistoryStore
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Toggle("Save call transcripts", isOn: $history.preferences.saveTranscripts)
                Picker("Keep calls for", selection: $history.preferences.retention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Call history")
            } footer: {
                FormFooter("Transcripts stay on this Mac, and Codex can read them when a call's result isn't enough. With saving off, results, Codex questions and answers, and mode changes are still kept.")
            }
            Section {
                LabeledContent("Saved calls") {
                    HStack(spacing: 12) {
                        Text("\(history.records.count)").monospacedDigit().foregroundStyle(.secondary)
                        Button("Delete All…", role: .destructive) { confirmingDelete = true }
                            .disabled(history.records.allSatisfy { $0.id == history.liveID })
                    }
                }
            } footer: {
                if !history.error.isEmpty { Text(history.error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all saved calls?", isPresented: $confirmingDelete) {
            Button("Delete All", role: .destructive) { history.deleteAllFinished() }
        } message: {
            Text("Transcripts and results are removed from this Mac. A call in progress is kept. Codex tasks keep their own copies of results.")
        }
    }
}

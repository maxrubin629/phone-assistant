import AppKit
import CallHistory
import SwiftUI

/// Calls Codex made, with results and transcripts. Live control stays in the notch.
/// Standard macOS structure: a searchable sidebar, a content pane using semantic
/// colors in either appearance, and per-call commands as toolbar symbols.
struct CallHistoryView: View {
    @ObservedObject var history: CallHistoryStore
    @State private var selection: String?
    @State private var search = ""
    @State private var confirmingDelete: CallRecord?

    private var visible: [CallRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history.records }
        return history.records.filter { call in
            call.title.localizedCaseInsensitiveContains(query)
                || (call.summary?.localizedCaseInsensitiveContains(query) ?? false)
                || (call.phoneNumber?.contains(query) ?? false)
                || call.entries.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }
    private var selected: CallRecord? { selection.flatMap(history.record) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Self.days(visible), id: \.title) { day in
                    Section(day.title) {
                        ForEach(day.calls) { call in
                            CallHistoryRow(call: call).tag(call.id)
                                .contextMenu {
                                    Button("Open in Codex") { openCodex(call) }
                                        .disabled(UUID(uuidString: call.originThreadID) == nil)
                                    Button("Copy Transcript") { copy(call) }
                                    Divider()
                                    Button("Delete…", role: .destructive) { confirmingDelete = call }
                                        .disabled(call.outcome == .live)
                                }
                        }
                    }
                }
            }
            .frame(minWidth: 280)
            .navigationSplitViewColumnWidth(min: 280, ideal: 310, max: 420)
            .searchable(text: $search, placement: .sidebar, prompt: "Search calls")
            .overlay {
                if !history.records.isEmpty && visible.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            if let call = selected {
                CallDetailView(call: call).id(call.id)
            } else if history.records.isEmpty {
                ContentUnavailableView {
                    Label("No Calls Yet", systemImage: "phone")
                } description: {
                    Text("Ask Codex to make a call, for example:\n“\(Self.exampleRequest)”\nIts result and transcript appear here.")
                } actions: {
                    Button("Copy Example") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.exampleRequest, forType: .string)
                    }
                }
            } else {
                ContentUnavailableView("No Call Selected", systemImage: "text.bubble")
            }
        }
        .navigationTitle("Calls")
        .navigationSubtitle(history.records.isEmpty ? "" : "\(history.records.count) saved")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { selected.map(openCodex) } label: { Label("Open in Codex", systemImage: "arrow.up.forward.app") }
                    .help("Open the Codex task that made this call")
                    .disabled(selected.map { UUID(uuidString: $0.originThreadID) == nil } ?? true)
                Button { selected.map(copy) } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }
                    .help("Copy the transcript")
                    .disabled(selected == nil)
                Button { confirmingDelete = selected } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete this call")
                    .disabled(selected == nil || selected?.outcome == .live)
            }
        }
        .confirmationDialog("Delete “\(confirmingDelete?.title ?? "")”?",
                            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            presenting: confirmingDelete) { call in
            Button("Delete", role: .destructive) {
                if selection == call.id { selection = nil }
                history.delete(call.id)
            }
        } message: { _ in
            Text("The transcript and result are removed from this Mac. The Codex task keeps its own copy of the result.")
        }
        .onAppear { applyRequestedSelection() }
        .onChange(of: history.requestedSelection) { _, _ in applyRequestedSelection() }
        .onChange(of: history.records.first?.id) { _, first in
            // Follow a new call as it starts unless the user is reading another one.
            if selected == nil { selection = first }
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    static let exampleRequest = "Call the dentist at +1 415 555 0132 and book a cleaning next week, mornings if possible. Check with me before confirming."

    /// Sidebar sections, newest first: Today, Yesterday, then weekday or date.
    static func days(_ calls: [CallRecord], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, calls: [CallRecord])] {
        var sections: [(title: String, calls: [CallRecord])] = []
        for call in calls {
            let title: String
            if calendar.isDateInToday(call.startedAt) { title = "Today" }
            else if calendar.isDateInYesterday(call.startedAt) { title = "Yesterday" }
            else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: call.startedAt), to: calendar.startOfDay(for: now)).day, days < 7 {
                title = call.startedAt.formatted(.dateTime.weekday(.wide))
            } else {
                title = call.startedAt.formatted(.dateTime.month(.wide).day().year())
            }
            if sections.last?.title == title { sections[sections.count - 1].calls.append(call) }
            else { sections.append((title, [call])) }
        }
        return sections
    }

    private func applyRequestedSelection() {
        if let requested = history.requestedSelection { selection = requested; history.requestedSelection = nil }
        else if selection == nil { selection = history.records.first?.id }
    }

    private func copy(_ call: CallRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(call.transcriptText, forType: .string)
    }

    private func openCodex(_ call: CallRecord) {
        guard UUID(uuidString: call.originThreadID) != nil,
              let url = URL(string: "codex://threads/" + call.originThreadID) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Status uses a symbol and text as well as color.
private struct OutcomeLabel: View {
    let call: CallRecord
    var body: some View {
        switch call.outcome {
        case .live: Label("Live", systemImage: "waveform").foregroundStyle(.tint)
        case .ended: Label(call.duration.map(CallRecord.offset) ?? "Ended", systemImage: "clock")
        case .failed: Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .interrupted: Label("Interrupted", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

private struct CallHistoryRow: View {
    let call: CallRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(call.title).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 6)
                Text(call.startedAt, format: .dateTime.hour().minute())
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            // The result is what people scan for; status stands in until there is one.
            Group {
                if call.outcome == .failed || call.outcome == .interrupted || (call.outcome == .live && call.summary == nil) {
                    OutcomeLabel(call: call)
                } else if let summary = call.summary {
                    Text(summary).foregroundStyle(.secondary)
                } else {
                    Text("No result reported").foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline).lineLimit(2)
        }
        .padding(.vertical, 3)
    }
}

private struct CallDetailView: View {
    let call: CallRecord
    @State private var showsTask = false
    private let bottom = "bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    GroupBox {
                        Text(call.summary ?? (call.outcome == .live ? "The assistant hasn't reported a result yet." : "No result was reported."))
                            .foregroundStyle(call.summary == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    } label: {
                        Label("Result", systemImage: "checkmark.seal")
                    }
                    DisclosureGroup("Task from Codex", isExpanded: $showsTask) {
                        Text(call.task).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    Divider()
                    transcript
                    Color.clear.frame(height: 1).id(bottom)
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: call.entries.last?.text) { _, _ in
                if call.outcome == .live { proxy.scrollTo(bottom, anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(call.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 6) {
                if let number = call.phoneNumber { Text(number); Text("·") }
                Text(call.startedAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                Text("·")
                OutcomeLabel(call: call).labelStyle(.titleAndIcon)
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript").font(.headline)
            if !call.transcriptSaved {
                Label("Transcript saving was off for this call.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if call.entries.isEmpty {
                Text(call.outcome == .live ? "Waiting for someone to speak…" : "Nothing was transcribed.")
                    .foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(call.entries) { entry in
                    TranscriptEntryView(entry: entry, offset: CallRecord.offset(entry.at.timeIntervalSince(call.startedAt)))
                }
            }
            if call.mixesUserAndCaller {
                Text("“Caller or you” lines were transcribed while your microphone was on, so they can't be told apart.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// A conversation: the caller on the leading side, the assistant on the trailing
/// side in the accent color, and Codex exchanges as full-width notes.
private struct TranscriptEntryView: View {
    let entry: CallEntry
    let offset: String

    var body: some View {
        switch entry.kind {
        case .event:
            Text("\(entry.text) · \(offset)")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case .question, .answer:
            VStack(alignment: .leading, spacing: 4) {
                caption(entry.kind == .question ? "questionmark.bubble" : "arrowshape.turn.up.left")
                Text(entry.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        default:
            // Your side of the call (the assistant and you) sits on the trailing edge.
            let ours = entry.kind == .assistant || entry.kind == .user
            HStack {
                if ours { Spacer(minLength: 60) }
                VStack(alignment: ours ? .trailing : .leading, spacing: 3) {
                    caption(nil)
                    Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !ours { Spacer(minLength: 60) }
            }
        }
    }

    private var bubble: AnyShapeStyle {
        switch entry.kind {
        case .assistant: return AnyShapeStyle(.tint.opacity(0.16))
        case .user: return AnyShapeStyle(.fill.secondary)
        default: return AnyShapeStyle(.fill.tertiary)
        }
    }

    private func caption(_ symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(entry.kind.label).fontWeight(.medium)
            Text(offset).monospacedDigit().foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

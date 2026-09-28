import CallControl
import CallHistory
import Combine
import Foundation

/// Keeps the live call's full record in memory and writes what the user's
/// preferences allow. Transcript opt-out affects disk only; the live call keeps
/// its transcript until it ends so the window and Codex can read it meanwhile.
@MainActor final class CallHistoryStore: ObservableObject {
    @Published private(set) var records: [CallRecord] = []
    @Published var preferences: HistoryPreferences {
        didSet {
            guard preferences != oldValue else { return }
            preferences.save(to: defaults)
            if preferences.retention != oldValue.retention { prune() }
            if let live = liveID { scheduleWrite(live) }
        }
    }
    /// Set by the notch or menu to open the window on a specific call.
    @Published var requestedSelection: String?
    @Published private(set) var error = ""
    private(set) var liveID: String?
    private var openAssistant: (session: String, entry: UUID, last: Date)?
    private let files: CallHistoryFiles
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.codexcall.call-history", qos: .utility)
    private var pendingWrites: [String: DispatchWorkItem] = [:]
    private var pruneTimer: Timer?

    init(files: CallHistoryFiles = CallHistoryFiles(), defaults: UserDefaults = .standard) {
        self.files = files; self.defaults = defaults
        preferences = HistoryPreferences.load(from: defaults)
        records = files.loadAll().map { record in
            // A record still marked live belonged to a run that did not finish it.
            guard record.outcome == .live else { return record }
            var closed = record; closed.outcome = .interrupted
            try? files.save(closed)
            return closed
        }
        prune()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    func record(_ id: String) -> CallRecord? { records.first { $0.id == id } }
    var mostRecent: CallRecord? { records.first }

    func begin(_ session: PhoneSession) {
        if let existing = record(session.sessionID), existing.outcome == .live { liveID = existing.id; return }
        let call = CallRecord(id: session.sessionID, title: session.title, task: session.task,
            phoneNumber: session.phoneNumber, originThreadID: session.originThreadID, startedAt: Date())
        records.removeAll { $0.id == call.id }
        records.insert(call, at: 0)
        liveID = call.id
        scheduleWrite(call.id, immediately: true)
    }

    func speech(_ text: String, isAssistant: Bool, userMicrophoneHeard: Bool) {
        let kind: CallEntry.Kind = isAssistant ? .assistant : (userMicrophoneHeard ? .callerAndUser : .caller)
        editLive { $0.appendSpeech(text, kind: kind, at: Date()) }
    }

    /// With on-device transcription, the assistant's streaming deltas extend its
    /// current turn until it pauses, even when caller or "You" lines are placed
    /// between them by time.
    func assistantSpeech(_ text: String, session id: String) {
        let now = Date()
        edit(id) { call in
            if let open = openAssistant, open.session == id, now.timeIntervalSince(open.last) < 2,
               call.extend(open.entry, with: text) {
                openAssistant?.last = now
                return
            }
            let entry = CallEntry(kind: .assistant, text: text, at: now)
            call.insert(entry)
            openAssistant = (id, entry.id, now)
        }
    }

    /// A finalized on-device line for the caller or the user. Lines can arrive
    /// just after the call ends; they're kept only if transcripts are saved.
    func transcribed(_ kind: CallEntry.Kind, _ text: String, at date: Date, session id: String) {
        guard kind == .caller || kind == .user, let call = record(id) else { return }
        guard call.outcome == .live || (preferences.saveTranscripts && call.transcriptSaved) else { return }
        if kind == .user && call.isLikelyEcho(text, at: date) { return }
        edit(id) { $0.insert(CallEntry(kind: kind, text: text, at: date)) }
    }

    func note(_ kind: CallEntry.Kind, _ text: String, session id: String) {
        edit(id) { $0.append(CallEntry(kind: kind, text: text, at: Date())) }
    }

    func reportSummary(_ summary: String, session id: String) {
        edit(id) { $0.summary = summary }
    }

    func finish(_ id: String, outcome: CallRecord.Outcome) {
        edit(id, immediately: true) { call in
            guard call.outcome == .live else { return }
            call.outcome = outcome; call.endedAt = Date()
        }
        guard liveID == id else { return }
        liveID = nil; openAssistant = nil
        // After the call, memory matches what was saved.
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index] = records[index].persisted(keepingTranscript: preferences.saveTranscripts)
        }
    }

    func delete(_ id: String) {
        guard id != liveID else { return }
        pendingWrites.removeValue(forKey: id)?.cancel()
        records.removeAll { $0.id == id }
        let files = files
        queue.async { try? files.delete(id: id) }
    }

    func deleteAllFinished() {
        let ids = records.filter { $0.id != liveID }.map(\.id)
        for id in ids { pendingWrites.removeValue(forKey: id)?.cancel() }
        records.removeAll { $0.id != liveID }
        let files = files
        queue.async { for id in ids { try? files.delete(id: id) } }
    }

    func prune() {
        let now = Date(), retention = preferences.retention
        records.removeAll { $0.id != liveID && CallHistoryFiles.expired($0, retention: retention, now: now) }
        let files = files
        queue.async { files.prune(retention, now: now) }
    }

    private func editLive(_ change: (inout CallRecord) -> Void) {
        guard let liveID else { return }
        edit(liveID, change)
    }

    private func edit(_ id: String, immediately: Bool = false, _ change: (inout CallRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        scheduleWrite(id, immediately: immediately)
    }

    /// Streaming speech arrives many times a second; coalesce disk writes.
    private func scheduleWrite(_ id: String, immediately: Bool = false) {
        if immediately { write(id); return }
        guard pendingWrites[id] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.write(id) }
        }
        pendingWrites[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func write(_ id: String) {
        pendingWrites.removeValue(forKey: id)?.cancel()
        guard let call = record(id) else { return }
        let saved = call.persisted(keepingTranscript: preferences.saveTranscripts)
        let files = files
        queue.async { [weak self] in
            do { try files.save(saved) }
            catch {
                let message = "Could not save call history: " + error.localizedDescription
                Task { @MainActor in self?.error = message }
            }
        }
    }

    /// Quit waits for the last write so a finished call is on disk.
    func flush() async {
        for id in Array(pendingWrites.keys) { write(id) }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

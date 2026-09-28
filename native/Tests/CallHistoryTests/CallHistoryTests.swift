import CallHistory
import Foundation
import XCTest

final class CallHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func record(_ id: String = UUID().uuidString, startedAt: Date? = nil) -> CallRecord {
        CallRecord(id: id, title: "Dentist", task: "Ask about Tuesday.", phoneNumber: "+1 555 0100",
                   originThreadID: "thread-1", startedAt: startedAt ?? start)
    }
    private func temporaryFiles() -> CallHistoryFiles {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("call-history-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CallHistoryFiles(directory: directory)
    }

    func testStreamingDeltasCoalesceUntilTheSpeakerChanges() {
        var call = record()
        call.appendSpeech("Hi, I'm ", kind: .assistant, at: start)
        call.appendSpeech("Alex.", kind: .assistant, at: start.addingTimeInterval(1))
        call.appendSpeech("Hello", kind: .caller, at: start.addingTimeInterval(65))
        call.append(CallEntry(kind: .question, text: "Is Tuesday OK?", at: start.addingTimeInterval(70)))
        call.appendSpeech("Sure", kind: .caller, at: start.addingTimeInterval(80))
        XCTAssertEqual(call.entries.map(\.kind), [.assistant, .caller, .question, .caller])
        XCTAssertEqual(call.entries[0].text, "Hi, I'm Alex.")
        XCTAssertEqual(call.transcriptText, """
            [0:00] Assistant: Hi, I'm Alex.
            [1:05] Caller: Hello
            [1:10] Asked Codex: Is Tuesday OK?
            [1:20] Caller: Sure
            """)
    }

    func testOptOutKeepsQuestionsAndSummaryButDropsSpeech() {
        var call = record()
        call.appendSpeech("Private detail", kind: .callerAndUser, at: start)
        call.append(CallEntry(kind: .answer, text: "Tuesday works", at: start))
        call.summary = "Booked Tuesday."
        let saved = call.persisted(keepingTranscript: false)
        XCTAssertFalse(saved.transcriptSaved)
        XCTAssertEqual(saved.entries.map(\.kind), [.answer])
        XCTAssertEqual(saved.summary, "Booked Tuesday.")
        XCTAssertEqual(call.persisted(keepingTranscript: true), call)
    }

    func testEntriesAreBounded() {
        var call = record()
        call.appendSpeech(String(repeating: "a", count: CallRecord.maximumEntryCharacters + 50), kind: .caller, at: start)
        call.appendSpeech("more", kind: .caller, at: start)
        XCTAssertEqual(call.entries[0].text.count, CallRecord.maximumEntryCharacters)
        for index in 0..<(CallRecord.maximumEntries + 10) {
            call.append(CallEntry(kind: .event, text: "\(index)", at: start))
        }
        XCTAssertEqual(call.entries.count, CallRecord.maximumEntries)
    }

    func testTranscriptPagesCoverEverythingWithinTheLimit() {
        var call = record()
        for index in 0..<40 {
            call.appendSpeech(String(repeating: "x", count: 300) + "\(index)", kind: index.isMultiple(of: 2) ? .assistant : .caller, at: start)
        }
        call.appendSpeech(String(repeating: "y", count: 2500), kind: .assistant, at: start)
        let first = call.transcriptPage(1, size: 1000)
        XCTAssertGreaterThan(first.pages, 1)
        var joined = [String]()
        for page in 1...first.pages {
            let value = call.transcriptPage(page, size: 1000)
            XCTAssertLessThanOrEqual(value.text.count, 1000)
            joined.append(value.text)
        }
        XCTAssertEqual(joined.joined().filter { $0 != "\n" }, call.transcriptText.filter { $0 != "\n" })
        XCTAssertEqual(call.transcriptPage(999, size: 1000).page, first.pages)
        XCTAssertEqual(record().transcriptPage(1).pages, 1)
    }

    func testFilesRoundTripSkipCorruptDataAndRejectUnsafeNames() throws {
        let files = temporaryFiles()
        var older = record(startedAt: start)
        older.appendSpeech("Hi", kind: .assistant, at: start)
        older.outcome = .ended; older.endedAt = start.addingTimeInterval(30)
        let newer = record(startedAt: start.addingTimeInterval(100))
        try files.save(older); try files.save(newer)
        try Data("not json".utf8).write(to: files.directory.appendingPathComponent(UUID().uuidString + ".json"))
        let loaded = files.loadAll()
        XCTAssertEqual(loaded.map(\.id), [newer.id, older.id])
        XCTAssertEqual(loaded[1].entries.first?.text, "Hi")
        let permissions = try FileManager.default.attributesOfItem(atPath: files.directory.appendingPathComponent(older.id + ".json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertThrowsError(try files.save(record("../escape")))
        XCTAssertThrowsError(try files.delete(id: "../escape"))
        try files.delete(id: older.id)
        XCTAssertEqual(files.loadAll().map(\.id), [newer.id])
        try files.deleteAll()
        XCTAssertTrue(files.loadAll().isEmpty)
    }

    func testRetentionExpiresOnlyFinishedCallsPastThirtyDays() throws {
        let files = temporaryFiles()
        let now = start.addingTimeInterval(31 * 24 * 60 * 60)
        var old = record(startedAt: start); old.outcome = .ended; old.endedAt = start
        var recent = record(startedAt: now.addingTimeInterval(-60)); recent.outcome = .ended; recent.endedAt = now
        let stillLive = record(startedAt: start)
        for call in [old, recent, stillLive] { try files.save(call) }
        XCTAssertEqual(files.prune(.forever, now: now), [])
        XCTAssertEqual(files.prune(.thirtyDays, now: now), [old.id])
        XCTAssertEqual(Set(files.loadAll().map(\.id)), [recent.id, stillLive.id])
    }

    func testPreferencesDefaultToSavingForThirtyDays() throws {
        let domain = "com.codexcall.tests.history." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertEqual(HistoryPreferences.load(from: defaults), HistoryPreferences())
        XCTAssertTrue(HistoryPreferences().saveTranscripts)
        XCTAssertEqual(HistoryPreferences().retention, .thirtyDays)
        var changed = HistoryPreferences(); changed.saveTranscripts = false; changed.retention = .forever
        changed.save(to: defaults)
        XCTAssertEqual(HistoryPreferences.load(from: defaults), changed)
    }
}

final class SpeakerLabeledTranscriptTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func call() -> CallRecord {
        CallRecord(id: UUID().uuidString, title: "Dentist", task: "Book", phoneNumber: nil, originThreadID: "t", startedAt: start)
    }

    func testLateLinesAreOrderedByWhenTheyWereSpoken() {
        var record = call()
        record.append(CallEntry(kind: .assistant, text: "Hi, I'm Alex.", at: start.addingTimeInterval(2)))
        record.append(CallEntry(kind: .event, text: "Switched to Join mode", at: start.addingTimeInterval(9)))
        record.insert(CallEntry(kind: .caller, text: "Bright Smile Dental.", at: start.addingTimeInterval(1)))
        record.insert(CallEntry(kind: .user, text: "Tuesday works for me.", at: start.addingTimeInterval(10)))
        record.insert(CallEntry(kind: .caller, text: "Great.", at: start.addingTimeInterval(5)))
        XCTAssertEqual(record.entries.map(\.text), ["Bright Smile Dental.", "Hi, I'm Alex.", "Great.", "Switched to Join mode", "Tuesday works for me."])
        XCTAssertEqual(record.transcriptText.components(separatedBy: "\n").last, "[0:10] You: Tuesday works for me.")
    }

    func testAssistantTurnExtendsInPlace() {
        var record = call()
        let turn = CallEntry(kind: .assistant, text: "Tuesday", at: start)
        record.insert(turn)
        record.insert(CallEntry(kind: .caller, text: "Sure.", at: start.addingTimeInterval(1)))
        XCTAssertTrue(record.extend(turn.id, with: " at nine works."))
        XCTAssertEqual(record.entries.first?.text, "Tuesday at nine works.")
        XCTAssertFalse(record.extend(UUID(), with: "x"))
    }

    func testEchoOfTheSpeakersIsDroppedButRealRepliesAreKept() {
        var record = call()
        record.append(CallEntry(kind: .assistant, text: "I can book Tuesday at nine thirty for Sam Lee.", at: start))
        XCTAssertTrue(record.isLikelyEcho("book Tuesday at nine thirty for Sam", at: start.addingTimeInterval(3)))
        XCTAssertFalse(record.isLikelyEcho("Actually make it Wednesday afternoon instead", at: start.addingTimeInterval(3)))
        XCTAssertFalse(record.isLikelyEcho("Yes please", at: start.addingTimeInterval(3)))
        XCTAssertFalse(record.isLikelyEcho("book Tuesday at nine thirty for Sam", at: start.addingTimeInterval(60)))
    }

    func testYouLinesAreSpeechAndFollowTheSavingSetting() {
        var record = call()
        record.insert(CallEntry(kind: .user, text: "Private", at: start))
        XCTAssertEqual(CallEntry.Kind.user.label, "You")
        XCTAssertTrue(record.persisted(keepingTranscript: false).entries.isEmpty)
    }
}

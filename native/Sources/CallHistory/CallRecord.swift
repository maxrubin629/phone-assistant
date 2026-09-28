import Foundation

/// One Codex phone session as the user and Codex review it afterwards.
/// Speech lines are untrusted caller or model content, never instructions.
public struct CallRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case live, ended, failed, interrupted
        public var title: String {
            switch self {
            case .live: return "Live"
            case .ended: return "Ended"
            case .failed: return "Failed"
            case .interrupted: return "Interrupted"
            }
        }
    }

    public static let maximumEntries = 4000
    public static let maximumEntryCharacters = 20000

    public let id: String
    public var title: String
    public var task: String
    public var phoneNumber: String?
    public var originThreadID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: Outcome = .live
    public var summary: String?
    public var entries: [CallEntry] = []
    /// False when the user turned off transcript saving; speech was not kept.
    public var transcriptSaved = true

    public init(id: String, title: String, task: String, phoneNumber: String?, originThreadID: String, startedAt: Date) {
        self.id = id; self.title = title; self.task = task; self.phoneNumber = phoneNumber
        self.originThreadID = originThreadID; self.startedAt = startedAt
    }

    public var duration: TimeInterval? { endedAt.map { max(0, $0.timeIntervalSince(startedAt)) } }
    /// When one speaker label covered the caller and the user's microphone together.
    public var mixesUserAndCaller: Bool { entries.contains { $0.kind == .callerAndUser } }

    /// Streaming transcript deltas extend the current line until the speaker changes.
    public mutating func appendSpeech(_ text: String, kind: CallEntry.Kind, at date: Date) {
        guard kind.isSpeech, !text.isEmpty else { return }
        if let last = entries.indices.last, entries[last].kind == kind {
            let room = Self.maximumEntryCharacters - entries[last].text.count
            if room > 0 { entries[last].text += text.prefix(room) }
            return
        }
        append(CallEntry(kind: kind, text: text, at: date))
    }

    public mutating func append(_ entry: CallEntry) {
        guard entries.count < Self.maximumEntries else { return }
        var bounded = entry
        bounded.text = String(entry.text.prefix(Self.maximumEntryCharacters))
        entries.append(bounded)
    }

    /// On-device lines arrive seconds after they were spoken; place them by time.
    public mutating func insert(_ entry: CallEntry) {
        guard entries.count < Self.maximumEntries else { return }
        var bounded = entry
        bounded.text = String(entry.text.prefix(Self.maximumEntryCharacters))
        let index = entries.lastIndex(where: { $0.at <= bounded.at }).map { $0 + 1 } ?? 0
        entries.insert(bounded, at: index)
    }

    /// Extends an entry still being spoken, such as the assistant's current turn.
    @discardableResult public mutating func extend(_ id: UUID, with text: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let room = Self.maximumEntryCharacters - entries[index].text.count
        if room > 0 { entries[index].text += text.prefix(room) }
        return true
    }

    /// Without headphones the user's microphone also picks up the caller and the
    /// assistant from the speakers. A "You" line is treated as echo when most of
    /// its words appear in a caller or assistant line from the preceding 30 s.
    /// Short replies are kept: there is too little to compare.
    public func isLikelyEcho(_ text: String, at date: Date) -> Bool {
        let words = Self.words(text)
        guard words.count >= 3 else { return false }
        return entries.contains { entry in
            guard entry.kind == .assistant || entry.kind == .caller,
                  entry.at <= date.addingTimeInterval(5), entry.at >= date.addingTimeInterval(-30) else { return false }
            let heard = Self.words(entry.text)
            return Double(words.filter(heard.contains).count) / Double(words.count) >= 0.6
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The copy written to disk. Questions, answers and events stay either way;
    /// Codex already holds them in its own thread.
    public func persisted(keepingTranscript: Bool) -> CallRecord {
        guard !keepingTranscript else { return self }
        var copy = self
        copy.entries.removeAll { $0.kind.isSpeech }
        copy.transcriptSaved = false
        return copy
    }

    public var transcriptText: String {
        entries.map { entry in
            let offset = Self.offset(entry.at.timeIntervalSince(startedAt))
            return "[\(offset)] \(entry.kind.label): \(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
    }

    /// Pages break on line boundaries where possible and are bounded in characters
    /// so a response always fits the local control frame.
    public func transcriptPage(_ page: Int, size: Int = 24000) -> (text: String, page: Int, pages: Int) {
        var pages: [String] = [], current = ""
        for line in transcriptText.split(separator: "\n", omittingEmptySubsequences: false) {
            var remaining = Substring(line)
            repeat {
                let room = size - current.count - (current.isEmpty ? 0 : 1)
                if room <= 0 || (remaining.count > room && !current.isEmpty) {
                    pages.append(current); current = ""; continue
                }
                if !current.isEmpty { current += "\n" }
                current += remaining.prefix(room)
                remaining = remaining.dropFirst(room)
            } while !remaining.isEmpty
        }
        if !current.isEmpty || pages.isEmpty { pages.append(current) }
        let index = min(max(page, 1), pages.count)
        return (pages[index - 1], index, pages.count)
    }

    public static func offset(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

public struct CallEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case assistant
        /// Only the caller reached the assistant.
        case caller
        /// The user's own microphone, transcribed on its own.
        case user
        /// The assistant heard the caller and the user's microphone as one mix.
        case callerAndUser
        case question, answer, event

        public var isSpeech: Bool { self == .assistant || self == .caller || self == .user || self == .callerAndUser }
        public var label: String {
            switch self {
            case .assistant: return "Assistant"
            case .caller: return "Caller"
            case .user: return "You"
            case .callerAndUser: return "Caller or you"
            case .question: return "Asked Codex"
            case .answer: return "Codex answered"
            case .event: return "Event"
            }
        }
    }

    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String, at: Date) {
        id = UUID(); self.kind = kind; self.text = text; self.at = at
    }
}

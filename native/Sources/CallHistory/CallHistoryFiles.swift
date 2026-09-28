import Foundation

public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case thirtyDays, forever
    public var title: String { self == .thirtyDays ? "30 days" : "Forever" }
    public var interval: TimeInterval? { self == .thirtyDays ? 30 * 24 * 60 * 60 : nil }
}

/// Stored under its own key, apart from assistant and audio-routing preferences.
public struct HistoryPreferences: Codable, Equatable, Sendable {
    public static let storageKey = "callHistory.v1"
    public var saveTranscripts = true
    public var retention: HistoryRetention = .thirtyDays
    public init() {}

    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// One owner-only JSON file per call. File names come only from session UUIDs.
public final class CallHistoryFiles: @unchecked Sendable {
    public let directory: URL
    private let manager = FileManager.default

    public init(directory: URL = CallHistoryFiles.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("com.codexcall.menu/Calls", isDirectory: true)
    }

    public func loadAll() -> [CallRecord] {
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = Self.decoder
        return names.compactMap { name -> CallRecord? in
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            // Unreadable files are skipped, never repaired or rewritten.
            return try? decoder.decode(CallRecord.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public func save(_ record: CallRecord) throws {
        let url = try fileURL(record.id)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(record).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func delete(id: String) throws {
        let url = try fileURL(id)
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
    }

    public func deleteAll() throws {
        for record in loadAll() { try delete(id: record.id) }
    }

    /// Returns the IDs removed. Live calls are never expired mid-call.
    @discardableResult public func prune(_ retention: HistoryRetention, now: Date = Date()) -> [String] {
        let expired = loadAll().filter { Self.expired($0, retention: retention, now: now) }.map(\.id)
        for id in expired { try? delete(id: id) }
        return expired
    }

    public static func expired(_ record: CallRecord, retention: HistoryRetention, now: Date) -> Bool {
        guard let interval = retention.interval, record.outcome != .live else { return false }
        return now.timeIntervalSince(record.endedAt ?? record.startedAt) > interval
    }

    private func fileURL(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw CocoaError(.fileWriteInvalidFileName) }
        return directory.appendingPathComponent(uuid.uuidString + ".json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

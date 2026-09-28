import Foundation

public struct PhoneSessionError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The originating task is fixed at creation. Caller/model content never selects
/// a callback destination. The registry is in memory and never resumes audio.
public struct PhoneSession: Codable, Equatable {
    public let sessionID: String
    public let originThreadID: String
    public let requestID: String
    public let task: String
    public let title: String
    public let phoneNumber: String?
    public var phase: String = "prepared"
    public var result: String?
    public var questionID: String?
    public var question: String?
    public var delivery: String?
    public var resultAttempted = false
    public var terminal: Bool { ["ended", "failed"].contains(phase) }
    public var json: [String: Any] {
        var value: [String: Any] = ["session_id": sessionID, "codex_task_id": originThreadID,
            "origin_thread_id": originThreadID, "request_id": requestID, "task": task,
            "title": title, "status": phase, "phone_connection": "managed_by_Phone",
            "dialing": "manual", "hangup": "manual"]
        value["phone_number"] = phoneNumber; value["result"] = result
        value["question_id"] = questionID; value["question"] = question
        value["callback_delivery"] = delivery
        return value
    }
}

public final class PhoneSessionRegistry {
    public private(set) var currentID: String?
    private var sessions: [String: PhoneSession] = [:]
    private var requests: [String: String] = [:]
    private var order: [String] = []
    public init() {}
    public var current: PhoneSession? { currentID.flatMap { sessions[$0] } }

    public func create(arguments: [String: Any]) throws -> PhoneSession {
        let origin = try text(arguments, "codex_task_id", maximum: 160)
        let request = try text(arguments, "request_id", maximum: 160)
        guard Self.validIdentifier(origin), Self.validIdentifier(request) else {
            throw PhoneSessionError("Use the exact Codex task ID and a stable alphanumeric request ID.")
        }
        let task = try text(arguments, "task", maximum: 16000)
        let title = try optionalText(arguments, "title", maximum: 120) ?? String(task.prefix(90))
        let phone = try optionalText(arguments, "phone_number", maximum: 30)
        if let phone, phone.range(of: "^\\+?[0-9 ()-]{3,30}$", options: .regularExpression) == nil {
            throw PhoneSessionError("Use a telephone number with digits, spaces, parentheses, or a leading +.")
        }
        if let id = requests[request], let existing = sessions[id] {
            guard existing.originThreadID == origin, existing.task == task,
                  existing.title == title, existing.phoneNumber == phone else {
                throw PhoneSessionError("This request ID was already used for a different task. Reuse its original arguments.")
            }
            return existing
        }
        guard current?.terminal != false else { throw PhoneSessionError("A phone session already exists. Use call_get, or end it before starting another.") }
        let value = PhoneSession(sessionID: UUID().uuidString, originThreadID: origin,
            requestID: request, task: task, title: title, phoneNumber: phone)
        sessions[value.sessionID] = value; requests[request] = value.sessionID
        currentID = value.sessionID; order.append(value.sessionID)
        while order.count > 32 {
            let old = order.removeFirst()
            if let removed = sessions.removeValue(forKey: old) { requests.removeValue(forKey: removed.requestID) }
        }
        return value
    }

    public func get(_ id: String? = nil) throws -> PhoneSession {
        guard let id = id ?? currentID, let session = sessions[id] else {
            throw PhoneSessionError("No matching phone session. Use call_start to prepare one.")
        }
        return session
    }
    public func update(_ id: String, _ edit: (inout PhoneSession) throws -> Void) throws {
        var value = try get(id); try edit(&value); sessions[id] = value
    }
    public func requireCurrent(_ id: String) throws -> PhoneSession {
        let session = try get(id)
        guard id == currentID, !session.terminal, session.phase != "disconnecting" else { throw PhoneSessionError("This phone session is ending or has ended. It cannot change the current call.") }
        return session
    }
    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
    private func text(_ values: [String: Any], _ key: String, maximum: Int) throws -> String {
        guard let value = values[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum else { throw PhoneSessionError("\(key) must be nonempty text, up to \(maximum) characters.") }
        return value
    }
    private func optionalText(_ values: [String: Any], _ key: String, maximum: Int) throws -> String? {
        guard values[key] != nil else { return nil }; return try text(values, key, maximum: maximum)
    }
}

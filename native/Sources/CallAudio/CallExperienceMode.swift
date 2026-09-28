import Foundation

/// Everyday call choices, backed by the same explicit audio permissions as advanced routing.
public enum CallExperienceMode: String, CaseIterable, Identifiable, Sendable {
    case assistant, listen, join, takeOver, manual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .assistant: return "Assistant"
        case .listen: return "Listen"
        case .join: return "Join"
        case .takeOver: return "Take over"
        case .manual: return "Just me"
        }
    }

    public var detail: String {
        switch self {
        case .assistant: return "Your assistant handles the call. Your microphone and listening are off."
        case .listen: return "Hear the conversation. Your microphone stays off."
        case .join: return "You and your assistant can both speak to the caller."
        case .takeOver: return "You speak. Your assistant listens without speaking."
        case .manual: return "Speak for yourself. Your assistant is off."
        }
    }

    public var symbolName: String {
        switch self {
        case .assistant: return "sparkles"
        case .listen: return "headphones"
        case .join: return "person.2.fill"
        case .takeOver: return "hand.raised.fill"
        case .manual: return "person.fill"
        }
    }

    public var routing: PhoneRouting {
        switch self {
        case .assistant: return PhoneRouting(speaker: .agent, listener: .agent)
        case .listen: return PhoneRouting(speaker: .agent, listener: .both)
        case .join: return PhoneRouting(speaker: .both, listener: .both)
        case .takeOver: return PhoneRouting(speaker: .user, listener: .both)
        case .manual: return PhoneRouting(speaker: .user, listener: .user)
        }
    }

    public var needsVoice: Bool { routing.needsVoice }

    /// Custom advanced routing stays custom instead of silently changing permissions.
    public init?(routing: PhoneRouting) {
        guard let mode = Self.allCases.first(where: { $0.routing == routing }) else { return nil }
        self = mode
    }
}

extension PhoneRouting {
    /// What the assistant is told about the current mode. Each preset states who
    /// is on the call, what the assistant hears, and how it should behave.
    /// Custom routing keeps the generic description.
    public func instructions(ownerName: String) -> String {
        let name = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = name.isEmpty ? "The owner" : name
        let ownerLower = name.isEmpty ? "the owner" : name
        switch CallExperienceMode(routing: self) {
        case .assistant:
            return "Mode: Assistant. You are handling this call alone. \(owner) can't hear it and isn't speaking, so every voice you hear besides your own is the caller."
        case .listen:
            return "Mode: Listen. You are handling this call. \(owner) is listening but not speaking, so every voice you hear besides your own is the caller. \(owner) may take over at any time."
        case .join:
            return "Mode: Join. \(owner) is on the call and speaking. Besides your own voice you'll hear two people mixed together: \(ownerLower) and the caller. \(owner) leads. Speak only when \(ownerLower) hands the conversation to you or asks you something, or when the caller clearly addresses you. Never talk over or contradict \(ownerLower). If you can't tell who said something, don't guess: let \(ownerLower) answer or ask."
        case .takeOver:
            return "Mode: Take over. \(owner) is handling the call. Stay completely silent and don't interject. Keep following the conversation, which mixes \(ownerLower) and the caller, so you can continue the call or report the result accurately when \(ownerLower) hands it back."
        case .manual, nil:
            return instructions
        }
    }
}

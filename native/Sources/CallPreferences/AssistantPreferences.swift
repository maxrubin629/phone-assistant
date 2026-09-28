import Foundation

public enum VoiceStyle: String, Codable, CaseIterable, Sendable {
    case natural, warm, focused
    public var title: String { rawValue.capitalized }
}

public enum SpeakingPace: String, Codable, CaseIterable, Sendable {
    case relaxed, balanced, brisk
    public var title: String { rawValue.capitalized }
}

public enum IntroductionStyle: String, Codable, CaseIterable, Sendable {
    case mentionAI, assistant, whenAsked, custom
    public var title: String {
        switch self {
        case .mentionAI: return "Introduce as an AI assistant"
        case .assistant: return "Introduce as my assistant"
        case .whenAsked: return "Wait to be asked"
        case .custom: return "Use my own introduction"
        }
    }
}

public enum SetupStep: String, Codable, Sendable {
    case permissions, assistant, introduction
}

/// Product preferences have their own key. They never replace the existing
/// audioRouting.v1 identifiers, levels, or explicit test configuration.
public struct AssistantPreferences: Codable, Equatable, Sendable {
    public static let storageKey = "assistantExperience.v1"
    public var name = "Alex"
    public var ownerName = ""
    public var voiceStyle: VoiceStyle = .natural
    public var pace: SpeakingPace = .balanced
    public var introduction: IntroductionStyle = .mentionAI
    public var customIntroduction = ""
    public var setupStep: SetupStep = .permissions
    public private(set) var setupCompleted = false

    public init() {}

    public var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give your assistant a name." }
        if introduction == .custom && customIntroduction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write an introduction or choose another option."
        }
        return nil
    }

    public var introductionPreview: String {
        let p = normalized()
        let aiIdentity = p.ownerName.isEmpty ? "an AI assistant" : p.ownerName + "'s AI assistant"
        let identity = p.ownerName.isEmpty ? "an assistant" : p.ownerName + "'s assistant"
        switch p.introduction {
        case .mentionAI: return "Hi, I'm \(p.name), \(aiIdentity)."
        case .assistant: return "Hi, I'm \(p.name), \(identity)."
        case .whenAsked: return "No automatic introduction. The assistant explains who it is when asked."
        case .custom: return p.customIntroduction
        }
    }

    /// No network or audio side effects. The native voice adapter applies this
    /// configuration at session creation, not during a live utterance.
    public var sessionInstructions: String {
        let p = normalized()
        return """
        Your assistant name is \(p.name).
        Voice delivery: \(p.voiceStyle.rawValue). Speaking pace: \(p.pace.rawValue).
        Introduction preference: \(p.introduction.title).
        Introduction text or behavior: \(p.introductionPreview)
        If asked whether you are AI, answer honestly. Do not claim to be human or impersonate the owner.
        """
    }

    @discardableResult public mutating func completeSetup() -> Bool {
        guard validationMessage == nil, setupStep == .introduction else { return false }
        setupCompleted = true
        return true
    }

    public func normalized() -> Self {
        var result = self
        result.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        result.ownerName = String(ownerName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        result.customIntroduction = String(customIntroduction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
        return result
    }

    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var value = preferences.normalized()
        if value.validationMessage != nil { value.setupCompleted = false }
        return value
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalized()) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

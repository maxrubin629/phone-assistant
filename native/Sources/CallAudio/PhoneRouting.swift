import Foundation

public enum PhoneParticipant: String, CaseIterable, Codable, Sendable {
    case agent, user, both
    public var title: String {
        switch self { case .agent: return "Assistant"; case .user: return "Me"; case .both: return "Both" }
    }
    public var includesAgent: Bool { self != .user }
    public var includesUser: Bool { self != .agent }
}

/// Two independent directions, with no implicit microphone opt-in from listening.
public struct PhoneRouting: Equatable, Codable, Sendable {
    public var speaker: PhoneParticipant
    public var listener: PhoneParticipant
    public init(speaker: PhoneParticipant = .agent, listener: PhoneParticipant = .agent) {
        self.speaker = speaker; self.listener = listener
    }
    public var needsVoice: Bool { speaker.includesAgent || listener.includesAgent }
    public var routes: CallAudioRoutes {
        var result: CallAudioRoutes = []
        if speaker.includesAgent { result.insert(.agentToCaller) }
        if speaker.includesUser { result.insert(.microphoneToCaller) }
        if listener.includesAgent {
            result.insert(.callerToAgent)
            if speaker.includesUser { result.insert(.microphoneToAgent) }
        }
        if listener.includesUser {
            result.insert(.callerToUser)
            if speaker.includesAgent { result.insert(.agentToUser) }
        }
        return result
    }
    public var instructions: String {
        let speaking = speaker.includesAgent
            ? "You may speak to the person on the phone. Yield when the owner speaks."
            : "The owner has taken over speaking. Listen to the conversation, but do not speak or interject until the owner changes this mode."
        let listening = listener.includesAgent
            ? "Incoming audio is the telephone conversation. When the owner joins, their voice may also be included; do not assume you can identify the speakers with certainty."
            : "The owner has disabled your access to caller audio. Do not claim to hear the caller. Speak only from the explicit task context."
        return speaking + " " + listening
    }
}

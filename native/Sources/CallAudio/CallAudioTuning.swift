import Foundation
import CallAudioDSP

/// Session-only troubleshooting controls. These can only narrow the routes
/// authorized by PhoneRouting; raising a level never opens a new destination.
public struct CallAudioTuning: Codable, Equatable, Sendable {
    public enum Path: String, CaseIterable, Codable, Sendable {
        case microphoneToCaller, agentToCaller, callerToUser, agentToUser, microphoneToAgent, callerToAgent
        public var title: String {
            switch self {
            case .microphoneToCaller: return "My microphone → caller"
            case .agentToCaller: return "Assistant → caller"
            case .callerToUser: return "Caller → my speakers"
            case .agentToUser: return "Assistant → my speakers"
            case .microphoneToAgent: return "My microphone → assistant"
            case .callerToAgent: return "Caller → assistant"
            }
        }
        public var route: CallAudioRoutes {
            switch self {
            case .microphoneToCaller: return .microphoneToCaller
            case .agentToCaller: return .agentToCaller
            case .callerToUser: return .callerToUser
            case .agentToUser: return .agentToUser
            case .microphoneToAgent: return .microphoneToAgent
            case .callerToAgent: return .callerToAgent
            }
        }
    }
    private var levels: [Path: Double] = [:]
    private var mutedPaths: Set<Path> = []
    public var limiterEnabled = true
    public var limiterCeiling: Double = 0.98
    public var limiterReleaseMS: Double = 80
    public init(microphoneGain: Double = 1) {
        self[.microphoneToCaller] = microphoneGain
        self[.microphoneToAgent] = microphoneGain
    }
    public subscript(path: Path) -> Double {
        get { levels[path] ?? 1 }
        set { levels[path] = Self.gain(newValue) }
    }
    public func isMuted(_ path: Path) -> Bool { mutedPaths.contains(path) }
    public mutating func setMuted(_ muted: Bool, path: Path) {
        if muted { mutedPaths.insert(path) } else { mutedPaths.remove(path) }
    }
    public func effectiveRoutes(_ authorized: CallAudioRoutes) -> CallAudioRoutes {
        mutedPaths.reduce(authorized) { $0.subtracting($1.route) }
    }
    public func normalized() -> Self {
        var copy = self
        for path in Path.allCases { copy[path] = self[path] }
        copy.limiterCeiling = limiterCeiling.isFinite ? min(0.999, max(0.1, limiterCeiling)) : 0.98
        copy.limiterReleaseMS = limiterReleaseMS.isFinite ? min(1000, max(10, limiterReleaseMS)) : 80
        return copy
    }
    private static func gain(_ value: Double) -> Double { value.isFinite ? min(4, max(0, value)) : 0 }
    func apply(to controls: OpaquePointer) {
        let value = normalized()
        cab_controls_set_gains(controls, Float(value[.microphoneToCaller]), Float(value[.agentToCaller]), Float(value[.callerToUser]))
        cab_controls_set_monitor_agent_gain(controls, Float(value[.agentToUser]))
        cab_controls_set_limiter(controls, value.limiterEnabled, Float(value.limiterCeiling), Float(value.limiterReleaseMS))
    }
}

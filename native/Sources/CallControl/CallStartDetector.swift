import Foundation

/// Decides when a prepared session may connect on its own. It fires once, only
/// after call audio was seen idle and then running, so it never joins a call that
/// was already in progress, and only while the preparation is recent.
public struct CallStartDetector {
    public static let window: TimeInterval = 10 * 60
    public let preparedAt: Date
    private var sawIdle = false
    private var fired = false

    public init(preparedAt: Date) { self.preparedAt = preparedAt }

    public var expired: Bool { fired }
    public func stale(at now: Date) -> Bool { now.timeIntervalSince(preparedAt) > Self.window }

    public mutating func observe(callAudioRunning running: Bool, at now: Date) -> Bool {
        guard !fired, !stale(at: now) else { return false }
        guard running else { sawIdle = true; return false }
        guard sawIdle else { return false }
        fired = true
        return true
    }
}

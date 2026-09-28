import CoreAudio
import CallAudioDSP
import Foundation

/// A blank selection follows macOS. A UID is an explicit, stable override.
public enum AudioDeviceSelection: Equatable, Sendable {
    case automatic
    case fixed(String)
    public init(uid: String?) {
        if let uid, !uid.isEmpty { self = .fixed(uid) } else { self = .automatic }
    }
}

struct AudioEndpointTarget: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let format: AudioStreamBasicDescription
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.uid == b.uid && CallHardware.same(a.format, b.format)
    }
}

protocol FollowingAudioEndpoint: AnyObject {
    func start() throws
    func close() throws
}
extension InputIO: FollowingAudioEndpoint {}
extension OutputIO: FollowingAudioEndpoint {}

/// Device replacement temporarily closes routes, without changing the separate
/// mute and cancellation controls. Failed changes cannot reopen delivery.
final class DeviceTransitionGate {
    let controls: AudioControls
    private(set) var changed = false
    init(_ controls: AudioControls) { self.controls = controls }
    func begin() { changed = true; cab_controls_set_routes(controls.pointer, 0) }
    func finish(success: Bool, restore: () -> Void) {
        guard changed else { return }
        if success { restore() } else { cab_controls_set_routes(controls.pointer, 0) }
    }
}

/// Worker-owned endpoint lifecycle. Never writes system defaults, touches the
/// Phone-facing device, changes mute, or replaces a caller/application tap.
final class FollowingDevice<Endpoint: FollowingAudioEndpoint> {
    private(set) var endpoint: Endpoint?
    private(set) var target: AudioEndpointTarget?
    private(set) var waiting = false
    private var retryAt: TimeInterval = 0

    @discardableResult func refresh(selection: AudioDeviceSelection, enabled: Bool, now: TimeInterval,
        resolve: (AudioDeviceSelection) throws -> AudioEndpointTarget,
        make: (AudioEndpointTarget) throws -> Endpoint, willChange: () -> Void,
        didClose: () -> Void = {}, isCancelled: () -> Bool = { false }) throws -> Bool {
        guard !isCancelled() else { throw CallAudioError("Device switching was cancelled.") }
        guard enabled else {
            waiting = false; retryAt = 0
            guard endpoint != nil else { return false }
            willChange(); try close(); didClose(); return true
        }
        let desired: AudioEndpointTarget
        do { desired = try resolve(selection) }
        catch {
            guard selection == .automatic else { throw error }
            waiting = true
            guard endpoint != nil else { return false }
            willChange(); try close(); didClose(); waiting = true; return true
        }
        if target == desired, endpoint != nil { waiting = false; return false }
        if endpoint == nil && now < retryAt { return false }
        willChange()
        // A failed close retains ownership and is fatal. Never start a second
        // reader/writer on the same rings while the first might still run.
        try close()
        didClose()
        do {
            guard !isCancelled() else { throw CallAudioError("Device switching was cancelled.") }
            endpoint = try make(desired)
            guard !isCancelled() else { throw CallAudioError("Device switching was cancelled.") }
            try endpoint?.start()
            guard !isCancelled() else { throw CallAudioError("Device switching was cancelled.") }
            target = desired; waiting = false; retryAt = 0
        } catch {
            let failure = error
            try close()
            guard !isCancelled(), selection == .automatic else { throw failure }
            waiting = true; retryAt = now + 0.5
        }
        return true
    }

    func close() throws {
        try endpoint?.close()
        endpoint = nil; target = nil
    }
    func reset() throws { try close(); waiting = false; retryAt = 0 }
}

extension CallHardware {
    static func endpoint(_ selection: AudioDeviceSelection, scope: AudioObjectPropertyScope) throws -> AudioEndpointTarget {
        let uid: String
        switch selection {
        case .fixed(let selected): uid = selected
        case .automatic:
            let selector = scope == kAudioDevicePropertyScopeInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
            let id = try value(AudioObjectID(kAudioObjectSystemObject), selector, initial: AudioDeviceID(0))
            guard id != 0 else { throw CallAudioError("macOS has no selected audio device.") }
            uid = try string(id, kAudioDevicePropertyDeviceUID)
        }
        // In particular, never follow our virtual microphone back into itself.
        let id = try physical(uid, scope: scope)
        return try .init(id: id, uid: uid, name: string(id, kAudioObjectPropertyName), format: format(id, scope: scope))
    }
}

import CoreAudio
import Foundation

/// Explicit operator controls only. No automatic writes, leases, default-device
/// changes, or driver replacement. Unsupported properties stay unavailable.
public struct HardwareAudioLevel: Sendable {
    public let volume: Double?
    public let muted: Bool?
    public let volumeWritable: Bool
    public let muteWritable: Bool
    public static func read(uid: String, input: Bool) throws -> Self {
        let device = try CallHardware.device(uid)
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        func writable(_ selector: AudioObjectPropertySelector) -> Bool {
            var property = CallHardware.address(selector, scope), value: DarwinBoolean = false
            return AudioObjectIsPropertySettable(device, &property, &value) == noErr && value.boolValue
        }
        let volume = try? CallHardware.value(device, kAudioDevicePropertyVolumeScalar, initial: Float32(0), scope: scope)
        let mute = try? CallHardware.value(device, kAudioDevicePropertyMute, initial: UInt32(0), scope: scope)
        return Self(volume: volume.flatMap { $0.isFinite ? Double($0) : nil }, muted: mute.map { $0 != 0 },
            volumeWritable: writable(kAudioDevicePropertyVolumeScalar), muteWritable: writable(kAudioDevicePropertyMute))
    }
    public static func setVolume(_ value: Double, uid: String, input: Bool) throws {
        guard value.isFinite, (0...1).contains(value) else { throw CallAudioError("Hardware volume must be between 0 and 100 percent.") }
        try set(Float32(value), selector: kAudioDevicePropertyVolumeScalar, uid: uid, input: input)
    }
    public static func setMuted(_ value: Bool, uid: String, input: Bool) throws {
        try set(UInt32(value ? 1 : 0), selector: kAudioDevicePropertyMute, uid: uid, input: input)
    }
    private static func set<T>(_ value: T, selector: AudioObjectPropertySelector, uid: String, input: Bool) throws {
        let device = try CallHardware.device(uid)
        var property = CallHardware.address(selector, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput)
        var writable: DarwinBoolean = false
        try CallHardware.check(AudioObjectIsPropertySettable(device, &property, &writable), "Check hardware volume control")
        guard writable.boolValue else { throw CallAudioError("This device does not expose that control.") }
        var copy = value
        try CallHardware.check(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<T>.size), &copy), "Set hardware level")
    }
}

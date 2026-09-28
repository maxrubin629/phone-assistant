import Foundation

/// Persist stable application/device identities, never a PID or HAL object ID.
public struct RoutingPreferences: Codable, Equatable, Sendable {
    /// A dedicated test path, not an application process-tree capture.
    public static let phoneSourceID = "com.codexcall.audio-test.phone"
    public var isPhoneTest: Bool { applicationID == Self.phoneSourceID }
    public var applicationID = ""
    public var applicationName = ""
    public var microphoneUID = ""
    public var microphoneName = ""
    public var monitorUID = ""
    public var monitorName = ""
    public var microphoneEnabled = false
    public var sourceToCaller = true
    public var microphoneToCaller = true
    public var listenToSource = false
    public var listenToMicrophone = false
    public var sourceGain: Double = 0.5
    public var microphoneGain: Double = 1
    // Optional storage preserves decoding of audioRouting.v1 installations.
    public var nativePhonePlayback: Bool? = nil
    public var usesNativePhonePlayback: Bool {
        get { nativePhonePlayback ?? false }
        set { nativePhonePlayback = newValue }
    }
    public init() {}
    private static let storageKey = "audioRouting.v1"
    public static func load(from defaults: UserDefaults) -> Self {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }?.normalized() ?? .init()
    }
    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(normalized()) { defaults.set(data, forKey: Self.storageKey) }
    }
    public func normalized() -> Self {
        var copy = self
        copy.sourceGain = sourceGain.isFinite ? min(4, max(0, sourceGain)) : 0
        copy.microphoneGain = microphoneGain.isFinite ? min(4, max(0, microphoneGain)) : 0
        if isPhoneTest {
            // Never interpret incoming telephone audio as generated speech.
            copy.sourceToCaller = false
            copy.listenToMicrophone = false
        }
        return copy
    }
    public var phoneTestConfiguration: CallAudioConfiguration {
        .init(virtualOutputUID: ApplicationAudioRuntime.sendDeviceUID,
              microphoneUID: microphoneUID.isEmpty ? nil : microphoneUID,
              monitorOutputUID: usesNativePhonePlayback || monitorUID.isEmpty ? nil : monitorUID,
              microphoneEnabled: microphoneEnabled && microphoneToCaller,
              mode: .takeOver, manageCallerListening: !usesNativePhonePlayback, requirePhoneInput: true)
    }
    public func requiresRestart(comparedTo other: Self) -> Bool {
        applicationID != other.applicationID || microphoneUID != other.microphoneUID || monitorUID != other.monitorUID ||
        microphoneEnabled != other.microphoneEnabled || sourceToCaller != other.sourceToCaller ||
        microphoneToCaller != other.microphoneToCaller || listenToSource != other.listenToSource ||
        listenToMicrophone != other.listenToMicrophone || usesNativePhonePlayback != other.usesNativePhonePlayback
    }
    public func unavailable(applicationIDs: [String], microphoneUIDs: [String], outputUIDs: [String]) -> String? {
        guard applicationIDs.filter({ $0 == applicationID }).count == 1 else {
            return applicationID.isEmpty ? "Choose an application." : "The selected application is unavailable or ambiguous. Reopen it, then refresh."
        }
        if microphoneEnabled && !microphoneUID.isEmpty && !microphoneUIDs.contains(microphoneUID) { return "The selected microphone is unavailable. Reconnect it or choose another microphone." }
        if !(isPhoneTest && usesNativePhonePlayback) && (listenToSource || (microphoneEnabled && listenToMicrophone)) && !monitorUID.isEmpty && !outputUIDs.contains(monitorUID) {
            return "The selected listening output is unavailable. Reconnect it or choose another output."
        }
        return nil
    }
}

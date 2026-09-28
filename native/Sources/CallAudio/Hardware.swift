import AppKit
import CoreAudio
import Foundation

enum CallHardware {
    static func check(_ status: OSStatus, _ label: String) throws {
        if status != noErr { throw CallAudioError("\(label) failed (\(status)).") }
    }
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var result = initial, size = UInt32(MemoryLayout<T>.size)
        var prop = address(selector, scope)
        try withUnsafeMutablePointer(to: &result) {
            try check(AudioObjectGetPropertyData(id, &prop, 0, nil, &size, $0), "Read audio property")
        }
        return result
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let value = try value(id, selector, initial: nil as Unmanaged<CFString>?)
        guard let value else { throw CallAudioError("Audio object has no stable identity.") }
        return value.takeRetainedValue() as String
    }
    static func list(_ selector: AudioObjectPropertySelector,
                     id: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
        var prop = address(selector, scope), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &prop, 0, nil, &size), "Read audio list size")
        if size == 0 { return [] }
        var result = [UInt32](repeating: 0, count: Int(size) / 4)
        try result.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(id, &prop, 0, nil, &size, $0.baseAddress!), "Read audio list")
        }
        return result
    }
    static func device(_ uid: String) throws -> AudioDeviceID {
        guard !uid.isEmpty, uid != "default" else { throw CallAudioError("Choose an explicit audio device; system defaults are not a route.") }
        // UID translation also resolves our hidden feed, which deliberately
        // does not appear in normal input/output device lists.
        let uidString = uid as CFString
        var token = Unmanaged.passUnretained(uidString)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try withExtendedLifetime(uidString) {
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                UInt32(MemoryLayout.size(ofValue: token)), &token, &size, &device), "Resolve audio device")
        }
        guard device != kAudioObjectUnknown else { throw CallAudioError("Selected audio device is missing: \(uid)") }
        guard try value(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) == 1 else {
            throw CallAudioError("Selected audio device is not alive: \(uid)")
        }
        return device
    }
    static func format(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        let result = try value(id, kAudioDevicePropertyStreamFormat, initial: AudioStreamBasicDescription(), scope: scope)
        guard result.mFormatID == kAudioFormatLinearPCM, result.mBitsPerChannel == 32,
              result.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              result.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              result.mChannelsPerFrame > 0, result.mChannelsPerFrame <= 32,
              (8000...192000).contains(result.mSampleRate) else {
            throw CallAudioError("The selected route requires native Float32 PCM at 8–192 kHz.")
        }
        return result
    }
    static func same(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate && lhs.mFormatID == rhs.mFormatID &&
        lhs.mFormatFlags == rhs.mFormatFlags && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame &&
        lhs.mBytesPerFrame == rhs.mBytesPerFrame && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
    static func disappeared(_ id: AudioDeviceID) -> Bool {
        var prop = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 1, size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &prop, 0, nil, &size, &alive)
        return status == kAudioHardwareBadDeviceError || status == kAudioHardwareBadObjectError || (status == noErr && alive == 0)
    }
    static func physical(_ uid: String, scope: AudioObjectPropertyScope) throws -> AudioDeviceID {
        let id = try device(uid)
        let type = try value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
        guard type != kAudioDeviceTransportTypeVirtual, type != kAudioDeviceTransportTypeAggregate else {
            throw CallAudioError("Select a physical microphone or monitor, not a virtual device.")
        }
        _ = try format(id, scope: scope)
        return id
    }
    static func sendDevice(_ uid: String) throws -> AudioDeviceID {
        guard uid == ApplicationAudioRuntime.sendDeviceUID else {
            throw CallAudioError("Select the Phone Assistant microphone supplied by Phone Assistant Audio Bridge.")
        }
        let id = try device(uid)
        guard try value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) == kAudioDeviceTransportTypeVirtual else {
            throw CallAudioError("The Phone send route must be an explicit virtual audio device.")
        }
        let input = try format(id, scope: kAudioDevicePropertyScopeInput)
        guard input.mChannelsPerFrame == 2, input.mSampleRate == 48000,
              try list(kAudioDevicePropertyStreams, id: id, scope: kAudioDevicePropertyScopeOutput).isEmpty else {
            throw CallAudioError("Update Phone Assistant Audio Bridge in Permissions to enable the separate microphone feed.")
        }
        _ = try feedDevice()
        return id
    }
    static func feedDevice() throws -> AudioDeviceID {
        let id = try device(ApplicationAudioRuntime.feedDeviceUID)
        let output = try format(id, scope: kAudioDevicePropertyScopeOutput)
        guard output.mChannelsPerFrame == 2, output.mSampleRate == 48000,
              try value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) == kAudioDeviceTransportTypeVirtual,
              try value(id, kAudioDevicePropertyIsHidden, initial: UInt32(0)) == 1,
              try list(kAudioDevicePropertyStreams, id: id, scope: kAudioDevicePropertyScopeInput).isEmpty else {
            throw CallAudioError("Phone Assistant Audio Bridge's internal audio feed is unavailable. Refresh Permissions.")
        }
        return id
    }
    static func phoneProcess() throws -> AudioObjectID {
        let processes = try list(kAudioHardwarePropertyProcessObjectList).compactMap { id -> CallAudioProcess? in
            guard let bundle = try? string(id, kAudioProcessPropertyBundleID) else { return nil }
            return CallAudioProcess(id: id, bundleID: bundle,
                runningOutput: (try? value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1)
        }
        return try CallAudioAttribution.select(processes: processes,
            phoneRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mobilephone").isEmpty,
            faceTimeRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FaceTime").isEmpty)
    }
    static func verifyPhoneInput(process: AudioObjectID, uid: String) throws {
        let expected = try sendDevice(uid)
        let inputs = try list(kAudioProcessPropertyDevices, id: process, scope: kAudioObjectPropertyScopeInput)
        let running = try value(process, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) == 1
        let devices = try inputs.map { id in
            PhoneProcessDevice(id: id, inputStreamCount: try list(kAudioDevicePropertyStreams,
                id: id, scope: kAudioDevicePropertyScopeInput).count)
        }
        let outputs = try list(kAudioProcessPropertyDevices, id: process, scope: kAudioObjectPropertyScopeOutput).map { id in
            PhoneProcessDevice(id: id, inputStreamCount: 0, outputStreamCount: try list(kAudioDevicePropertyStreams,
                id: id, scope: kAudioDevicePropertyScopeOutput).count)
        }
        try PhoneInputRoute.validate(running: running, devices: devices, expected: expected, outputs: outputs)
    }
}

/// Owns exact random UIDs. No global default, process exclusions, or other
/// applications' taps are mutated. The aggregate has only the caller tap.
final class CallerTap {
    let process: AudioObjectID
    let uid = "com.codexcall.runtime." + UUID().uuidString
    let tapUUID = UUID()
    private(set) var tap: AudioObjectID = 0
    private(set) var device: AudioDeviceID = 0
    init(process: AudioObjectID) { self.process = process }
    func start(manageListening: Bool) throws {
        let description = CATapDescription(monoMixdownOfProcesses: [process])
        description.name = "Phone Assistant Caller"
        description.uuid = tapUUID; description.isPrivate = true
        description.isExclusive = false
        description.muteBehavior = manageListening ? .mutedWhenTapped : .unmuted
        if #available(macOS 26.0, *) { description.isProcessRestoreEnabled = false }
        try CallHardware.check(AudioHardwareCreateProcessTap(description, &tap), "Create scoped caller tap")
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Phone Assistant Caller Capture",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]
        ]
        try CallHardware.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "Create private caller capture")
        for _ in 0..<40 {
            if (try? CallHardware.value(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1 { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw CallAudioError("The caller capture device did not become ready.")
    }
    func close() throws {
        var failures: [String] = []
        if device != 0 {
            let status = AudioHardwareDestroyAggregateDevice(device)
            if status == noErr { device = 0 } else { failures.append("aggregate \(status)") }
        }
        // Independent cleanup: a disappearing device must never prevent unmuting.
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status == noErr { tap = 0 } else { failures.append("tap \(status)") }
        }
        if !failures.isEmpty { throw CallAudioError("Caller cleanup failed: " + failures.joined(separator: ", ")) }
    }
    func setManagedListening(_ managed: Bool) throws {
        guard tap != 0 else { throw CallAudioError("Caller capture is not running.") }
        var property = CallHardware.address(kAudioTapPropertyDescription)
        let raw = try CallHardware.value(tap, kAudioTapPropertyDescription, initial: nil as Unmanaged<CATapDescription>?)
        guard let description = raw?.takeRetainedValue() else { throw CallAudioError("Caller tap description is unavailable.") }
        description.muteBehavior = managed ? .mutedWhenTapped : .unmuted
        var reference = Unmanaged.passUnretained(description)
        try CallHardware.check(AudioObjectSetPropertyData(tap, &property, 0, nil,
            UInt32(MemoryLayout.size(ofValue: reference)), &reference), "Change Phone playback")
        let check = try CallHardware.value(tap, kAudioTapPropertyDescription, initial: nil as Unmanaged<CATapDescription>?)
        guard let actual = check?.takeRetainedValue(), actual.muteBehavior == description.muteBehavior else {
            throw CallAudioError("macOS did not apply the Phone playback choice.")
        }
    }
    deinit { try? close() }
}

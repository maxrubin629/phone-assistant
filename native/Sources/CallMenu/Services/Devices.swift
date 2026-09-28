import CoreAudio
import Foundation

enum Devices {
    static func defaultDevice(input: Bool, from devices: [AudioDevice]) -> AudioDevice? {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return devices.first { $0.id == id && $0.isPhysical && (input ? $0.input : $0.output) }
    }
    static func list() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            throw AudioError.message("Cannot enumerate audio devices")
        }
        guard size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { throw AudioError.message("Cannot read audio devices") }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            var prop = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var length = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &prop, 0, nil, &length, &transport)
            return AudioDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                               input: hasChannels(id, kAudioDevicePropertyScopeInput),
                               output: hasChannels(id, kAudioDevicePropertyScopeOutput), transport: transport)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var prop = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &prop, 0, nil, &length, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasChannels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var prop = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var length: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &prop, 0, nil, &length) == noErr && length > 0
    }
}

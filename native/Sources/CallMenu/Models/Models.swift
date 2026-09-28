import Foundation
import CoreAudio

struct CallSession: Decodable, Identifiable {
    let id: String
    let phone_number: String
    let mode: String
    let state: String
    var active: Bool { !["ended", "failed", "closing"].contains(state) }
}

struct ServerState: Decodable { let calls: [CallSession] }

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let input: Bool
    let output: Bool
    let transport: UInt32
    var isVirtual: Bool { transport == kAudioDeviceTransportTypeVirtual }
    var isPhysical: Bool { !isVirtual && transport != kAudioDeviceTransportTypeAggregate }
}

struct NativeAudioEvent: Decodable {
    let type: String
    var scope: String?
    var protocolVersion: Int?
    var epoch: String?
    var mode: String?
    var sequence: UInt64?
    var audience: String?
    var audio: String?
    var captureReady: Bool?
    var outputReady: Bool?
    var outputUID: String?
    var message: String?
    var reason: String?
}

enum AudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

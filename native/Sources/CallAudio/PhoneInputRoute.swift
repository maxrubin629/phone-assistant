import Foundation

/// The process device list can include an output-only device on a duplex I/O
/// client. Stream capability distinguishes that case from another microphone.
struct PhoneProcessDevice: Equatable {
    let id: UInt32
    let inputStreamCount: Int
    var outputStreamCount: Int = 0
}

enum PhoneInputRoute {
    static func validate(running: Bool, devices: [PhoneProcessDevice], expected: UInt32,
                         outputs: [PhoneProcessDevice]? = nil) throws {
        let possibleInputs = devices.filter { $0.inputStreamCount > 0 }
        guard running, Set(possibleInputs.map(\.id)) == [expected] else {
            throw CallAudioError("Phone has not activated Phone Assistant as its microphone. Disconnect and reconnect to retry automatic selection.")
        }
        if let outputs {
            guard outputs.contains(where: { $0.id != expected && $0.outputStreamCount > 0 }) else {
                throw CallAudioError("Phone's output is also set to Phone Assistant. In Phone's Audio menu, choose Use System Setting under Output. Keep Phone Assistant selected only under Microphone.")
            }
        }
    }
}

import Foundation

public enum PhoneControlPaths {
    // A short, user-owned directory avoids sockaddr_un's small path limit.
    public static var socketURL: URL {
        URL(fileURLWithPath: "/private/tmp/codex-phone-\(getuid())", isDirectory: true)
            .appendingPathComponent("control.sock")
    }
}

public struct PhoneControlError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum PhoneControlProtocol {
    public static let maximumFrameBytes = 128 * 1024
    public static let protocolVersion = 1

    public static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw PhoneControlError("Invalid control response") }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count < maximumFrameBytes else { throw PhoneControlError("Control message is too large") }
        data.append(10)
        return data
    }

    public static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count < maximumFrameBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhoneControlError("Expected a bounded JSON object")
        }
        return object
    }
}

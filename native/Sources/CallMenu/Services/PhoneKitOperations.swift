import Foundation
import Security
import ServiceManagement

@objc(PhoneKitPrivilegedProtocol) protocol PhoneKitPrivilegedProtocol {
    func install(withReply reply: @escaping (String) -> Void)
    func status(withReply reply: @escaping (String) -> Void)
}

struct PhoneKitStatus: Decodable {
    let bundledValid: Bool
    let installed: Bool
    let installedValid: Bool
    let updateAvailable: Bool
    let loaded: Bool
    let message: String
}

enum PhoneKitOperations {
    static let helperID = "com.codexcall.phonekit.helper"
    static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/" + helperID) }

    static func status() throws -> PhoneKitStatus {
        try JSONDecoder().decode(PhoneKitStatus.self, from: runHelper("--status"))
    }

    static func runHelper(_ argument: String) throws -> Data {
        guard ["--status", "--check", "--wait"].contains(argument) else { throw AudioError.message("Unsupported Phone Assistant Audio Bridge operation.") }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AudioError.message("This copy of Phone Assistant is missing its bridge installer. Reinstall the app.")
        }
        let process = Process(), output = Pipe()
        process.executableURL = helper; process.arguments = [argument]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if let response = try? JSONDecoder().decode(PhoneKitStatus.self, from: data) { throw AudioError.message(response.message) }
            throw AudioError.message(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    static func install() throws {
        _ = try runHelper("--check")
        let helperRequirement = try requirement("PhoneKitHelperRequirement")
        let clientRequirement = try requirement("PhoneKitClientRequirement")
        try validateSignature(helper, requirement: helperRequirement)
        try validateSignature(Bundle.main.bundleURL, requirement: clientRequirement)
        let installedHelper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/" + helperID)
        let bundledBytes = try Data(contentsOf: helper)
        // Explicit Enable repairs the helper registration as well as its file.
        // File equality alone cannot establish that launchd has registered it.
        try authorizeAndBless()
        guard (try? Data(contentsOf: installedHelper)) == bundledBytes else {
            throw AudioError.message("The installed Phone Assistant Audio Bridge helper does not match this build. Setup stopped before changing audio.")
        }
        let response = try callHelper(requirement: helperRequirement + " and " + codeHashRequirement(helper))
        guard response.loaded else { throw AudioError.message(response.message) }
    }

    private static func requirement(_ key: String) throws -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            throw AudioError.message("This build needs a signed native Phone Assistant Audio Bridge installer. No script installer will be used.")
        }
        return value
    }

    private static func validateSignature(_ url: URL, requirement text: String) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else {
            throw AudioError.message("Phone Assistant Audio Bridge's native installer signature could not be verified. Rebuild with the configured Apple signing identity.")
        }
    }

    private static func codeHashRequirement(_ url: URL) throws -> String {
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let hash = values[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
            throw AudioError.message("Phone Assistant Audio Bridge's signed build identifier is unavailable.")
        }
        return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
    }

    private static func authorizeAndBless() throws {
        var authorization: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &authorization)
        guard created == errAuthorizationSuccess, let authorization else {
            throw AudioError.message("macOS could not prepare Phone Assistant Audio Bridge authorization (\(created)).")
        }
        defer { AuthorizationFree(authorization, [.destroyRights]) }
        let result = kSMRightBlessPrivilegedHelper.withCString { right in
            var item = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                return AuthorizationCopyRights(authorization, &rights, nil,
                    [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        if result == errAuthorizationCanceled { throw AudioError.message("Setup was cancelled. Enable Phone Assistant Audio Bridge when ready.") }
        guard result == errAuthorizationSuccess else { throw AudioError.message("macOS did not authorize Phone Assistant Audio Bridge (\(result)).") }
        var error: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, helperID as CFString, authorization, &error) else {
            let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "Native helper installation failed."
            throw AudioError.message(message)
        }
    }

    private static func callHelper(requirement: String) throws -> PhoneKitStatus {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
            throw AudioError.message("Phone Assistant Audio Bridge's helper verification rule is invalid.")
        }
        let connection = NSXPCConnection(machServiceName: helperID, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PhoneKitPrivilegedProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        let reply = PhoneKitReply()
        connection.invalidationHandler = { reply.finish(.failure(AudioError.message("Phone Assistant Audio Bridge's native helper connection closed. Refresh setup status."))) }
        connection.interruptionHandler = { reply.finish(.failure(AudioError.message("Phone Assistant Audio Bridge's native helper was interrupted. Refresh setup status."))) }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.finish(.failure($0)) }) as? PhoneKitPrivilegedProtocol else {
            throw AudioError.message("Could not connect to the native Phone Assistant Audio Bridge installer.")
        }
        proxy.install { json in reply.finish(Result { try JSONDecoder().decode(PhoneKitStatus.self, from: Data(json.utf8)) }) }
        guard reply.finished.wait(timeout: .now() + 45) == .success else {
            throw AudioError.message("Phone Assistant Audio Bridge setup is taking longer than expected. Refresh status before trying again.")
        }
        return try reply.value().get()
    }
}

private final class PhoneKitReply: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<PhoneKitStatus, Error>?
    func finish(_ value: Result<PhoneKitStatus, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; lock.unlock(); finished.signal()
    }
    func value() -> Result<PhoneKitStatus, Error> {
        lock.lock(); defer { lock.unlock() }
        return result ?? .failure(AudioError.message("Phone Assistant Audio Bridge returned no setup result."))
    }
}

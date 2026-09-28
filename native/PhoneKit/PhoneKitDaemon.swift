import Foundation

func json(_ result: KitStatus) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) else {
        return "{\"loaded\":false,\"message\":\"Phone Assistant Audio Bridge could not encode its status.\"}"
    }
    return text
}

final class PhoneKitService: NSObject, PhoneKitPrivilegedProtocol {
    private let queue = DispatchQueue(label: "com.codexcall.phonekit.install")
    func install(withReply reply: @escaping (String) -> Void) {
        queue.async { reply(json(enablePhoneKit())) }
    }
    func status(withReply reply: @escaping (String) -> Void) {
        queue.async { reply(json(SwiftStatus())) }
    }
}

// Avoid ambiguity with the Objective-C service method of the same name.
func SwiftStatus() -> KitStatus { status() }

final class PhoneKitListener: NSObject, NSXPCListenerDelegate {
    let service = PhoneKitService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // macOS evaluates the peer's signature for incoming messages. No PID-based client-auth race.
        connection.setCodeSigningRequirement(PhoneKitBuild.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: PhoneKitPrivilegedProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

#if !PHONE_KIT_TESTING
if CommandLine.arguments.count == 2 {
    do {
        switch CommandLine.arguments[1] {
        case "--status": emit(status())
        case "--check": emit(try preflight())
        default: throw KitError.invalid("Phone Assistant Audio Bridge accepts only read-only --status/--check outside its signed app connection.")
        }
    } catch {
        var result = status(); result.message = String(describing: error); emit(result); exit(2)
    }
} else if CommandLine.arguments.count == 1 && geteuid() == 0 {
    let delegate = PhoneKitListener()
    let listener = NSXPCListener(machServiceName: "com.codexcall.phonekit.helper")
    listener.delegate = delegate
    listener.resume()
    withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
} else {
    var result = status(); result.message = "Enable Phone Assistant Audio Bridge from the app's native setup screen."; emit(result); exit(2)
}
#endif

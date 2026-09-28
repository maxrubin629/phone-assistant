import Foundation

@objc(PhoneKitPrivilegedProtocol)
protocol PhoneKitPrivilegedProtocol {
    func install(withReply reply: @escaping (String) -> Void)
    func status(withReply reply: @escaping (String) -> Void)
}

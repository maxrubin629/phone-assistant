import Darwin
import Foundation
import XCTest
@testable import CallControl

final class LocalControlSocketTests: XCTestCase {
    private func directory() throws -> URL {
        let path = URL(fileURLWithPath: "/private/tmp/call-control-test-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    func testSameUserRoundTripAndStopRemoveOwnedSocket() throws {
        let url = try directory().appendingPathComponent("control.sock")
        let server = LocalControlServer(socketURL: url)
        defer { server.stop() }
        try server.start { request in ["received": request["action"] as? String ?? "missing", "ok": true] }
        let result = try LocalControlClient(socketURL: url).request(["action": "call_get", "arguments": [:]])
        XCTAssertEqual(result["received"] as? String, "call_get")
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try LocalControlClient(socketURL: url, timeout: 0.1).request(["action": "call_get"]))
    }

    func testSecondServerCannotUnlinkLiveSocket() throws {
        let url = try directory().appendingPathComponent("control.sock")
        let first = LocalControlServer(socketURL: url), second = LocalControlServer(socketURL: url)
        defer { first.stop(); second.stop() }
        try first.start { _ in ["owner": "first"] }
        XCTAssertThrowsError(try second.start { _ in ["owner": "second"] })
        let response = try LocalControlClient(socketURL: url).request(["action": "call_get"])
        XCTAssertEqual(response["owner"] as? String, "first")
        second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLooseDirectoryAndSymlinkSocketAreRejected() throws {
        let folder = try directory(), url = folder.appendingPathComponent("control.sock")
        XCTAssertEqual(chmod(folder.path, 0o755), 0)
        XCTAssertThrowsError(try LocalControlServer(socketURL: url).start { _ in [:] })
        XCTAssertEqual(chmod(folder.path, 0o700), 0)
        let target = folder.appendingPathComponent("preserve")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try LocalControlServer(socketURL: url).start { _ in [:] })
        XCTAssertThrowsError(try LocalControlClient(socketURL: url).request([:]))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
    }

    func testClientDeadlineAndServerCanRestart() throws {
        let url = try directory().appendingPathComponent("control.sock")
        let server = LocalControlServer(socketURL: url)
        defer { server.stop() }
        try server.start { _ in
            try? await Task.sleep(nanoseconds: 500_000_000)
            return ["status": "late"]
        }
        let began = Date()
        XCTAssertThrowsError(try LocalControlClient(socketURL: url, timeout: 0.1).request(["action": "call_get"]))
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        server.stop()
        try server.start { _ in ["status": "new"] }
        XCTAssertEqual(try LocalControlClient(socketURL: url).request(["action": "call_get"])["status"] as? String, "new")
    }
}

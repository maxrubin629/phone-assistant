import Darwin
import Foundation

/// Compatibility adapter for the installed desktop's versioned coordination
/// IPC. This does not start a daemon, subscribe to history, or create a task.
/// The public app-server proxy remains preferred when its socket is available.
actor CodexDesktopCallback {
    private var sessions: [UUID: CodexDesktopSession] = [:]
    private var closed = false
    private let makeConnection: @Sendable () throws -> any CodexDesktopConnection
    init() { makeConnection = { try CodexDesktopSocket() } }
    init(connection: @escaping @Sendable () throws -> any CodexDesktopConnection) { makeConnection = connection }

    func deliver(threadID: String, name: String, payload: [String: Any]) async throws -> String? {
        guard !closed else { throw CodexCallbackError.closed }
        guard sessions.count < 4 else { throw CodexCallbackError.overloaded }
        let parameters = try CodexCallbackWire.parameters(threadID: threadID, name: name, payload: payload)
        let id = UUID(), session = CodexDesktopSession(factory: makeConnection)
        sessions[id] = session
        defer { sessions.removeValue(forKey: id) }
        let task = Task.detached(priority: .userInitiated) { try session.deliver(origin: threadID, turnParameters: parameters) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { session.cancel() }
    }
    func close() {
        closed = true
        for session in sessions.values { session.cancel() }
    }
}

protocol CodexDesktopConnection: AnyObject, Sendable {
    func start() throws
    func write(_ frame: Data, deadline: TimeInterval) throws
    func read(deadline: TimeInterval) throws -> [String: Any]
    func cancel()
    func close()
}

enum CodexDesktopWire {
    static func frame(_ object: [String: Any]) throws -> Data {
        var bytes = try CodexCallbackWire.line(object)
        bytes.removeLast() // Desktop framing is not JSON-lines.
        var size = UInt32(bytes.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(bytes)
        return frame
    }
    static func frameSize(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw CodexCallbackError.protocolViolation }
        let size = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard size > 0, size <= CodexCallbackWire.maximumLineBytes else { throw CodexCallbackError.messageTooLarge }
        return Int(size)
    }
    static func request(method: String, version: Int, params: [String: Any], source: String,
                        id: String, target: String? = nil) -> [String: Any] {
        var object: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": source,
            "method": method, "version": version, "params": params, "timeoutMs": 15000]
        if let target { object["targetClientId"] = target }
        // Local follower envelopes must omit hostId. A hostId changes the
        // installed protocol version; local identity is established by discovery.
        return object
    }
}

private final class CodexDesktopSession: @unchecked Sendable {
    private let factory: @Sendable () throws -> any CodexDesktopConnection
    private let lock = NSLock()
    private var connection: (any CodexDesktopConnection)?
    private var cancelled = false
    private var callbackSubmitted = false // Only the worker reads/writes this.
    init(factory: @escaping @Sendable () throws -> any CodexDesktopConnection) { self.factory = factory }
    func cancel() {
        lock.lock(); cancelled = true; let current = connection; lock.unlock()
        current?.cancel()
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func deliver(origin: String, turnParameters: [String: Any]) throws -> String? {
        guard !isCancelled else { throw CodexCallbackError.cancelled(deliveryUncertain: false) }
        let io = try factory()
        lock.lock(); connection = io; let alreadyCancelled = cancelled; lock.unlock()
        defer { io.close(); lock.lock(); connection = nil; lock.unlock() }
        if alreadyCancelled { io.cancel(); throw CodexCallbackError.cancelled(deliveryUncertain: false) }
        do {
            try io.start()
            let initialized = try request(io, method: "initialize", version: 0,
                params: ["clientType": "codex-call"], source: "initializing-client")
            guard let client = (initialized["result"] as? [String: Any])?["clientId"] as? String,
                  UUID(uuidString: client) != nil, initialized["handledByClientId"] as? String == client else {
                throw CodexCallbackError.protocolViolation
            }
            let ownerReply = try request(io, method: "thread-owner-discovery", version: 1,
                params: ["hostId": "local", "conversationId": origin], source: client)
            guard let owner = ownerReply["handledByClientId"] as? String, UUID(uuidString: owner) != nil,
                  (ownerReply["result"] as? [String: Any])?["supportsUntrustedAppInput"] as? Bool == true else {
                throw CodexCallbackError.desktopIncompatible
            }
            guard !isCancelled else { throw CodexCallbackError.cancelled(deliveryUncertain: false) }
            // This single intended mutation invokes the owner's turn/start with
            // the exact external tool output for both idle and active origins.
            // It is never used to probe state, and is never retried or steered.
            let reply = try request(io, method: "thread-follower-start-turn", version: 2,
                params: ["conversationId": origin, "turnStart": ["request": turnParameters, "context": [:]]],
                source: client, target: owner, mutation: true)
            guard reply["handledByClientId"] as? String == owner else {
                throw CodexCallbackError.disconnected(deliveryUncertain: true)
            }
            let result = (reply["result"] as? [String: Any])?["result"] as? [String: Any]
            return (result?["turn"] as? [String: Any])?["id"] as? String
        } catch {
            if isCancelled { throw CodexCallbackError.cancelled(deliveryUncertain: callbackSubmitted) }
            if let known = error as? CodexCallbackError {
                switch known {
                case .desktopRejected: throw known // Explicit router pre-dispatch refusal.
                case .timedOut: throw CodexCallbackError.timedOut(method: "desktop callback", deliveryUncertain: callbackSubmitted)
                default:
                    if callbackSubmitted { throw CodexCallbackError.disconnected(deliveryUncertain: true) }
                    throw known
                }
            }
            throw CodexCallbackError.disconnected(deliveryUncertain: callbackSubmitted)
        }
    }

    private func request(_ io: any CodexDesktopConnection, method: String, version: Int,
                         params: [String: Any], source: String, target: String? = nil,
                         mutation: Bool = false) throws -> [String: Any] {
        let id = UUID().uuidString
        let frame = try CodexDesktopWire.frame(CodexDesktopWire.request(method: method, version: version,
            params: params, source: source, id: id, target: target))
        let deadline = ProcessInfo.processInfo.systemUptime + (mutation ? 15 : 3)
        guard !isCancelled else { throw CodexCallbackError.cancelled(deliveryUncertain: callbackSubmitted) }
        if mutation { callbackSubmitted = true }
        try io.write(frame, deadline: deadline)
        for _ in 0..<128 {
            let response = try io.read(deadline: deadline)
            if response["type"] as? String == "client-discovery-request", let incoming = response["requestId"] as? String {
                try io.write(CodexDesktopWire.frame(["type": "client-discovery-response", "requestId": incoming,
                    "response": ["canHandle": false]]), deadline: deadline)
                continue
            }
            guard response["type"] as? String == "response", response["requestId"] as? String == id else { continue }
            if response["resultType"] as? String == "error" {
                let code = response["error"] as? String ?? "unknown"
                let refused = ["no-client-found", "request-version-mismatch", "no-handler-for-request", "client-cannot-handle-request"]
                if refused.contains(code) { throw CodexCallbackError.desktopRejected(code) }
                if code == "request-timeout" { throw CodexCallbackError.timedOut(method: method, deliveryUncertain: mutation) }
                throw CodexCallbackError.disconnected(deliveryUncertain: mutation)
            }
            guard response["resultType"] as? String == "success", response["method"] as? String == method,
                  response["result"] is [String: Any] else { throw CodexCallbackError.protocolViolation }
            return response
        }
        throw CodexCallbackError.overloaded
    }
}

enum CodexDesktopEndpoint {
    static func codexHome(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["CODEX_HOME"], path.hasPrefix("/"), path.rangeOfCharacter(from: .controlCharacters) == nil {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static func validate(_ url: URL, uid: uid_t = getuid()) throws {
        var socket = stat(), directory = stat()
        guard lstat(url.path, &socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
              socket.st_uid == uid, socket.st_mode & 0o077 == 0,
              lstat(url.deletingLastPathComponent().path, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == uid,
              directory.st_mode & 0o022 == 0 else { throw CodexCallbackError.desktopUnavailable }
    }
    static func desktop() throws -> URL {
        let current = codexHome().appendingPathComponent("ipc/ipc.sock")
        if (try? validate(current)) != nil { return current }
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("codex-ipc/ipc-\(getuid()).sock")
        try validate(legacy)
        return legacy
    }
    static func proxySocket() -> URL? {
        if let path = ProcessInfo.processInfo.environment["CODEX_APP_SERVER_SOCKET"], path.hasPrefix("/") {
            let explicit = URL(fileURLWithPath: path)
            return (try? validate(explicit)) != nil ? explicit : nil
        }
        let standard = codexHome().appendingPathComponent("app-server-control/app-server-control.sock")
        return (try? validate(standard)) != nil ? standard : nil
    }
}

private final class CodexDesktopSocket: CodexDesktopConnection, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var cancelled = false
    init() throws { url = try CodexDesktopEndpoint.desktop() }
    func start() throws {
        try CodexDesktopEndpoint.validate(url)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexCallbackError.desktopUnavailable }
        lock.lock()
        if cancelled { lock.unlock(); Darwin.close(fd); throw CodexCallbackError.cancelled(deliveryUncertain: false) }
        descriptor = fd; lock.unlock()
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1, fcntl(fd, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else { throw CodexCallbackError.desktopUnavailable }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(url.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexCallbackError.desktopUnavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }}
        if result != 0 {
            guard errno == EINPROGRESS else { throw CodexCallbackError.desktopUnavailable }
            try wait(POLLOUT, deadline: ProcessInfo.processInfo.systemUptime + 3)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw CodexCallbackError.desktopUnavailable }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw CodexCallbackError.desktopUnavailable }
    }
    private func wait(_ event: Int32, deadline: TimeInterval) throws {
        while true {
            lock.lock(); let stopped = cancelled, fd = descriptor; lock.unlock()
            guard !stopped, fd >= 0 else { throw CodexCallbackError.cancelled(deliveryUncertain: false) }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CodexCallbackError.timedOut(method: "desktop IPC", deliveryUncertain: false) }
            var item = pollfd(fd: fd, events: Int16(event), revents: 0)
            let ready = poll(&item, 1, Int32(min(100, ceil(remaining * 1000))))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw CodexCallbackError.disconnected(deliveryUncertain: false) }
            if ready == 0 { continue }
            if item.revents & Int16(event) != 0 { return }
            throw CodexCallbackError.disconnected(deliveryUncertain: false)
        }
    }
    func write(_ frame: Data, deadline: TimeInterval) throws {
        guard frame.count <= CodexCallbackWire.maximumLineBytes + 4 else { throw CodexCallbackError.messageTooLarge }
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < frame.count {
                try wait(POLLOUT, deadline: deadline)
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw CodexCallbackError.disconnected(deliveryUncertain: false) }
                offset += count
            }
        }
    }
    private func exact(_ size: Int, deadline: TimeInterval) throws -> Data {
        var data = Data(count: size), offset = 0
        try data.withUnsafeMutableBytes { bytes in
            while offset < size {
                try wait(POLLIN, deadline: deadline)
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), size - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw CodexCallbackError.disconnected(deliveryUncertain: false) }
                offset += count
            }
        }
        return data
    }
    func read(deadline: TimeInterval) throws -> [String: Any] {
        let size = try CodexDesktopWire.frameSize(exact(4, deadline: deadline))
        let bytes = try exact(size, deadline: deadline)
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { throw CodexCallbackError.protocolViolation }
        return object
    }
    func cancel() {
        lock.lock(); cancelled = true
        if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) }
        lock.unlock()
    }
    func close() {
        lock.lock(); let fd = descriptor; descriptor = -1; lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
    }
    deinit { close() }
}

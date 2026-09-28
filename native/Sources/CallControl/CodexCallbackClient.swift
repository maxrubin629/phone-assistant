import Darwin
import Foundation

public enum CodexCallbackError: Error, LocalizedError, Equatable {
    case invalidThreadID, invalidToolName, invalidPayload, messageTooLarge
    case executableNotFound, launchFailed, closed, overloaded, protocolViolation
    case desktopUnavailable, desktopIncompatible, desktopRejected(String)
    case rejected(method: String, code: Int?)
    case timedOut(method: String, deliveryUncertain: Bool)
    case disconnected(deliveryUncertain: Bool)
    case cancelled(deliveryUncertain: Bool)

    public var deliveryUncertain: Bool {
        switch self {
        case .timedOut(_, let uncertain), .disconnected(let uncertain), .cancelled(let uncertain): return uncertain
        default: return false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidThreadID: return "A valid originating Codex task ID is required."
        case .invalidToolName: return "Unsupported Codex callback tool."
        case .invalidPayload: return "The Codex callback payload is not valid JSON."
        case .messageTooLarge: return "The Codex callback exceeds the one-megabyte message limit."
        case .executableNotFound: return "The installed Codex command could not be found."
        case .launchFailed: return "The Codex app-server proxy could not be started."
        case .closed: return "The Codex callback client is closed."
        case .overloaded: return "The Codex callback transport is full."
        case .protocolViolation: return "The Codex app-server proxy returned an invalid message."
        case .desktopUnavailable: return "The running Codex desktop connection is unavailable or is not owned by this Mac user. Open Codex, then try again."
        case .desktopIncompatible: return "This Codex desktop does not support the required callback protocol."
        case .desktopRejected(let code): return "Codex desktop did not accept the callback (\(code)). No callback turn was dispatched."
        case .rejected(let method, let code): return "Codex rejected \(method)" + (code.map { " (\($0))" } ?? "") + "."
        case .timedOut(let method, let uncertain):
            return "Codex \(method) timed out." + (uncertain ? " Delivery may have succeeded. Do not retry automatically." : " No callback turn was submitted by this request.")
        case .disconnected(let uncertain):
            return "The Codex app-server proxy disconnected." + (uncertain ? " Callback delivery is uncertain. Do not retry automatically." : "")
        case .cancelled(let uncertain):
            return "Codex callback delivery was cancelled." + (uncertain ? " The callback may already have reached its task. Do not retry automatically." : "")
        }
    }
}

/// Protocol construction is pure so tests can inspect callback envelopes without
/// opening Codex or sending a turn. The payload can never override its origin.
enum CodexCallbackWire {
    static let maximumLineBytes = 1_048_576
    static let allowedNames: Set<String> = ["call_agent_question", "call_agent_result"]

    static func parameters(threadID: String, name: String, payload: [String: Any]) throws -> [String: Any] {
        guard !threadID.isEmpty, threadID.utf8.count <= 160,
              threadID == threadID.trimmingCharacters(in: .whitespacesAndNewlines),
              threadID.rangeOfCharacter(from: .controlCharacters) == nil else { throw CodexCallbackError.invalidThreadID }
        guard allowedNames.contains(name) else { throw CodexCallbackError.invalidToolName }
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let output = String(data: encoded, encoding: .utf8) else { throw CodexCallbackError.invalidPayload }
        let params: [String: Any] = ["threadId": threadID, "input": [],
            "toolOutput": ["name": name, "namespace": "codex_call", "output": output]]
        // Include envelope overhead in validation before any thread is resumed.
        _ = try line(["id": Int.max, "method": "turn/start", "params": params])
        return params
    }

    static func line(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { throw CodexCallbackError.invalidPayload }
        guard data.count <= maximumLineBytes else { throw CodexCallbackError.messageTooLarge }
        data.append(10)
        return data
    }

    static func childEnvironment(_ source: [String: String]) -> [String: String] {
        source.filter { key, _ in
            let key = key.uppercased()
            let credentialParts = ["API_KEY", "APIKEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTHORIZATION"]
            return !credentialParts.contains(where: key.contains) &&
                !["OPENAI_BASE_URL", "CODEX_BIN", "SSH_AUTH_SOCK", "GIT_ASKPASS", "SUDO_ASKPASS", "LD_PRELOAD"].contains(key) &&
                !key.hasPrefix("DYLD_")
        }
    }
}

protocol CodexCallbackTransport: AnyObject, Sendable {
    var lines: AsyncThrowingStream<Data, Error> { get }
    func start() throws
    /// This must enqueue a bounded write and return without waiting for stdin.
    func send(_ line: Data) throws
    func close()
}

/// A JSON-lines client for the installed desktop proxy. Each delivery freezes
/// its supplied origin through resume and turn/start. There is no thread/start
/// route and no automatic retry, including after an uncertain turn timeout.
public actor CodexCallbackClient {
    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<[String: Any], Error>
        var timeout: Task<Void, Never>?
        var submitted = false
    }
    private let makeTransport: @Sendable () throws -> any CodexCallbackTransport
    private let timeoutNanoseconds: UInt64
    private let allowsDesktopFallback: Bool
    private var desktop: CodexDesktopCallback?
    private var transport: (any CodexCallbackTransport)?
    private var reader: Task<Void, Never>?
    private var connecting: Task<Void, Error>?
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var connectionGeneration: UInt64 = 0
    private var connected = false
    private var permanentlyClosed = false

    public init() {
        makeTransport = { try CodexProxyTransport() }
        timeoutNanoseconds = 15_000_000_000
        allowsDesktopFallback = true
    }
    init(timeoutNanoseconds: UInt64, transport: @escaping @Sendable () throws -> any CodexCallbackTransport) {
        self.timeoutNanoseconds = max(1, timeoutNanoseconds)
        self.makeTransport = transport
        allowsDesktopFallback = false
    }

    public func deliver(threadID: String, name: String, payload: [String: Any]) async throws -> String? {
        try await withTaskCancellationHandler {
            try await performDelivery(threadID: threadID, name: name, payload: payload)
        } onCancel: { [weak self] in
            Task { await self?.cancelDelivery() }
        }
    }
    private func performDelivery(threadID: String, name: String, payload: [String: Any]) async throws -> String? {
        guard !Task.isCancelled else { throw CodexCallbackError.cancelled(deliveryUncertain: false) }
        let origin = threadID
        let params = try CodexCallbackWire.parameters(threadID: origin, name: name, payload: payload)
        guard !permanentlyClosed else { throw CodexCallbackError.closed }
        if allowsDesktopFallback, CodexDesktopEndpoint.proxySocket() == nil {
            if ProcessInfo.processInfo.environment["CODEX_APP_SERVER_SOCKET"] != nil {
                throw CodexCallbackError.desktopUnavailable
            }
            if desktop == nil { desktop = CodexDesktopCallback() }
            return try await desktop!.deliver(threadID: origin, name: name, payload: payload)
        }
        try await connect()
        let resumed = try await request("thread/resume", params: ["threadId": origin, "excludeTurns": true])
        guard (resumed["thread"] as? [String: Any])?["id"] as? String == origin else {
            failConnection(CodexCallbackError.protocolViolation)
            throw CodexCallbackError.protocolViolation
        }
        let result = try await request("turn/start", params: params)
        // A successful response without a turn identifier still acknowledges
        // delivery. The caller must not turn a missing ID into a retry.
        return (result["turn"] as? [String: Any])?["id"] as? String
    }

    private func cancelDelivery() async {
        // Also wakes callers awaiting a shared initialize task. An already
        // submitted turn is conservatively reported as uncertain by teardown.
        failConnection(CodexCallbackError.cancelled(deliveryUncertain: false))
        // Desktop deliveries have their own cancellation handler; its session
        // socket is shut down directly without closing this reusable adapter.
    }

    public func close() async {
        permanentlyClosed = true
        connecting?.cancel(); connecting = nil
        failConnection(CodexCallbackError.closed)
        await desktop?.close()
    }

    private func connect() async throws {
        guard !permanentlyClosed else { throw CodexCallbackError.closed }
        if connected { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.open() }
        connecting = task
        do { try await task.value; connecting = nil }
        catch { connecting = nil; throw error }
    }

    private func open() async throws {
        guard !permanentlyClosed else { throw CodexCallbackError.closed }
        let created = try makeTransport()
        transport = created
        connectionGeneration &+= 1
        let generation = connectionGeneration
        do {
            try created.start()
            reader = Task { [weak self] in
                do {
                    for try await line in created.lines {
                        guard !Task.isCancelled else { return }
                        await self?.receive(line, generation: generation)
                    }
                    await self?.connectionEnded(generation: generation)
                } catch { await self?.connectionEnded(generation: generation) }
            }
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "codex_call", "title": "Phone Assistant", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            guard generation == connectionGeneration, !permanentlyClosed else { throw CodexCallbackError.closed }
            try created.send(CodexCallbackWire.line(["method": "initialized"]))
            connected = true
        } catch {
            if generation == connectionGeneration { failConnection(error) }
            throw error
        }
    }

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard !permanentlyClosed, let transport else { throw CodexCallbackError.closed }
        guard pending.count < 16 else { throw CodexCallbackError.overloaded }
        guard !Task.isCancelled else { throw CodexCallbackError.cancelled(deliveryUncertain: false) }
        let id = nextID; nextID += 1
        let data = try CodexCallbackWire.line(["id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(method: method, continuation: continuation)
                pending[id]?.timeout = Task { [weak self, timeoutNanoseconds] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    await self?.requestTimedOut(id)
                }
                do {
                    try transport.send(data)
                    pending[id]?.submitted = true
                } catch {
                    finish(id, result: .failure(error))
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.requestCancelled(id) }
        }
    }

    private func receive(_ data: Data, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        guard data.count <= CodexCallbackWire.maximumLineBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            failConnection(CodexCallbackError.protocolViolation); return
        }
        if object["method"] is String {
            if let id = object["id"], validRequestID(id) {
                // This client has no approval authority. No server-supplied
                // request is executed, including command/file/tool approvals.
                do {
                    try transport?.send(CodexCallbackWire.line(["id": id, "error": [
                        "code": -32601,
                        "message": "Phone Assistant callbacks do not support approvals or server requests. Use the Codex desktop UI."
                    ]]))
                } catch { failConnection(error) }
            } else if object["id"] != nil { failConnection(CodexCallbackError.protocolViolation) }
            return // Notifications are intentionally not retained or logged.
        }
        guard let id = object["id"] as? Int, let request = pending[id] else { return }
        if let error = object["error"] as? [String: Any] {
            finish(id, result: .failure(CodexCallbackError.rejected(method: request.method, code: error["code"] as? Int)))
        } else if let result = object["result"] as? [String: Any] {
            finish(id, result: .success(result))
        } else { failConnection(CodexCallbackError.protocolViolation) }
    }

    private func validRequestID(_ id: Any) -> Bool {
        if let string = id as? String { return string.utf8.count <= 1024 }
        guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
    }

    private func finish(_ id: Int, result: Result<[String: Any], Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout?.cancel()
        request.continuation.resume(with: result)
    }
    private func requestTimedOut(_ id: Int) {
        guard let request = pending[id] else { return }
        let uncertain = request.method == "turn/start" && request.submitted
        finish(id, result: .failure(CodexCallbackError.timedOut(method: request.method, deliveryUncertain: uncertain)))
        failConnection(CodexCallbackError.disconnected(deliveryUncertain: false))
    }
    private func requestCancelled(_ id: Int) {
        guard let request = pending[id] else { return }
        let uncertain = request.method == "turn/start" && request.submitted
        finish(id, result: .failure(CodexCallbackError.cancelled(deliveryUncertain: uncertain)))
        if uncertain { failConnection(CodexCallbackError.disconnected(deliveryUncertain: false)) }
    }
    private func connectionEnded(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        failConnection(CodexCallbackError.disconnected(deliveryUncertain: false))
    }
    private func failConnection(_ error: Error) {
        connectionGeneration &+= 1
        connected = false
        reader?.cancel(); reader = nil
        let previous = transport; transport = nil
        previous?.close()
        for (id, request) in pending {
            let failure: Error = request.method == "turn/start" && request.submitted
                ? CodexCallbackError.disconnected(deliveryUncertain: true) : error
            finish(id, result: .failure(failure))
        }
    }
    deinit { reader?.cancel(); connecting?.cancel(); transport?.close() }
}

/// Nonblocking pipe I/O is confined to one queue. Incoming lines and outgoing
/// bytes are bounded before publication. Stderr is discarded, never logged.
private final class CodexProxyTransport: CodexCallbackTransport, @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let io = DispatchQueue(label: "com.codexcall.callback.proxy")
    private let state = NSLock()
    private var closed = false
    private var queuedBytes = 0
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writerResumed = false
    private var readBuffer = Data()
    private var writes: [Data] = []
    private var writeOffset = 0
    private static let maximumQueuedBytes = 2 * CodexCallbackWire.maximumLineBytes

    init() throws {
        var saved: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(16)) { saved = $0 }
        continuation = saved
        process.executableURL = try Self.executable()
        let environment = ProcessInfo.processInfo.environment
        var arguments = ["app-server", "proxy"]
        if let socket = environment["CODEX_APP_SERVER_SOCKET"], socket.hasPrefix("/"),
           socket.utf8.count <= 4096, socket.rangeOfCharacter(from: .controlCharacters) == nil {
            arguments += ["--sock", socket]
        }
        process.arguments = arguments
        process.environment = CodexCallbackWire.childEnvironment(environment)
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }
    private static func executable() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
                          URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                          home.appendingPathComponent(".local/bin/codex")]
        for entry in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where entry.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: String(entry)).appendingPathComponent("codex"))
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CodexCallbackError.executableNotFound
        }
        return executable.resolvingSymlinksInPath()
    }
    func start() throws {
        process.terminationHandler = { [weak self] _ in self?.end(CodexCallbackError.disconnected(deliveryUncertain: false)) }
        let readFD = output.fileHandleForReading.fileDescriptor
        let writeFD = input.fileHandleForWriting.fileDescriptor
        guard fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK) != -1 else { throw CodexCallbackError.launchFailed }
        // Ignore SIGPIPE for this pipe, not for the whole application.
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1 else { throw CodexCallbackError.launchFailed }
        io.sync {
            let reader = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: io)
            reader.setEventHandler { [weak self] in self?.readAvailable() }
            reader.setCancelHandler { [output] in try? output.fileHandleForReading.close() }
            readSource = reader
            let writer = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: io)
            writer.setEventHandler { [weak self] in self?.writeAvailable() }
            writer.setCancelHandler { [input] in try? input.fileHandleForWriting.close() }
            writeSource = writer
            reader.resume()
        }
        do { try process.run() } catch { end(CodexCallbackError.launchFailed); throw CodexCallbackError.launchFailed }
    }
    func send(_ line: Data) throws {
        guard line.count <= CodexCallbackWire.maximumLineBytes + 1 else { throw CodexCallbackError.messageTooLarge }
        state.lock()
        guard !closed else { state.unlock(); throw CodexCallbackError.closed }
        guard queuedBytes + line.count <= Self.maximumQueuedBytes else { state.unlock(); throw CodexCallbackError.overloaded }
        queuedBytes += line.count
        state.unlock()
        io.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.writes.append(line)
            if !self.writerResumed { self.writerResumed = true; self.writeSource?.resume() }
        }
    }
    private var isClosed: Bool { state.lock(); defer { state.unlock() }; return closed }
    private func readAvailable() {
        guard !isClosed else { return }
        var bytes = [UInt8](repeating: 0, count: 16384)
        // Bound work per dispatch event as well as the stored line length.
        for _ in 0..<16 {
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count == 0 { end(CodexCallbackError.disconnected(deliveryUncertain: false)); return }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                end(CodexCallbackError.disconnected(deliveryUncertain: false)); return
            }
            readBuffer.append(contentsOf: bytes.prefix(count))
            while let newline = readBuffer.firstIndex(of: 10) {
                let length = readBuffer.distance(from: readBuffer.startIndex, to: newline)
                guard length <= CodexCallbackWire.maximumLineBytes else { end(CodexCallbackError.messageTooLarge); return }
                var line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(...newline)
                if line.last == 13 { line.removeLast() }
                guard !line.isEmpty else { continue }
                if case .dropped = continuation.yield(line) { end(CodexCallbackError.overloaded); return }
            }
            guard readBuffer.count <= CodexCallbackWire.maximumLineBytes else { end(CodexCallbackError.messageTooLarge); return }
        }
    }
    private func writeAvailable() {
        guard !isClosed else { return }
        var budget = 262144
        while let first = writes.first, budget > 0 {
            let count = first.withUnsafeBytes {
                Darwin.write(input.fileHandleForWriting.fileDescriptor, $0.baseAddress!.advanced(by: writeOffset), min(budget, first.count - writeOffset))
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                end(CodexCallbackError.disconnected(deliveryUncertain: false)); return
            }
            guard count > 0 else { return }
            budget -= count; writeOffset += count
            state.lock(); queuedBytes -= count; state.unlock()
            if writeOffset == first.count { writes.removeFirst(); writeOffset = 0 }
        }
        if writes.isEmpty, writerResumed { writerResumed = false; writeSource?.suspend() }
    }
    private func end(_ error: Error?) {
        state.lock()
        guard !closed else { state.unlock(); return }
        closed = true
        state.unlock()
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        let child = process
        if child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        io.async { [self] in
            readSource?.cancel(); readSource = nil
            if let writeSource {
                writeSource.cancel()
                if !writerResumed { writeSource.resume() }
            }
            writeSource = nil; writerResumed = false
            writes.removeAll(); readBuffer.removeAll()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
    }
    func close() { end(nil) }
    deinit { process.terminationHandler = nil }
}

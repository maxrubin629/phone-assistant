import Foundation

public actor LiveVoiceSession {
    public typealias AudioHandler = @Sendable (Data) async throws -> Void
    /// The application owns the destination and authorization. Return a bounded
    /// tool-result string; a pending question can return immediately and its
    /// eventual answer can arrive through instruct(_:).
    public typealias DelegationHandler = @Sendable (_ toolName: String, _ arguments: String, _ callID: String) async throws -> String
    typealias EventSender = @Sendable (Data) async throws -> Void
    private var socket: URLSessionWebSocketTask?
    private var transport: URLSession?
    private var receiver: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var connected = false
    private var closed = false
    private let audio: AudioHandler
    private let transcript: @Sendable (String, Bool) async -> Void
    private let failure: @Sendable (String) async -> Void
    private let delegation: DelegationHandler?
    private var delegationState = LiveDelegationState()
    private var delegationTasks: [LiveDelegationBatch.ID: Task<Void, Never>] = [:]
    private let eventSender: EventSender?

    public init(audio: @escaping AudioHandler,
                transcript: @escaping @Sendable (String, Bool) async -> Void = { _, _ in },
                failure: @escaping @Sendable (String) async -> Void = { _ in },
                delegation: DelegationHandler? = nil) {
        self.audio = audio; self.transcript = transcript; self.failure = failure
        self.delegation = delegation; self.eventSender = nil
    }

    /// Transport injection for deterministic protocol/lifecycle tests. Uses the
    /// same inbound handling and outbound serialization as the real socket.
    init(audio: @escaping AudioHandler,
         transcript: @escaping @Sendable (String, Bool) async -> Void = { _, _ in },
         failure: @escaping @Sendable (String) async -> Void = { _ in },
         delegation: DelegationHandler? = nil, sendEvent: @escaping EventSender) {
        self.audio = audio; self.transcript = transcript; self.failure = failure
        self.delegation = delegation; self.eventSender = sendEvent
    }

    public func connect(key: String, instructions: String, context: String = "", model: String = LiveModels.live) async throws {
        guard !closed, socket == nil, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveVoiceError("A voice connection needs an API key and a fresh session")
        }
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let transport = URLSession(configuration: configuration)
        self.transport = transport
        let task = transport.webSocketTask(with: request)
        task.maximumMessageSize = 262144
        socket = task; task.resume()
        receiver = Task { [weak self] in await self?.receive(task) }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            await self?.fail("The voice connection timed out")
        }
        do { try await send(LiveProtocol.start(instructions: instructions, context: context, model: model,
                                             delegationEnabled: delegation != nil)) }
        catch { await fail(error.localizedDescription); throw error }
        if connected { return }
        guard !closed else { throw LiveVoiceError("The voice connection closed during startup") }
        try await withCheckedThrowingContinuation { ready = $0 }
    }

    private func receive(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled && !closed {
                let message = try await task.receive()
                guard !closed else { return }
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: continue
                }
                await handleServerEvent(data)
            }
        } catch { if !closed && !Task.isCancelled { await fail(error.localizedDescription) } }
    }

    func handleServerEvent(_ data: Data) async {
        guard !closed else { return }
        do {
            switch try LiveProtocol.decode(data, includeDelegationEvents: delegation != nil) {
            case .ready:
                connected = true; timeout?.cancel(); timeout = nil
                ready?.resume(); ready = nil
            case .audio(let pcm):
                guard connected else { throw LiveVoiceError("Voice audio arrived before readiness") }
                try await audio(pcm)
            case .transcript(let text, let isAssistant): await transcript(text, isAssistant)
            case .error(let text): throw LiveVoiceError(text)
            case .closed: throw LiveVoiceError("The voice service closed the session")
            case .delegation(let event):
                guard let delegation else { return }
                guard connected else { throw LiveVoiceError("Voice delegation arrived before readiness") }
                guard let batch = try delegationState.accept(event) else { return }
                guard delegationTasks.count < 4 else { throw LiveVoiceError("Too many voice delegations are awaiting results") }
                // The receive loop must never await private facts or decisions.
                // Each batch reserves its deduplication state before this task
                // can suspend. Close cancels every task and retires the state.
                delegationTasks[batch.id] = Task { [weak self] in
                    await self?.run(batch, handler: delegation)
                }
            case .ignored: break
            }
        } catch { if !closed && !Task.isCancelled { await fail(error.localizedDescription) } }
    }

    private func run(_ batch: LiveDelegationBatch, handler: DelegationHandler) async {
        defer { delegationTasks.removeValue(forKey: batch.id) }
        do {
            for call in batch.calls {
                guard connected, !closed, !Task.isCancelled else { return }
                let output: String
                do {
                    let arguments = try LiveProtocol.checkedToolArguments(call)
                    output = try await handler(call.name, arguments, call.callID)
                    guard output.utf8.count <= 32000 else { throw LiveVoiceError("Voice tool result exceeded its size limit") }
                } catch {
                    guard !closed, !Task.isCancelled else { return }
                    let message = LiveVoiceError(error.localizedDescription).message
                    let bytes = try JSONSerialization.data(withJSONObject: ["error": String(message.prefix(1800))])
                    try await send(LiveProtocol.toolOutput(callID: call.callID, output: String(decoding: bytes, as: UTF8.self)))
                    continue
                }
                guard connected, !closed, !Task.isCancelled else { return }
                try await send(LiveProtocol.toolOutput(callID: call.callID, output: output))
            }
            guard connected, !closed, !Task.isCancelled else { return }
            // Exactly one continuation per completed batch, after all results.
            // The Live schema does not accept a delegation_id on this event.
            try await send(["type": "response.create"])
        } catch { if !closed && !Task.isCancelled { await fail(error.localizedDescription) } }
    }

    public func sendInput(_ encodedPCM: String) async throws {
        guard connected, !closed else { throw LiveVoiceError("Voice input is not connected") }
        guard encodedPCM.utf8.count <= 64000, let bytes = Data(base64Encoded: encodedPCM),
              !bytes.isEmpty, bytes.count.isMultiple(of: 2), bytes.base64EncodedString() == encodedPCM else {
            throw LiveVoiceError("Invalid microphone/caller audio")
        }
        try await send(["type": "session.input_audio.append", "audio": encodedPCM])
    }
    public func instruct(_ content: String) async throws {
        guard connected, !closed else { throw LiveVoiceError("Voice is not connected") }
        try await send(LiveProtocol.instructions(content))
    }
    private func send(_ event: [String: Any]) async throws {
        guard !closed else { throw LiveVoiceError("Voice transport is closed") }
        let bytes = try JSONSerialization.data(withJSONObject: event)
        if let eventSender { try await eventSender(bytes); return }
        guard let socket else { throw LiveVoiceError("Voice transport is closed") }
        try await Self.sendWithDeadline(.string(String(decoding: bytes, as: UTF8.self)), socket: socket)
    }
    private func fail(_ message: String) async {
        guard !closed else { return }
        let error = LiveVoiceError(message)
        close(error: error)
        await failure(error.message)
    }
    public func close() { close(error: LiveVoiceError("Voice connection cancelled")) }
    private func close(error: Error) {
        closed = true; connected = false
        delegationState.close()
        for task in delegationTasks.values { task.cancel() }
        delegationTasks.removeAll()
        ready?.resume(throwing: error); ready = nil
        timeout?.cancel(); timeout = nil
        receiver?.cancel(); receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        transport?.invalidateAndCancel(); transport = nil
    }

    private final class SendCompletion: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?
        init(_ value: CheckedContinuation<Void, Error>) { continuation = value }
        func finish(_ error: Error?) -> Bool {
            lock.lock(); let value = continuation; continuation = nil; lock.unlock()
            guard let value else { return false }
            if let error { value.resume(throwing: error) } else { value.resume() }
            return true
        }
    }
    private static func sendWithDeadline(_ message: URLSessionWebSocketTask.Message, socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completion = SendCompletion(continuation)
            socket.send(message) { error in _ = completion.finish(error) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if completion.finish(LiveVoiceError("Voice transport stopped accepting audio")) {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
        }
    }
}

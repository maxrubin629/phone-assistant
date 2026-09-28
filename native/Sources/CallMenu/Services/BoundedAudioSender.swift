import Foundation

/// Called only by the audio worker, never by a Core Audio realtime callback.
/// At most 500 ms of PCM and one network send can be pending. Overflow closes
/// the gate rather than dropping words or allowing latency to grow indefinitely.
final class BoundedAudioSender: @unchecked Sendable {
    typealias Transport = @Sendable (URLSessionWebSocketTask.Message) async throws -> Void
    private struct Frame { let pcm: Data; let epoch: String; let sequence: UInt64 }
    private let lock = NSLock()
    private let maximumBytes = 24_000
    private var queue: [Frame] = []
    private var queuedBytes = 0
    private var epoch: String?
    private var sequence: UInt64 = 0
    private var revision: UInt64 = 0
    private var draining = false
    private var transport: Transport?
    var onFailure: ((String, String) -> Void)?

    func open(epoch: String, socket: URLSessionWebSocketTask) {
        open(epoch: epoch) { message in try await Self.sendWithDeadline(message, socket: socket) }
    }

    /// The injected transport also makes epoch and backpressure tests independent
    /// of microphone permission, Core Audio, network availability, and API keys.
    func open(epoch: String, transport: @escaping Transport) {
        lock.lock()
        revision &+= 1
        queue.removeAll(keepingCapacity: true)
        queuedBytes = 0
        sequence = 0
        self.epoch = epoch
        self.transport = transport
        lock.unlock()
    }

    func close() {
        lock.lock()
        clearLocked()
        lock.unlock()
    }

    private func clearLocked() {
        revision &+= 1
        epoch = nil
        transport = nil
        queue.removeAll(keepingCapacity: true)
        queuedBytes = 0
    }

    func enqueue(_ pcm: Data, epoch packetEpoch: String) {
        lock.lock()
        guard let epoch, epoch == packetEpoch, !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
            lock.unlock()
            return
        }
        guard pcm.count + queuedBytes <= maximumBytes else {
            clearLocked()
            lock.unlock()
            onFailure?(epoch, "The backend could not accept audio in time. Routing stopped.")
            return
        }
        queue.append(Frame(pcm: pcm, epoch: epoch, sequence: sequence))
        sequence &+= 1
        queuedBytes += pcm.count
        let launch = !draining
        draining = true
        lock.unlock()
        if launch { Task.detached { [weak self] in await self?.drain() } }
    }

    private func next() -> (Frame, Transport, UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty, let transport else { draining = false; return nil }
        let frame = queue.removeFirst()
        queuedBytes -= frame.pcm.count
        return (frame, transport, revision)
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == value && epoch != nil
    }

    private func failIfCurrent(_ value: UInt64, message: String) {
        lock.lock()
        guard revision == value, let failedEpoch = epoch else { lock.unlock(); return }
        clearLocked()
        lock.unlock()
        onFailure?(failedEpoch, message)
    }

    private final class SendCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        @discardableResult func finish(_ error: Error?) -> Bool {
            lock.lock()
            let completion = continuation
            continuation = nil
            lock.unlock()
            guard let completion else { return false }
            if let error { completion.resume(throwing: error) }
            else { completion.resume() }
            return true
        }
    }

    private static func sendWithDeadline(_ message: URLSessionWebSocketTask.Message, socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completion = SendCompletion(continuation)
            socket.send(message) { error in completion.finish(error) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if completion.finish(AudioError.message("The audio connection stopped accepting data")) {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
        }
    }

    private func drain() async {
        while let (frame, transport, revision) = next() {
            guard isCurrent(revision) else { continue }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["type": "audio", "epoch": frame.epoch,
                    "sequence": frame.sequence, "audio": frame.pcm.base64EncodedString()])
                try await transport(.string(String(decoding: data, as: UTF8.self)))
            } catch {
                failIfCurrent(revision, message: error.localizedDescription)
            }
        }
    }
}

import Foundation

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private var failures: [String] = []
    private var waiting: CheckedContinuation<Void, Error>?
    var blockFirst = false

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw AudioError.message("Invalid test frame")
        }
        let block = record(object)
        if block {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock(); waiting = continuation; lock.unlock()
            }
        }
    }
    private func record(_ object: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        messages.append(object)
        return blockFirst && messages.count == 1
    }
    func fail(_ epoch: String) { lock.lock(); failures.append(epoch); lock.unlock() }
    func release(failing: Bool = false) {
        lock.lock(); let pending = waiting; waiting = nil; lock.unlock()
        if failing { pending?.resume(throwing: AudioError.message("Old transport failed")) }
        else { pending?.resume() }
    }
    var blocked: Bool { lock.lock(); defer { lock.unlock() }; return waiting != nil }
    var snapshot: ([[String: Any]], [String]) { lock.lock(); defer { lock.unlock() }; return (messages, failures) }
}

@main struct NativeTransportChecks {
    static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AudioError.message("Timed out waiting for deterministic transport check")
    }
    static func require(_ predicate: @autoclosure () -> Bool, _ message: String) throws {
        if !predicate() { throw AudioError.message(message) }
    }
    static func main() async throws {
        let sender = BoundedAudioSender(), recorder = Recorder()
        sender.onFailure = { epoch, _ in recorder.fail(epoch) }
        let pcm = Data(repeating: 1, count: 960)
        sender.enqueue(pcm, epoch: "closed")
        recorder.blockFirst = true
        sender.open(epoch: "old") { try await recorder.send($0) }
        sender.enqueue(pcm, epoch: "old")
        try await waitUntil { recorder.blocked }
        sender.enqueue(pcm, epoch: "old") // Queued old speech must be removed.
        sender.close()
        sender.open(epoch: "new") { try await recorder.send($0) }
        sender.enqueue(pcm, epoch: "old") // Delayed worker callback must be dropped.
        sender.enqueue(pcm, epoch: "new")
        recorder.release(failing: true) // Retired failure must not clear the new epoch.
        try await waitUntil { recorder.snapshot.0.count == 2 }
        let snapshot = recorder.snapshot
        try require(snapshot.1.isEmpty, "A retired failure closed the new epoch")
        try require(snapshot.0.map { $0["epoch"] as? String } == ["old", "new"], "Stale speech escaped")
        try require(snapshot.0.map { ($0["sequence"] as? NSNumber)?.intValue } == [0, 0], "Epoch sequence did not reset")
        sender.close()

        let blockedSender = BoundedAudioSender(), blocked = Recorder()
        blocked.blockFirst = true
        blockedSender.onFailure = { epoch, _ in blocked.fail(epoch) }
        blockedSender.open(epoch: "bounded") { try await blocked.send($0) }
        blockedSender.enqueue(pcm, epoch: "bounded")
        try await waitUntil { blocked.blocked }
        for _ in 0..<26 { blockedSender.enqueue(pcm, epoch: "bounded") }
        try require(blocked.snapshot.1 == ["bounded"], "500 ms overflow did not close the gate exactly once")
        blockedSender.enqueue(pcm, epoch: "bounded")
        blocked.release()
        try await Task.sleep(for: .milliseconds(30))
        try require(blocked.snapshot.0.count == 1, "Queued speech survived a backpressure fault")
        print("Native transport checks passed: epoch flush, stale callbacks, retired failure, sequence reset, bounded overflow.")
    }
}

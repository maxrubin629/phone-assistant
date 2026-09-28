import Darwin
import Foundation

private enum LocalSocketIO {
    static func descriptor() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PhoneControlError("Could not open the local control connection") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        return fd
    }

    static func address(_ url: URL) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(url.path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw PhoneControlError("The local control socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }

    static func checkPeer(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            throw PhoneControlError("The control connection must belong to this Mac user")
        }
    }

    static func wait(_ fd: Int32, events: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw PhoneControlError("Phone Assistant did not respond in time; check its status before retrying") }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(1000, ceil(remaining * 1000))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw PhoneControlError("Local control connection failed") }
            if result == 0 { continue }
            if item.revents & events != 0 { return }
            if events == Int16(POLLIN), item.revents & Int16(POLLHUP) != 0 { return }
            throw PhoneControlError("Phone Assistant closed the control connection")
        }
    }

    static func connect(_ fd: Int32, to url: URL, until deadline: TimeInterval) throws {
        var address = try address(url)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw PhoneControlError("Open Phone Assistant, then try again. Its local connection is unavailable.") }
            try wait(fd, events: Int16(POLLOUT), until: deadline)
            var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw PhoneControlError("Open Phone Assistant, then try again. Its local connection is unavailable.")
            }
        }
        try checkPeer(fd)
    }

    static func readFrame(_ fd: Int32, until deadline: TimeInterval) throws -> Data {
        var accumulated = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(fd, events: Int16(POLLIN), until: deadline)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw PhoneControlError("Phone Assistant closed the control connection") }
            accumulated.append(contentsOf: bytes.prefix(count))
            guard accumulated.count <= PhoneControlProtocol.maximumFrameBytes else { throw PhoneControlError("Control message is too large") }
            if let newline = accumulated.firstIndex(of: 10) {
                guard newline == accumulated.index(before: accumulated.endIndex) else {
                    throw PhoneControlError("One request is allowed per control connection")
                }
                return accumulated.prefix(upTo: newline)
            }
        }
    }

    static func write(_ data: Data, to fd: Int32, until deadline: TimeInterval) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, events: Int16(POLLOUT), until: deadline)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw PhoneControlError("Could not send the control message") }
                offset += count
            }
        }
    }

    static func privateDirectory(_ url: URL, create: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard create, errno == ENOENT, mkdir(url.path, 0o700) == 0 else {
                throw PhoneControlError("Open Phone Assistant to enable its local connection")
            }
            guard lstat(url.path, &info) == 0 else { throw PhoneControlError("Could not inspect the local control directory") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw PhoneControlError("The local control directory must be a private folder owned by this Mac user")
        }
    }

    static func socketInfo(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            throw PhoneControlError("Open Phone Assistant to enable its private local connection")
        }
        return info
    }
}

public final class LocalControlClient {
    private let socketURL: URL
    private let timeout: TimeInterval
    public init(socketURL: URL = PhoneControlPaths.socketURL, timeout: TimeInterval = 40) {
        self.socketURL = socketURL; self.timeout = timeout
    }
    public func request(_ request: [String: Any]) throws -> [String: Any] {
        try LocalSocketIO.privateDirectory(socketURL.deletingLastPathComponent(), create: false)
        _ = try LocalSocketIO.socketInfo(socketURL)
        let data = try PhoneControlProtocol.encode(request)
        let fd = try LocalSocketIO.descriptor(); defer { Darwin.close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try LocalSocketIO.connect(fd, to: socketURL, until: deadline)
        try LocalSocketIO.write(data, to: fd, until: deadline)
        return try PhoneControlProtocol.decode(LocalSocketIO.readFrame(fd, until: deadline))
    }
}

public final class LocalControlServer: @unchecked Sendable {
    private let socketURL: URL
    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: 8)
    private var listening: Int32 = -1
    private var fileLock: Int32 = -1
    private var socketIdentity: stat?
    private var generation = UUID()
    private var clients = Set<Int32>()
    private var work = [Int32: Task<Void, Never>]()
    public init(socketURL: URL = PhoneControlPaths.socketURL) { self.socketURL = socketURL }
    deinit { stop() }

    public func start(handler: @escaping @Sendable ([String: Any]) async -> [String: Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard listening < 0 else { return }
        let directory = socketURL.deletingLastPathComponent()
        try LocalSocketIO.privateDirectory(directory, create: true)
        let lockFD = open(directory.appendingPathComponent("control.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw PhoneControlError("Could not lock the local control directory") }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(), lockInfo.st_mode & 0o777 == 0o600,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            throw PhoneControlError("Another Phone Assistant instance owns the local control connection")
        }
        var fd: Int32 = -1, bound = false
        do {
            var old = stat()
            if lstat(socketURL.path, &old) == 0 {
                _ = try LocalSocketIO.socketInfo(socketURL)
                let probe = try LocalSocketIO.descriptor()
                defer { Darwin.close(probe) }
                var address = try LocalSocketIO.address(socketURL)
                let status = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }}
                guard status != 0, errno == ECONNREFUSED else { throw PhoneControlError("A live app already owns the local control socket") }
                let rechecked = try LocalSocketIO.socketInfo(socketURL)
                guard rechecked.st_ino == old.st_ino, rechecked.st_dev == old.st_dev, unlink(socketURL.path) == 0 else {
                    throw PhoneControlError("The local control socket changed during startup")
                }
            } else if errno != ENOENT { throw PhoneControlError("Could not inspect the local control socket") }
            fd = try LocalSocketIO.descriptor()
            var address = try LocalSocketIO.address(socketURL)
            let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }}
            guard result == 0 else { throw PhoneControlError("Could not bind the local control socket") }
            bound = true
            guard chmod(socketURL.path, 0o600) == 0, listen(fd, 8) == 0 else { throw PhoneControlError("Could not prepare the local control socket") }
            socketIdentity = try LocalSocketIO.socketInfo(socketURL)
            listening = fd; fileLock = lockFD; generation = UUID()
            let run = generation
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptLoop(fd, generation: run, handler: handler) }
        } catch {
            if fd >= 0 { Darwin.close(fd) }
            if bound { unlink(socketURL.path) }
            flock(lockFD, LOCK_UN); Darwin.close(lockFD)
            throw error
        }
    }

    private func acceptLoop(_ server: Int32, generation run: UUID, handler: @escaping @Sendable ([String: Any]) async -> [String: Any]) {
        while isCurrent(server, generation: run) {
            var item = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 250)
            if ready < 0 && errno == EINTR { continue }
            if ready <= 0 { continue }
            guard isCurrent(server, generation: run) else { break }
            let fd = accept(server, nil, nil)
            if fd < 0 { continue }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            guard slots.wait(timeout: .now()) == .success else { Darwin.close(fd); continue }
            lock.lock()
            if listening != server || generation != run { lock.unlock(); Darwin.close(fd); slots.signal(); break }
            clients.insert(fd); lock.unlock()
            DispatchQueue.global(qos: .utility).async { self.serve(fd, generation: run, handler: handler) }
        }
    }

    private func isCurrent(_ fd: Int32, generation run: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return listening == fd && generation == run }

    private final class ResponseBox: @unchecked Sendable {
        let lock = NSLock()
        var value: [String: Any] = [:]
        func store(_ next: [String: Any]) { lock.lock(); value = next; lock.unlock() }
        func take() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func serve(_ fd: Int32, generation run: UUID, handler: @escaping @Sendable ([String: Any]) async -> [String: Any]) {
        defer {
            lock.lock(); clients.remove(fd); work.removeValue(forKey: fd); lock.unlock()
            Darwin.close(fd); slots.signal()
        }
        do {
            try LocalSocketIO.checkPeer(fd)
            let request = try PhoneControlProtocol.decode(LocalSocketIO.readFrame(fd, until: ProcessInfo.processInfo.systemUptime + 5))
            let completed = DispatchSemaphore(value: 0), box = ResponseBox()
            lock.lock()
            guard listening >= 0, generation == run else { lock.unlock(); return }
            let task = Task {
                guard !Task.isCancelled else { completed.signal(); return }
                box.store(await handler(request)); completed.signal()
            }
            work[fd] = task; lock.unlock()
            guard completed.wait(timeout: .now() + 35) == .success else {
                task.cancel(); throw PhoneControlError("The operation timed out; check call status before retrying")
            }
            let response = try PhoneControlProtocol.encode(box.take())
            try LocalSocketIO.write(response, to: fd, until: ProcessInfo.processInfo.systemUptime + 3)
        } catch {
            if let response = try? PhoneControlProtocol.encode(["error": error.localizedDescription]) {
                try? LocalSocketIO.write(response, to: fd, until: ProcessInfo.processInfo.systemUptime + 1)
            }
        }
    }

    public func stop() {
        lock.lock()
        let fd = listening, lockFD = fileLock, identity = socketIdentity
        listening = -1; fileLock = -1; socketIdentity = nil; generation = UUID()
        for client in clients { shutdown(client, SHUT_RDWR) }
        for task in work.values { task.cancel() }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        if let identity, let current = try? LocalSocketIO.socketInfo(socketURL),
           identity.st_ino == current.st_ino, identity.st_dev == current.st_dev { unlink(socketURL.path) }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }
        lock.unlock()
    }
}

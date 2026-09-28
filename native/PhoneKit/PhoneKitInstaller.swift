import Foundation
import CoreAudio
import CryptoKit
import Security
import Darwin

// Built separately and nested-code-signed by stage_app.py. It accepts no caller-selected paths.
enum KitError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}
let driverName = "CodexCallSend.driver"
let driverID = "com.codexcall.audio.send"
let deviceUID = "com.codexcall.audio.send.device"
let feedDeviceUID = "com.codexcall.audio.send.feed"
let halDirectory = "/Library/Audio/Plug-Ins/HAL"
let fm = FileManager.default

struct KitStatus: Codable {
    var bundledValid = false
    var installed = false
    var installedValid = false
    var updateAvailable = false
    var loaded = false
    var pluginRegistered = false
    var deviceUID = "com.codexcall.audio.send.device"
    var deviceID: UInt32 = 0
    var feedDeviceID: UInt32 = 0
    var activation = "notInstalled"
    var message = "Phone Assistant Audio Bridge is not enabled."
}

func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw KitError.invalid(message) }
}

func directoryFD(_ path: String, protected: Bool = false) throws -> Int32 {
    try check(path.hasPrefix("/"), "An absolute installation path is required.")
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try check(fd >= 0, "Cannot open the filesystem root.")
    do {
        for part in path.split(separator: "/") {
            try check(part != "." && part != "..", "Relative path components are not allowed.")
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try check(next >= 0, "Cannot open \(path); missing directories and symbolic links are refused.")
            close(fd); fd = next
            if protected {
                var info = stat()
                try check(fstat(fd, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0,
                          "Installation directories must be owned by root and not writable by other users.")
            }
        }
        return fd
    } catch { close(fd); throw error }
}

func readFile(_ root: Int32, _ relative: String) throws -> Data {
    let parts = relative.split(separator: "/").map(String.init)
    try check(!parts.isEmpty && !relative.hasPrefix("/") && !parts.contains("..") && !parts.contains("."), "Invalid bundled file path.")
    var parent = dup(root)
    defer { close(parent) }
    for part in parts.dropLast() {
        let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try check(next >= 0, "A bundled directory is missing or is a symbolic link.")
        close(parent); parent = next
    }
    let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    try check(fd >= 0, "A bundled file is missing or is a symbolic link: \(relative)")
    defer { close(fd) }
    var info = stat()
    try check(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_size >= 0 && info.st_size <= 32 * 1024 * 1024,
              "Phone Assistant Audio Bridge only accepts regular, single-link files up to 32 MB.")
    var data = Data(); var bytes = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = read(fd, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        try check(count >= 0, "Unable to read a bundled file.")
        if count == 0 { break }
        data.append(contentsOf: bytes.prefix(count))
        try check(data.count <= 32 * 1024 * 1024, "A bundled file changed during validation.")
    }
    return data
}

func signedBundle(_ url: URL, requirementText: String? = nil) throws {
    var code: SecStaticCode?
    try check(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, "Cannot inspect the Phone Assistant Audio Bridge signature.")
    var requirement: SecRequirement?
    try check(SecRequirementCreateWithString((requirementText ?? "identifier \"\(driverID)\"") as CFString, [], &requirement) == errSecSuccess,
              "Cannot construct the Phone Assistant Audio Bridge signature requirement.")
    try check(SecStaticCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), requirement) == errSecSuccess,
              "Phone Assistant Audio Bridge's signature or identity is invalid.")
}

func relativeFiles(_ root: Int32, prefix: String = "", requireRootOwnership: Bool = false) throws -> Set<String> {
    guard let directory = fdopendir(dup(root)) else { throw KitError.invalid("Cannot inspect Phone Assistant Audio Bridge's directory entries.") }
    defer { closedir(directory) }
    var result = Set<String>()
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        var info = stat()
        try check(fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0, "Phone Assistant Audio Bridge changed while being inspected.")
        if requireRootOwnership {
            try check(info.st_uid == 0 && info.st_mode & 0o022 == 0, "Installed Phone Assistant Audio Bridge files must be owned by root and not writable by other users.")
        }
        let relative = prefix.isEmpty ? name : prefix + "/" + name
        if info.st_mode & S_IFMT == S_IFDIR {
            try check(relative.split(separator: "/").count <= 6, "Phone Assistant Audio Bridge contains an unexpected directory tree.")
            let child = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try check(child >= 0, "Phone Assistant Audio Bridge contains a symbolic link or unreadable directory.")
            defer { close(child) }
            result.formUnion(try relativeFiles(child, prefix: relative, requireRootOwnership: requireRootOwnership))
        } else {
            try check(info.st_mode & S_IFMT == S_IFREG, "Phone Assistant Audio Bridge may not contain symbolic links or special files.")
            result.insert(relative)
        }
        try check(result.count <= 64, "Phone Assistant Audio Bridge contains unexpected files.")
    }
    return result
}

func readBundle(_ url: URL, requireRootOwnership: Bool = false) throws -> [String: Data] {
    let root = try directoryFD(url.path, protected: requireRootOwnership); defer { close(root) }
    let actualFiles = try relativeFiles(root, requireRootOwnership: requireRootOwnership)
    var files: [String: Data] = [:]
    for path in actualFiles { files[path] = try readFile(root, path) }
    guard let plist = files["Contents/Info.plist"],
          let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { throw KitError.invalid("Phone Assistant Audio Bridge has no valid Info.plist.") }
    try check(info["CFBundleIdentifier"] as? String == driverID && info["CFBundleExecutable"] as? String == "CodexCallSend",
              "Phone Assistant Audio Bridge's bundle identity is unexpected.")
    guard let binary = files["Contents/MacOS/CodexCallSend"] else { throw KitError.invalid("Phone Assistant Audio Bridge is missing its driver.") }
    let header = [UInt8](binary.prefix(8))
    try check(header == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1], "Phone Assistant Audio Bridge requires an Apple Silicon-only driver.")
    try signedBundle(url)
    return files
}

func fingerprints(_ files: [String: Data]) -> [String: String] {
    files.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
}
func snapshot(_ url: URL, requireRootOwnership: Bool = false) throws -> [String: Data] {
    let files = try readBundle(url, requireRootOwnership: requireRootOwnership)
    try check(fingerprints(files) == PhoneKitBuild.files, "Phone Assistant Audio Bridge differs from the bundled payload.")
    return files
}
func bundleVersion(_ files: [String: Data]) throws -> [Int] {
    guard let data = files["Contents/Info.plist"],
          let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let version = info["CFBundleVersion"] as? String else { throw KitError.invalid("Missing kit version.") }
    let parts = version.split(separator: ".").compactMap { Int($0) }
    try check(!parts.isEmpty && parts.count <= 3 && parts.count == version.split(separator: ".").count &&
              parts.allSatisfy { $0 >= 0 }, "Invalid kit version.")
    return parts + Array(repeating: 0, count: 3 - parts.count)
}
func equivalentPayload(_ url: URL, files: [String: Data]) throws -> Bool {
    if fingerprints(files) == PhoneKitBuild.files { return true }
    // Re-signing identical code changes its CMS signing time, not its code or
    // resources. Do not turn an app-only rebuild into a driver replacement.
    try signedBundle(url, requirementText: PhoneKitBuild.driverRequirement)
    var code: SecStaticCode?, information: CFDictionary?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let info = information as? [String: Any],
          let hash = info[kSecCodeInfoUnique as String] as? Data else { return false }
    let binary = "Contents/MacOS/CodexCallSend"
    return hash.map { String(format: "%02x", $0) }.joined() == PhoneKitBuild.driverCodeHash &&
        fingerprints(files).filter { $0.key != binary } == PhoneKitBuild.files.filter { $0.key != binary }
}
func upgradeCandidate(_ url: URL, requireRootOwnership: Bool = true) throws -> [String: Data] {
    let files = try readBundle(url, requireRootOwnership: requireRootOwnership)
    if (try? equivalentPayload(url, files: files)) == true { return files }
    // Old ad-hoc prototypes are accepted only by their entire compiled-in
    // fingerprint. A matching filename or device UID is never sufficient.
    if !PhoneKitBuild.legacyPayloads.contains(fingerprints(files)) {
        try signedBundle(url, requirementText: PhoneKitBuild.driverRequirement)
    }
    let previous = try bundleVersion(files), current = try bundleVersion(embeddedPayload())
    try check(previous.lexicographicallyPrecedes(current), "A newer or conflicting Phone Assistant Audio Bridge is installed. It was preserved.")
    return files
}

func translate(_ selector: AudioObjectPropertySelector, _ uid: String) -> AudioObjectID {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let qualifier = uid as CFString
    var qualifierPointer = Unmanaged.passUnretained(qualifier).toOpaque()
    var value: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &qualifierPointer, &size, &value)
    return result == noErr ? value : 0
}

func activeDevices() throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, "Cannot check whether Mac audio is busy.")
    var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr, "Cannot check whether Mac audio is busy.")
    var active: [AudioObjectID] = []
    for device in devices {
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        try check(result == noErr, "Cannot determine whether an audio device is in use. Close audio apps and try again.")
        if running != 0 { active.append(device) }
    }
    return active
}

func embeddedPayload() throws -> [String: Data] {
    var files: [String: Data] = [:]
    for (path, digest) in PhoneKitBuild.files {
        guard let encoded = PhoneKitBuild.payload[path], let data = Data(base64Encoded: encoded) else {
            throw KitError.invalid("Phone Assistant Audio Bridge's signed helper contains an invalid payload.")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try check(actual == digest, "Phone Assistant Audio Bridge's embedded payload is invalid.")
        files[path] = data
    }
    return files
}

func status(source: URL? = nil) -> KitStatus {
    var result = KitStatus()
    do {
        if let source { _ = try snapshot(source) } else { _ = try embeddedPayload() }
        result.bundledValid = true
    }
    catch { result.message = String(describing: error); result.activation = "invalidBundle"; return result }
    let destination = URL(fileURLWithPath: halDirectory).appendingPathComponent(driverName)
    var info = stat()
    result.installed = lstat(destination.path, &info) == 0
    if result.installed {
        do {
            let files = try upgradeCandidate(destination)
            result.updateAvailable = (try? equivalentPayload(destination, files: files)) != true
            result.installedValid = !result.updateAvailable
        }
        catch { result.activation = "conflict"; result.message = "An installed Phone Assistant Audio Bridge differs from this app. It was preserved."; return result }
    }
    result.deviceID = translate(kAudioHardwarePropertyTranslateUIDToDevice, deviceUID)
    result.feedDeviceID = translate(kAudioHardwarePropertyTranslateUIDToDevice, feedDeviceUID)
    result.pluginRegistered = translate(kAudioHardwarePropertyTranslateBundleIDToPlugIn, driverID) != 0
    result.loaded = result.installedValid && result.pluginRegistered && result.deviceID != 0 &&
        result.feedDeviceID != 0 && result.deviceID != result.feedDeviceID
    if result.loaded {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let ok = AudioObjectGetPropertyData(result.deviceID, &address, 0, nil, &size, &name) == noErr
        result.loaded = ok && (name?.takeRetainedValue() as String?) == "Phone Assistant"
        func streamBytes(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr ? size : nil
        }
        var hidden: UInt32 = 0
        address.mSelector = kAudioDevicePropertyIsHidden
        size = UInt32(MemoryLayout<UInt32>.size)
        let feedHidden = AudioObjectGetPropertyData(result.feedDeviceID, &address, 0, nil, &size, &hidden) == noErr && hidden == 1
        result.loaded = result.loaded && feedHidden &&
            streamBytes(result.deviceID, kAudioDevicePropertyScopeInput) == 4 &&
            streamBytes(result.deviceID, kAudioDevicePropertyScopeOutput) == 0 &&
            streamBytes(result.feedDeviceID, kAudioDevicePropertyScopeInput) == 0 &&
            streamBytes(result.feedDeviceID, kAudioDevicePropertyScopeOutput) == 4
    }
    if result.updateAvailable { result.activation = "updateAvailable"; result.message = "An update is ready. Enable Phone Assistant Audio Bridge to update the existing microphone without changing its identity."; return result }
    if result.loaded { result.activation = "ready"; result.message = "Phone Assistant Audio Bridge is enabled and its virtual microphone is available." }
    else if result.installed { result.activation = "installedNotLoaded"; result.message = "Phone Assistant Audio Bridge is installed, but macOS has not activated its virtual microphone." }
    return result
}

@discardableResult
func installFiles(_ files: [String: Data], in parent: Int32, parentPath: String = halDirectory,
                  replacing previous: [String: Data]? = nil) throws -> String? {
    let temporary = ".CodexCallSend.install-" + UUID().uuidString
    try check(mkdirat(parent, temporary, 0o700) == 0, "Cannot stage Phone Assistant Audio Bridge in the audio plug-in directory.")
    let stage = openat(parent, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try check(stage >= 0, "Cannot open the Phone Assistant Audio Bridge staging directory.")
    var committed = false
    defer {
        if !committed {
            for path in files.keys { _ = unlinkat(stage, path, 0) }
            let directories = Set(files.keys.flatMap { path -> [String] in
                let parts = path.split(separator: "/"); return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
            }).sorted { $0.count > $1.count }
            for path in directories { _ = unlinkat(stage, path, AT_REMOVEDIR) }
            _ = unlinkat(parent, temporary, AT_REMOVEDIR)
        }
        close(stage)
    }
    // Only fixed compiled-in file names are written. No recursive copy follows user-controlled links.
    for (path, data) in files.sorted(by: { $0.key < $1.key }) {
        let parts = path.split(separator: "/").map(String.init)
        var directory = dup(stage)
        defer { close(directory) }
        for part in parts.dropLast() {
            if mkdirat(directory, part, 0o755) != 0 { try check(errno == EEXIST, "Cannot create a Phone Assistant Audio Bridge directory.") }
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try check(next >= 0, "Cannot open a Phone Assistant Audio Bridge staging directory.")
            close(directory); directory = next
        }
        let executable = path == "Contents/MacOS/CodexCallSend"
        let fd = openat(directory, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, executable ? 0o755 : 0o644)
        try check(fd >= 0, "Cannot create a Phone Assistant Audio Bridge file.")
        do {
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < data.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: written), data.count - written)
                    if count < 0 && errno == EINTR { continue }
                    try check(count > 0, "Cannot write Phone Assistant Audio Bridge."); written += count
                }
            }
            try check(fsync(fd) == 0, "Cannot persist Phone Assistant Audio Bridge.")
            close(fd)
        } catch { close(fd); throw error }
    }
    try check(fchmod(stage, 0o755) == 0 && fsync(stage) == 0, "Cannot finalize Phone Assistant Audio Bridge staging.")
    let stagedURL = URL(fileURLWithPath: parentPath).appendingPathComponent(temporary)
    try signedBundle(stagedURL)
    if let previous {
        let existing = URL(fileURLWithPath: parentPath).appendingPathComponent(driverName)
        let verified = try upgradeCandidate(existing, requireRootOwnership: parentPath == halDirectory)
        try check(verified == previous, "The installed kit changed during the update. It was preserved.")
        try check(renameatx_np(parent, temporary, parent, driverName, UInt32(RENAME_SWAP)) == 0,
                  "Cannot atomically update Phone Assistant Audio Bridge. The existing installation was preserved.")
        committed = true
        _ = fsync(parent)
        // The previous bundle remains under a non-.driver name until activation succeeds.
        return temporary
    }
    try check(renameatx_np(parent, temporary, parent, driverName, UInt32(RENAME_EXCL)) == 0,
              "An installation already exists or appeared while enabling Phone Assistant Audio Bridge; it was preserved.")
    committed = true
    _ = fsync(parent)
    return nil
}

struct CoreAudioProcess: Equatable {
    let pid: pid_t
    let uid: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String
}

func coreAudioProcess(_ pid: pid_t) throws -> CoreAudioProcess {
    try check(pid > 1, "Invalid Core Audio process identifier.")
    var info = proc_bsdinfo()
    try check(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              "Cannot inspect the Core Audio process identity.")
    guard let account = getpwnam("_coreaudiod") else { throw KitError.invalid("Cannot resolve the system audio account.") }
    try check(info.pbi_uid == account.pointee.pw_uid && info.pbi_ppid == 1,
              "The audio process is not the expected launchd-managed system service.")
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    try check(proc_pidpath(pid, &path, UInt32(path.count)) > 0, "Cannot inspect the Core Audio executable.")
    let executable = String(cString: path)
    try check(executable == "/usr/sbin/coreaudiod", "Unexpected Core Audio executable; no process was signaled.")
    var code: SecCode?
    try check(SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              "Cannot verify the running Core Audio signature.")
    var requirement: SecRequirement?
    let requirementText = "anchor apple and identifier \"com.apple.audio.coreaudiod\""
    try check(SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              "Cannot construct the Apple audio signature requirement.")
    try check(SecCodeCheckValidity(code!, [], requirement) == errSecSuccess,
              "The running Core Audio process is not signed by Apple.")
    return CoreAudioProcess(pid: pid, uid: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
                            startMicroseconds: info.pbi_start_tvusec, executable: executable)
}

func findCoreAudioProcess() throws -> CoreAudioProcess {
    let count = proc_listallpids(nil, 0)
    try check(count > 0, "Cannot list processes to locate the system audio service.")
    var pids = [pid_t](repeating: 0, count: Int(count) + 128)
    let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    try check(actual > 0 && actual <= pids.count, "The process list changed while locating Core Audio; try Enable again.")
    var matches: [CoreAudioProcess] = []
    for pid in pids.prefix(Int(actual)) where pid > 1 {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path) == "/usr/sbin/coreaudiod" {
            matches.append(try coreAudioProcess(pid))
        }
    }
    try check(matches.count == 1, "Could not identify exactly one Apple system audio process; no process was signaled.")
    return matches[0]
}

func signalCoreAudio(_ expected: CoreAudioProcess,
                     inspect: (pid_t) throws -> CoreAudioProcess = coreAudioProcess,
                     send: (pid_t, Int32) -> Int32 = Darwin.kill) throws {
    let current = try inspect(expected.pid)
    try check(current == expected, "The Core Audio process changed during activation; try Enable again.")
    // The exact PID, system account, Apple signature, path and start time are checked above.
    if send(expected.pid, SIGKILL) != 0 {
        let code = errno
        throw KitError.invalid("macOS declined to reconnect Core Audio (errno \(code): \(String(cString: strerror(code)))). Phone Assistant Audio Bridge remains installed; no security setting was changed.")
    }
}

func activate() throws {
    let active = try activeDevices()
    try check(active.isEmpty, "Pause music and end calls before enabling Phone Assistant Audio Bridge. Mac audio briefly reconnects during setup.")
    try signalCoreAudio(findCoreAudioProcess())
}

func emit(_ result: KitStatus) {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(result) { FileHandle.standardOutput.write(data); print("") }
}

func preflight() throws -> KitStatus {
    _ = try embeddedPayload()
    let before = status()
    try check(before.activation != "conflict", before.message)
    let parent = try directoryFD(halDirectory, protected: true); defer { close(parent) }
    if !before.loaded || before.updateAvailable {
        let active = try activeDevices()
        try check(active.isEmpty, "Pause music and end calls before enabling Phone Assistant Audio Bridge. Mac audio briefly reconnects during setup.")
    }
    return before
}

func enablePhoneKit() -> KitStatus {
    do {
        try check(geteuid() == 0, "Use Enable Phone Assistant Audio Bridge in the app to authorize installation.")
        let files = try embeddedPayload()
        let before = try preflight()
        let parent = try directoryFD(halDirectory, protected: true); defer { close(parent) }
        umask(0o022)
        var backup: String?
        if before.updateAvailable {
            let old = try upgradeCandidate(URL(fileURLWithPath: halDirectory).appendingPathComponent(driverName))
            backup = try installFiles(files, in: parent, replacing: old)
        } else if !before.installed { try installFiles(files, in: parent) }
        if before.updateAvailable || !status().loaded { try activate() }
        let deadline = Date().addingTimeInterval(15)
        // The public UID can become visible before the hidden feed and stream
        // layout finish registering. Wait for the complete readiness contract.
        var result = status()
        while !result.loaded && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            result = status()
        }
        if result.loaded, let backup {
            // This name was created by the root helper in the protected HAL directory.
            try? fm.removeItem(at: URL(fileURLWithPath: halDirectory).appendingPathComponent(backup))
        }
        return result
    } catch {
        var result = status()
        result.message = String(describing: error)
        return result
    }
}

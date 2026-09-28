// Appended to a PHONE_KIT_TESTING build. No call to activate(), no /Library writes.
func expectedFailure(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw KitError.invalid("A hostile installer input was unexpectedly accepted.")
}

let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("PhoneKitChecks-" + UUID().uuidString)
try fm.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try snapshot(source)
let parent = try directoryFD(base.path)
defer { close(parent) }
try installFiles(files, in: parent, parentPath: base.path)
let installed = base.appendingPathComponent(driverName)
try check(try snapshot(installed) == files, "Installed bytes changed.")
try expectedFailure { try installFiles(files, in: parent, parentPath: base.path) }
try check(try snapshot(installed) == files, "An existing install was overwritten.")
try check(try fm.contentsOfDirectory(atPath: base.path) == [driverName], "Failed install left a staging directory.")

if CommandLine.arguments.count > 2 {
    let legacy = URL(fileURLWithPath: CommandLine.arguments[2])
    let old = try upgradeCandidate(legacy, requireRootOwnership: false)
    try check(fingerprints(old) != PhoneKitBuild.files, "Upgrade fixture must contain a previous version.")
    try fm.removeItem(at: installed)
    try fm.copyItem(at: legacy, to: installed)
    let backup = try installFiles(files, in: parent, parentPath: base.path, replacing: old)
    try check(try snapshot(installed) == files, "Upgrade did not install the new payload.")
    try check(try readBundle(base.appendingPathComponent(backup!)) == old, "Upgrade did not preserve the previous payload.")
    try check(try fm.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".driver") } == [driverName],
              "Upgrade created a duplicate driver.")
    try check(deviceUID == "com.codexcall.audio.send.device", "Upgrade changed the stable device UID.")
    try expectedFailure { try installFiles(files, in: parent, parentPath: base.path, replacing: old) }
    try check(try snapshot(installed) == files, "A stale upgrade overwrote a newer installation.")
    try fm.removeItem(at: base.appendingPathComponent(backup!))
    print("Existing-install upgrade passed: exact previous bytes, atomic replacement, preserved UID, one driver, stale-update rejection.")
}

let changed = base.appendingPathComponent("Tampered.driver")
try fm.copyItem(at: source, to: changed)
try Data("changed".utf8).write(to: changed.appendingPathComponent("Contents/Resources/APPLE-LICENSE.txt"))
try expectedFailure { _ = try snapshot(changed) }
try fm.removeItem(at: changed)
try fm.copyItem(at: source, to: changed)
let linkedFile = changed.appendingPathComponent("Contents/Resources/APPLE-LICENSE.txt")
try fm.removeItem(at: linkedFile)
try fm.createSymbolicLink(at: linkedFile, withDestinationURL: source.appendingPathComponent("Contents/Resources/APPLE-LICENSE.txt"))
try expectedFailure { _ = try snapshot(changed) }
let linkedDirectory = base.appendingPathComponent("Linked.driver")
try fm.createSymbolicLink(at: linkedDirectory, withDestinationURL: source)
try expectedFailure { _ = try snapshot(linkedDirectory) }
try fm.removeItem(at: changed)
try fm.copyItem(at: source, to: changed)
try Data("extra".utf8).write(to: changed.appendingPathComponent("extra"))
try expectedFailure { _ = try snapshot(changed) }
try expectedFailure { _ = try readFile(parent, "../outside") }
try check(try embeddedPayload() == files, "Embedded payload differs from validated bundle.")
let expectedProcess = CoreAudioProcess(pid: 1234, uid: 202, startSeconds: 10, startMicroseconds: 20, executable: "/usr/sbin/coreaudiod")
var signals: [(pid_t, Int32)] = []
try signalCoreAudio(expectedProcess, inspect: { _ in expectedProcess }, send: { pid, signal in signals.append((pid, signal)); return 0 })
try check(signals.count == 1 && signals[0].0 == 1234 && signals[0].1 == SIGKILL, "Activation did not target exactly the verified process.")
signals.removeAll()
let reusedPID = CoreAudioProcess(pid: 1234, uid: 202, startSeconds: 99, startMicroseconds: 20, executable: "/usr/sbin/coreaudiod")
try expectedFailure {
    try signalCoreAudio(expectedProcess, inspect: { _ in reusedPID }, send: { pid, signal in signals.append((pid, signal)); return 0 })
}
try check(signals.isEmpty, "Activation signaled a reused process identifier.")
do {
    try signalCoreAudio(expectedProcess, inspect: { _ in expectedProcess }, send: { _, _ in errno = EPERM; return -1 })
    throw KitError.invalid("Signal denial was treated as success.")
} catch { try check(String(describing: error).contains("errno 1"), "Signal error details were lost.") }
print("Phone Assistant Audio Bridge checks passed: exact embedded payload, atomic install, conflict preservation, cleanup, tampering, symlinks, traversal, exact-PID signaling, PID reuse and denied-signal errors. All signals were injected.")

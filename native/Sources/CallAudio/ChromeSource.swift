import AppKit
import CoreAudio
import Darwin
import Foundation
import Security

/// Selection is app-wide. Persistent identity excludes ephemeral process IDs.
public struct ApplicationAudioSource: Identifiable, Equatable, Sendable {
    public let name: String
    public let bundlePath: String
    public let mainProcessID: Int32
    public let audioProcessIDs: [UInt32]
    public let bundleID: String
    public let teamID: String
    public var id: String { bundleID + "|" + teamID + "|" + bundlePath }
    public init(name: String, bundlePath: String, mainProcessID: Int32, audioProcessIDs: [UInt32],
                bundleID: String, teamID: String) {
        self.name = name; self.bundlePath = bundlePath; self.mainProcessID = mainProcessID
        self.audioProcessIDs = audioProcessIDs.sorted(); self.bundleID = bundleID; self.teamID = teamID
    }
}

struct ChromeProcessIdentity: Equatable {
    let objectID: UInt32
    let pid: Int32
    let bundleID: String
    let signingID: String
    let teamID: String
    let executablePath: String
    let validSignature: Bool
    let runningOutput: Bool
    let ancestors: [Int32]
}

/// Requires both an OS-reported audio process and a valid Google-signed process
/// whose actual executable is contained in the selected Chrome bundle. A name
/// or bundle-ID prefix alone never authorizes another application's capture.
enum ChromeAttribution {
    static let bundleID = "com.google.Chrome"
    static let teamID = "EQHXZ8M8AV"
    static func supportedID(_ value: String) -> Bool {
        value == bundleID || value == bundleID + ".helper" || value.hasPrefix(bundleID + ".helper.")
    }
    /// macOS can run a still-open Chrome main executable from a code-sign clone
    /// while Launch Services and its helpers continue referring to the installed
    /// app. Accept only that observed clone layout, after validating the running
    /// main process's Google signature, identifier and PID below.
    private static func runtimeRoot(main: ChromeProcessIdentity, installedRoot: String) -> String? {
        let suffix = "/Contents/MacOS/Google Chrome"
        if main.executablePath == installedRoot + suffix { return installedRoot }
        guard main.executablePath.hasSuffix(suffix) else { return nil }
        let root = URL(fileURLWithPath: String(main.executablePath.dropLast(suffix.count)))
        let clone = root.deletingLastPathComponent()
        let owner = clone.deletingLastPathComponent()
        guard root.lastPathComponent == "Google Chrome.app.bundle",
              clone.lastPathComponent.hasPrefix("code_sign_clone."),
              owner.lastPathComponent == "com.google.Chrome.code_sign_clone",
              owner.deletingLastPathComponent().lastPathComponent == "X",
              root.path.hasPrefix("/var/folders/") || root.path.hasPrefix("/private/var/folders/") else { return nil }
        return root.path
    }
    static func select(bundlePath: String, mainPID: Int32, main: ChromeProcessIdentity,
                       processes: [ChromeProcessIdentity]) throws -> [UInt32] {
        let root = URL(fileURLWithPath: bundlePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard mainPID > 0, main.pid == mainPID, main.validSignature, main.teamID == teamID,
              main.bundleID == bundleID, main.signingID == bundleID,
              let runtimeRoot = runtimeRoot(main: main, installedRoot: root) else {
            throw CallAudioError("The selected Chrome instance could not be verified. Refresh the source list.")
        }
        return Array(Set(processes.filter { process in
            process.pid > 0 && process.objectID != 0 &&
            process.validSignature && process.teamID == teamID &&
            supportedID(process.bundleID) && supportedID(process.signingID) &&
            (process.executablePath.hasPrefix(root + "/Contents/") ||
             process.executablePath.hasPrefix(runtimeRoot + "/Contents/")) &&
            (process.pid == mainPID || (process.ancestors.contains(mainPID) &&
                (process.executablePath.contains("/Helpers/") || process.executablePath.contains("/Frameworks/"))))
        }.map(\.objectID))).sorted()
    }
    static func validateSelection(_ selected: ApplicationAudioSource, current: ApplicationAudioSource) throws {
        guard selected.id == current.id, selected.mainProcessID == current.mainProcessID, !selected.audioProcessIDs.isEmpty,
              selected.audioProcessIDs == current.audioProcessIDs else {
            throw CallAudioError("Chrome's audio process changed. Audio stopped; refresh Chrome and start the test again.")
        }
    }
}

/// Never infer shared system renderers from a bundle-name prefix. Helpers need
/// a valid signature, live ancestry, and an executable in the selected bundle.
enum ApplicationAttribution {
    static func select(bundlePath: String, mainPID: Int32, main: ChromeProcessIdentity,
                       processes: [ChromeProcessIdentity]) throws -> [UInt32] {
        if main.bundleID == ChromeAttribution.bundleID {
            return try ChromeAttribution.select(bundlePath: bundlePath, mainPID: mainPID, main: main, processes: processes)
        }
        let root = URL(fileURLWithPath: bundlePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard mainPID > 0, main.pid == mainPID, main.validSignature,
              !main.bundleID.isEmpty, main.signingID == main.bundleID,
              main.executablePath.hasPrefix(root + "/Contents/") else {
            throw CallAudioError("The selected application could not be verified. Refresh applications.")
        }
        return Array(Set(processes.filter { process in
            process.objectID != 0 && process.pid > 0 && process.validSignature &&
            process.teamID == main.teamID && process.executablePath.hasPrefix(root + "/Contents/") &&
            (process.pid == mainPID || process.ancestors.contains(mainPID))
        }.map(\.objectID))).sorted()
    }
    static func validateSelection(_ selected: ApplicationAudioSource, current: ApplicationAudioSource) throws {
        guard selected.id == current.id, selected.mainProcessID == current.mainProcessID,
              !selected.audioProcessIDs.isEmpty, selected.audioProcessIDs == current.audioProcessIDs else {
            throw CallAudioError("The application restarted or changed audio processes. Routing stopped. Choose Start to reconnect.")
        }
    }
}

enum ApplicationDiscovery {
    private static func ancestors(of pid: Int32) -> [Int32] {
        var result: [Int32] = [], current = pid
        for _ in 0..<16 {
            var information = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &information, size) == size else { break }
            let parent = Int32(information.pbi_ppid)
            guard parent > 1, parent != current, !result.contains(parent) else { break }
            result.append(parent); current = parent
        }
        return result
    }
    private static func identity(pid: Int32, objectID: UInt32, bundleID: String,
                                 runningOutput: Bool) throws -> ChromeProcessIdentity {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary,
                                             [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            throw CallAudioError("Application process identity could not be verified.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw CallAudioError("Application executable identity is unavailable.")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let information = information as? [String: Any],
              let signingID = information[kSecCodeInfoIdentifier as String] as? String,
              let executable = information[kSecCodeInfoMainExecutable as String] as? URL else {
            throw CallAudioError("Application signing identity is incomplete.")
        }
        let teamID = information[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        return .init(objectID: objectID, pid: pid, bundleID: bundleID, signingID: signingID,
            teamID: teamID, executablePath: executable.standardizedFileURL.resolvingSymlinksInPath().path,
            validSignature: true, runningOutput: runningOutput, ancestors: ancestors(of: pid))
    }
    static func sources(matching selection: ApplicationAudioSource? = nil) throws -> [ApplicationAudioSource] {
        let excluded = ["com.codexcall.menu", "com.apple.mobilephone", "com.apple.FaceTime"]
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && (selection == nil || $0.processIdentifier == selection!.mainProcessID) && $0.bundleURL != nil &&
            $0.bundleIdentifier != nil && !excluded.contains($0.bundleIdentifier!)
        }
        guard !apps.isEmpty else { return [] }
        let processes = try CallHardware.list(kAudioHardwarePropertyProcessObjectList).compactMap { id -> ChromeProcessIdentity? in
            guard let bundleID = try? CallHardware.string(id, kAudioProcessPropertyBundleID),
                  let pid = try? CallHardware.value(id, kAudioProcessPropertyPID, initial: pid_t(0)),
                  let output = try? CallHardware.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) else { return nil }
            if let selection, pid != selection.mainProcessID, !ancestors(of: pid).contains(selection.mainProcessID) { return nil }
            // Pausing YouTube changes this activity bit without changing the
            // process's identity. Keep verified idle processes in the tap so
            // pause/resume and gaps between repeated videos do not tear it down.
            return try? identity(pid: pid, objectID: id, bundleID: bundleID, runningOutput: output == 1)
        }
        return apps.compactMap { app -> ApplicationAudioSource? in
            guard let bundle = app.bundleURL, let bundleID = app.bundleIdentifier else { return nil }
            let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
            guard let main = try? identity(pid: app.processIdentifier, objectID: 0, bundleID: bundleID, runningOutput: false),
                  let ids = try? ApplicationAttribution.select(bundlePath: path, mainPID: app.processIdentifier,
                                                               main: main, processes: processes) else { return nil }
            return ApplicationAudioSource(name: app.localizedName ?? bundleID, bundlePath: path,
                mainProcessID: app.processIdentifier, audioProcessIDs: ids, bundleID: bundleID, teamID: main.teamID)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func validate(_ source: ApplicationAudioSource) throws {
        guard let current = try sources(matching: source).first(where: { $0.id == source.id }) else {
            throw CallAudioError("The selected application has quit. Its selection is saved. Reopen it and choose Start.")
        }
        try ApplicationAttribution.validateSelection(source, current: current)
    }
    static func isPlaying(_ source: ApplicationAudioSource) throws -> Bool {
        try source.audioProcessIDs.contains { id in
            try CallHardware.value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0
        }
    }
}

/// This tap has no physical subdevices and never captures the system mix.
/// Destroying it restores the application's normal output, including after a failed start.
final class ApplicationProcessTap {
    private let processes: [AudioObjectID]
    private let tapUUID = UUID()
    private var tap: AudioObjectID = 0
    private(set) var device: AudioDeviceID = 0
    init(processes: [AudioObjectID]) { self.processes = processes }
    func start() throws {
        guard !processes.isEmpty else { throw CallAudioError("Play audio in the selected application, refresh, then start.") }
        let description = CATapDescription(monoMixdownOfProcesses: processes)
        description.name = "Phone Assistant Application Audio"
        description.uuid = tapUUID; description.isPrivate = true; description.isExclusive = false
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) { description.isProcessRestoreEnabled = false }
        try CallHardware.check(AudioHardwareCreateProcessTap(description, &tap), "Create selected-application capture")
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Phone Assistant Application Audio Capture",
            kAudioAggregateDeviceUIDKey: "com.codexcall.chrome." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString,
                                             kAudioSubTapDriftCompensationKey: true]]
        ]
        try CallHardware.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "Create private application capture")
        for _ in 0..<40 {
            if (try? CallHardware.value(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) == 1 { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw CallAudioError("Application capture did not become ready.")
    }
    func close() throws {
        var failures: [String] = []
        if device != 0 {
            let status = AudioHardwareDestroyAggregateDevice(device)
            if status == noErr { device = 0 } else { failures.append("aggregate \(status)") }
        }
        if tap != 0 {
            let status = AudioHardwareDestroyProcessTap(tap)
            if status == noErr { tap = 0 } else { failures.append("tap \(status)") }
        }
        if !failures.isEmpty { throw CallAudioError("Application cleanup is incomplete: " + failures.joined(separator: ", ")) }
    }
    deinit { try? close() }
}

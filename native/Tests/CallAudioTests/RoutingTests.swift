import XCTest
import CallAudioDSP
@testable import CallAudio

final class RoutingTests: XCTestCase {
    private func source(pid: Int32 = 10, objects: [UInt32] = [20]) -> ApplicationAudioSource {
        .init(name: "Player", bundlePath: "/Applications/Player.app", mainProcessID: pid,
              audioProcessIDs: objects, bundleID: "org.example.player", teamID: "PLAYERTEAM")
    }
    func testSavedSelectionSurvivesRestartButRunningTapMustBeRebuilt() throws {
        let before = source(), after = source(pid: 11, objects: [21])
        XCTAssertEqual(before.id, after.id)
        XCTAssertThrowsError(try ApplicationAttribution.validateSelection(before, current: after))
        try ApplicationAttribution.validateSelection(after, current: after)
        var settings = RoutingPreferences()
        settings.applicationID = before.id; settings.microphoneUID = "usb-mic"; settings.monitorUID = "usb-output"
        settings.microphoneEnabled = true; settings.listenToSource = true
        let restored = try JSONDecoder().decode(RoutingPreferences.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(settings, restored)
        XCTAssertNil(restored.unavailable(applicationIDs: [after.id], microphoneUIDs: ["usb-mic"], outputUIDs: ["usb-output"]))
        XCTAssertNotNil(restored.unavailable(applicationIDs: [after.id], microphoneUIDs: ["different-mic"], outputUIDs: ["usb-output"]))
        XCTAssertNotNil(restored.unavailable(applicationIDs: [after.id], microphoneUIDs: ["usb-mic"], outputUIDs: ["different-output"]))
        XCTAssertNotNil(restored.unavailable(applicationIDs: [], microphoneUIDs: ["usb-mic"], outputUIDs: ["usb-output"]))
        XCTAssertNotNil(restored.unavailable(applicationIDs: [after.id, after.id], microphoneUIDs: ["usb-mic"], outputUIDs: ["usb-output"]))
        XCTAssertEqual(restored.microphoneUID, "usb-mic")
    }
    func testPreferencesStoragePreservesIDsAndHandlesCorruptData() {
        let suite = "CodexPhoneRoutingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = RoutingPreferences()
        settings.applicationID = source().id; settings.microphoneUID = "usb-stable-uid"
        settings.monitorUID = "headphone-stable-uid"; settings.sourceGain = 3.15
        settings.microphoneEnabled = true; settings.listenToSource = true
        settings.save(to: defaults)
        XCTAssertEqual(RoutingPreferences.load(from: UserDefaults(suiteName: suite)!), settings)
        settings.sourceGain = 99; settings.save(to: defaults)
        XCTAssertEqual(RoutingPreferences.load(from: defaults).sourceGain, 4)
        defaults.set(Data("not settings".utf8), forKey: "audioRouting.v1")
        XCTAssertEqual(RoutingPreferences.load(from: defaults), .init())
    }
    func testGenericApplicationIncludesOnlyItsVerifiedProcessTree() throws {
        let root = "/Applications/Player.app"
        func identity(_ id: UInt32, _ pid: Int32, path: String, team: String = "PLAYERTEAM",
                      parents: [Int32] = [10], valid: Bool = true) -> ChromeProcessIdentity {
            .init(objectID: id, pid: pid, bundleID: "org.example.player", signingID: "org.example.player",
                  teamID: team, executablePath: path, validSignature: valid, runningOutput: true, ancestors: parents)
        }
        let main = identity(20, 10, path: root + "/Contents/MacOS/Player", parents: [])
        let child = identity(21, 11, path: root + "/Contents/Helpers/Audio")
        let otherApp = identity(22, 12, path: "/Applications/Other.app/Contents/MacOS/Other")
        let otherInstance = identity(23, 13, path: root + "/Contents/Helpers/Audio", parents: [99])
        let wrongPublisher = identity(24, 14, path: root + "/Contents/Helpers/Audio", team: "OTHER")
        let unsigned = identity(25, 15, path: root + "/Contents/Helpers/Audio", valid: false)
        let sharedRenderer = identity(26, 16, path: "/System/Library/AudioRenderer")
        XCTAssertEqual(try ApplicationAttribution.select(bundlePath: root, mainPID: 10, main: main,
            processes: [main, child, otherApp, otherInstance, wrongPublisher, unsigned, sharedRenderer]), [20, 21])
    }
    func testIndependentCallerAndListeningRoutesAndEmergencyStop() throws {
        let controls = AudioControls()
        for flags in 0..<16 {
            let configuration = ApplicationAudioConfiguration(source: source(), microphoneEnabled: true,
                sourceGain: 1, microphoneGain: 1, sourceToCaller: flags & 1 != 0,
                microphoneToCaller: flags & 2 != 0, listenToSource: flags & 4 != 0, listenToMicrophone: flags & 8 != 0)
            cab_controls_set_routes(controls.pointer, configuration.callerRoutes.union(configuration.listeningRoutes).rawValue)
            cab_controls_set_send_muted(controls.pointer, false)
            let routes = cab_controls_snapshot(controls.pointer).routes
            var phone = [Float](repeating: 0, count: 1), monitor = phone
            cab_mix_mono([0.1], [0.2], &phone, nil, 1, 1, 1, 1, routes)
            cab_mix_monitor([0.1], [0.2], nil, &monitor, 1, 1, 1, routes)
            XCTAssertEqual(phone[0], (flags & 1 != 0 ? 0.2 : 0) + (flags & 2 != 0 ? 0.1 : 0), accuracy: 0.00001)
            XCTAssertEqual(monitor[0], (flags & 4 != 0 ? 0.2 : 0) + (flags & 8 != 0 ? 0.1 : 0), accuracy: 0.00001)
            cab_controls_set_send_muted(controls.pointer, true)
            let muted = cab_controls_snapshot(controls.pointer).routes
            cab_mix_mono([0.1], [0.2], &phone, nil, 1, 1, 1, 1, muted)
            XCTAssertEqual(phone, [0])
            var afterMute: [Float] = [0]
            cab_mix_monitor([0.1], [0.2], nil, &afterMute, 1, 1, 1, muted)
            XCTAssertEqual(afterMute, monitor)
        }
        let revision = cab_controls_revision(controls.pointer)
        cab_controls_cancel(controls.pointer)
        cab_controls_set_routes(controls.pointer, CallAudioRoutes.all.rawValue)
        XCTAssertFalse(cab_controls_enable_if_revision(controls.pointer, revision))
        XCTAssertEqual(cab_controls_snapshot(controls.pointer).routes, 0)
    }
    func testConversionForDeviceSampleRates() throws {
        for (from, to) in [(44100.0, 48000.0), (96000, 48000), (48000, 44100), (16000, 96000)] {
            let converter = try MonoConverter(from: from, to: to)
            var output: [Float] = []
            for _ in 0..<100 { output += try converter.convert(Array(repeating: Float(0.25), count: 480)) }
            XCTAssertLessThan(abs(Double(output.count) - 48000 * to / from), 256)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            XCTAssertEqual(output.suffix(100).reduce(0, +) / 100, 0.25, accuracy: 0.002)
        }
    }
}

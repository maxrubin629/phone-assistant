import XCTest
import CallAudioDSP
@testable import CallAudio

final class PhoneAudioTestTests: XCTestCase {
    func testLegacyPreferencesAndNativePlaybackPreserveSavedMonitor() throws {
        let oldJSON = Data("""
        {"applicationID":"com.codexcall.audio-test.phone","applicationName":"Phone",
        "microphoneUID":"saved-mic","microphoneName":"Microphone","monitorUID":"disconnected-headphones",
        "monitorName":"Headphones","microphoneEnabled":true,"sourceToCaller":false,"microphoneToCaller":true,
        "listenToSource":true,"listenToMicrophone":false,"sourceGain":1.96,"microphoneGain":1.06}
        """.utf8)
        var preferences = try JSONDecoder().decode(RoutingPreferences.self, from: oldJSON)
        let original = preferences
        XCTAssertFalse(preferences.usesNativePhonePlayback)
        XCTAssertTrue(preferences.phoneTestConfiguration.manageCallerListening)
        preferences.usesNativePhonePlayback = true
        let config = preferences.phoneTestConfiguration
        XCTAssertTrue(config.usesMicrophone)
        XCTAssertTrue(config.requirePhoneInput)
        XCTAssertFalse(config.manageCallerListening)
        XCTAssertFalse(config.needsListeningDevice)
        XCTAssertNil(config.monitorOutputUID)
        XCTAssertEqual(config.microphoneUID, "saved-mic")
        XCTAssertNil(preferences.unavailable(applicationIDs: [RoutingPreferences.phoneSourceID], microphoneUIDs: ["saved-mic"], outputUIDs: []))
        XCTAssertEqual(preferences.sourceGain, original.sourceGain)
        XCTAssertEqual(preferences.microphoneGain, original.microphoneGain)
        XCTAssertTrue(preferences.requiresRestart(comparedTo: original))
        preferences = try JSONDecoder().decode(RoutingPreferences.self, from: JSONEncoder().encode(preferences))
        preferences.usesNativePhonePlayback = false
        XCTAssertEqual(preferences.phoneTestConfiguration.monitorOutputUID, "disconnected-headphones")
        XCTAssertTrue(preferences.listenToSource)
        XCTAssertNotNil(preferences.unavailable(applicationIDs: [RoutingPreferences.phoneSourceID], microphoneUIDs: ["saved-mic"], outputUIDs: []))
    }

    func testPhoneSelectionRoundTripsWithoutMigratingExistingApplicationSettings() throws {
        var preferences = RoutingPreferences()
        preferences.applicationID = "existing-application-identity"
        preferences.microphoneUID = "saved-input"; preferences.monitorUID = "saved-output"
        XCTAssertEqual(try JSONDecoder().decode(RoutingPreferences.self,
            from: JSONEncoder().encode(preferences)), preferences)
        preferences.applicationID = RoutingPreferences.phoneSourceID
        preferences.microphoneEnabled = true; preferences.listenToSource = true
        let suite = "PhoneAudioTestTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.save(to: defaults)
        let restored = RoutingPreferences.load(from: defaults)
        XCTAssertTrue(restored.isPhoneTest)
        XCTAssertEqual(restored.microphoneUID, "saved-input")
        XCTAssertEqual(restored.monitorUID, "saved-output")
        XCTAssertFalse(restored.sourceToCaller)
        XCTAssertNil(restored.unavailable(applicationIDs: [RoutingPreferences.phoneSourceID],
            microphoneUIDs: ["saved-input"], outputUIDs: ["saved-output"]))
        XCTAssertNotNil(restored.unavailable(applicationIDs: [RoutingPreferences.phoneSourceID],
            microphoneUIDs: [], outputUIDs: ["saved-output"]))
    }

    func testPhoneTestNeverEnablesAgentOrModelRoutesEvenWithStaleApplicationFlags() {
        var preferences = RoutingPreferences()
        preferences.applicationID = RoutingPreferences.phoneSourceID
        preferences.sourceToCaller = true; preferences.listenToMicrophone = true
        preferences.microphoneEnabled = true
        let configuration = preferences.phoneTestConfiguration
        XCTAssertEqual(configuration.effectiveRoutes, [.microphoneToCaller, .callerToUser])
        XCTAssertTrue(configuration.requirePhoneInput)
        XCTAssertTrue(configuration.manageCallerListening)
        XCTAssertFalse(preferences.normalized().sourceToCaller)
        XCTAssertFalse(preferences.normalized().listenToMicrophone)
        // Production mixer: generated audio stays blocked, microphone sends,
        // caller audio is available only to the separate listening mixer.
        let controls = AudioControls()
        cab_controls_set_routes(controls.pointer, configuration.effectiveRoutes.rawValue)
        cab_controls_set_send_muted(controls.pointer, false)
        var outgoing: [Float] = [0], listening: [Float] = [0]
        let routes = cab_controls_snapshot(controls.pointer).routes
        cab_mix_mono([0.2], [0.9], &outgoing, nil, 1, 1, 1, 1, routes)
        cab_mix_monitor([0.7], [0.9], nil, &listening, 1, 1, 1, routes)
        XCTAssertEqual(outgoing[0], 0.2, accuracy: 0.00001)
        XCTAssertEqual(listening[0], 0.7, accuracy: 0.00001)
        cab_controls_set_send_muted(controls.pointer, true)
        let muted = cab_controls_snapshot(controls.pointer).routes
        cab_mix_mono([0.2], [0.9], &outgoing, nil, 1, 1, 1, 1, muted)
        cab_mix_monitor([0.7], [0.9], nil, &listening, 1, 1, 1, muted)
        XCTAssertEqual(outgoing, [0])
        XCTAssertEqual(listening[0], 0.7, accuracy: 0.00001)
    }

    func testPhoneMicrophoneOptInAndStopBeforeQueuedStart() throws {
        var preferences = RoutingPreferences()
        preferences.applicationID = RoutingPreferences.phoneSourceID
        XCTAssertFalse(preferences.phoneTestConfiguration.usesMicrophone)
        preferences.microphoneEnabled = true
        XCTAssertTrue(preferences.phoneTestConfiguration.usesMicrophone)
        preferences.microphoneToCaller = false
        XCTAssertFalse(preferences.phoneTestConfiguration.usesMicrophone)
        let runtime = CallAudioRuntime(), revision = runtime.lifecycleRevision
        runtime.stopAsync()
        XCTAssertThrowsError(try runtime.start(configuration: preferences.phoneTestConfiguration,
            epoch: "cancelled-test", expectedLifecycleRevision: revision)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cancelled before execution"))
        }
        try runtime.stopAndReport()
    }
}

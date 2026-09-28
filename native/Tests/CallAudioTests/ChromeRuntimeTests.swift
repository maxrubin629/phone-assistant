import XCTest
import CallAudioDSP
@testable import CallAudio

final class ChromeRuntimeTests: XCTestCase {
    private let root = "/Applications/Google Chrome.app"
    private func process(object: UInt32, pid: Int32, bundle: String = "com.google.Chrome.helper",
                         signing: String = "com.google.Chrome.helper", team: String = "EQHXZ8M8AV",
                         path: String? = nil, valid: Bool = true, running: Bool = true,
                         ancestors: [Int32] = [100]) -> ChromeProcessIdentity {
        .init(objectID: object, pid: pid, bundleID: bundle, signingID: signing, teamID: team,
            executablePath: path ?? root + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            validSignature: valid, runningOutput: running, ancestors: ancestors)
    }
    private var main: ChromeProcessIdentity {
        process(object: 10, pid: 100, bundle: "com.google.Chrome", signing: "com.google.Chrome",
                path: root + "/Contents/MacOS/Google Chrome", ancestors: [])
    }
    func testChromeAttributionIncludesVerifiedHelpersAndRejectsOtherInstancesAndImpersonators() throws {
        let first = process(object: 20, pid: 101)
        let second = process(object: 21, pid: 102, ancestors: [101, 100])
        let otherBrowser = process(object: 30, pid: 103, bundle: "com.apple.Safari")
        let unrelatedSignedProcess = process(object: 31, pid: 104, path: "/Applications/Other.app/Contents/MacOS/Other")
        let unsignedImpersonator = process(object: 32, pid: 105, valid: false)
        let wrongTeam = process(object: 33, pid: 106, team: "OTHERTEAM")
        let prefixImpersonator = process(object: 34, pid: 107, bundle: "com.google.Chrome.helperImpostor")
        let secondInstance = process(object: 35, pid: 108, ancestors: [200])
        let idle = process(object: 36, pid: 109, running: false)
        let lookalikePath = process(object: 37, pid: 110, path: root + ".other/Contents/Helpers/Fake")
        let selected = try ChromeAttribution.select(bundlePath: root, mainPID: 100, main: main,
            processes: [main, second, first, first, otherBrowser, unrelatedSignedProcess,
                        unsignedImpersonator, wrongTeam, prefixImpersonator, secondInstance, idle, lookalikePath])
        XCTAssertEqual(selected, [10, 20, 21, 36])
        XCTAssertThrowsError(try ChromeAttribution.select(bundlePath: root, mainPID: 200, main: main, processes: [first]))
        XCTAssertThrowsError(try ChromeAttribution.select(bundlePath: "/Applications/Other.app", mainPID: 100, main: main, processes: [first]))
    }
    func testPauseResumeKeepsVerifiedProcessSelectionStable() throws {
        func source(running: Bool) throws -> ApplicationAudioSource {
            let ids = try ChromeAttribution.select(bundlePath: root, mainPID: 100, main: main,
                processes: [process(object: 20, pid: 101, running: running)])
            return ApplicationAudioSource(name: "Chrome", bundlePath: root, mainProcessID: 100, audioProcessIDs: ids, bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV")
        }
        let playing = try source(running: true)
        let paused = try source(running: false)
        try ChromeAttribution.validateSelection(playing, current: paused)
        try ChromeAttribution.validateSelection(paused, current: playing)
        XCTAssertEqual(paused.audioProcessIDs, [20])
        XCTAssertFalse(ChromeMixPolicy.captureStalled(secondsWithoutBuffers: 60, sourcePlaying: false))
        XCTAssertFalse(ChromeMixPolicy.captureStalled(secondsWithoutBuffers: 0.1, sourcePlaying: true))
        XCTAssertTrue(ChromeMixPolicy.captureStalled(secondsWithoutBuffers: 0.6, sourcePlaying: true))
    }
    func testProcessRestartOrNewChromeRendererRequiresExplicitReselection() throws {
        let selected = ApplicationAudioSource(name: "Chrome", bundlePath: root, mainProcessID: 100, audioProcessIDs: [20, 21], bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV")
        try ChromeAttribution.validateSelection(selected, current: selected)
        for current in [
            ApplicationAudioSource(name: "Chrome", bundlePath: root, mainProcessID: 200, audioProcessIDs: [20, 21], bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV"),
            ApplicationAudioSource(name: "Chrome", bundlePath: root, mainProcessID: 100, audioProcessIDs: [20, 22], bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV"),
            ApplicationAudioSource(name: "Chrome", bundlePath: root, mainProcessID: 100, audioProcessIDs: [20], bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV"),
            ApplicationAudioSource(name: "Chrome", bundlePath: root, mainProcessID: 100, audioProcessIDs: [], bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV")
        ] { XCTAssertThrowsError(try ChromeAttribution.validateSelection(selected, current: current)) }
    }
    func testGoogleSignedMacOSCodeSignCloneRetainsExactMainAndHelperAttribution() throws {
        let cloneRoot = "/var/folders/test/user/X/com.google.Chrome.code_sign_clone/code_sign_clone.Observed/Google Chrome.app.bundle"
        let cloneMain = process(object: 10, pid: 100, bundle: "com.google.Chrome", signing: "com.google.Chrome",
                                path: cloneRoot + "/Contents/MacOS/Google Chrome", ancestors: [])
        let installedHelper = process(object: 20, pid: 101)
        let cloneHelper = process(object: 21, pid: 102,
            path: cloneRoot + "/Contents/Frameworks/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper")
        let otherCloneHelper = process(object: 22, pid: 103,
            path: cloneRoot.replacingOccurrences(of: ".Observed/", with: ".Other/") + "/Contents/Frameworks/Helpers/Google Chrome Helper")
        XCTAssertEqual(try ChromeAttribution.select(bundlePath: root, mainPID: 100, main: cloneMain,
            processes: [cloneMain, installedHelper, cloneHelper, otherCloneHelper]), [10, 20, 21])
        for badMain in [
            process(object: 10, pid: 100, bundle: "com.google.Chrome", signing: "com.google.Chrome", team: "OTHER",
                    path: cloneMain.executablePath, ancestors: []),
            process(object: 10, pid: 100, bundle: "com.google.Chrome", signing: "com.google.Chrome", valid: false,
                    ancestors: []),
            process(object: 10, pid: 100, bundle: "com.google.Chrome", signing: "com.google.Chrome",
                    path: "/tmp/com.google.Chrome.code_sign_clone/code_sign_clone.Fake/Google Chrome.app.bundle/Contents/MacOS/Google Chrome", ancestors: [])
        ] {
            XCTAssertThrowsError(try ChromeAttribution.select(bundlePath: root, mainPID: 100, main: badMain, processes: [installedHelper]))
        }
    }
    func testInjectedAudioUsesProductionMixerForChromeGainOptInMicAndMute() {
        let source: [Float] = [0.5, 0.25, -0.5, .nan]
        let microphone: [Float] = [0.25, 0.25, -0.25, .infinity]
        func mix(microphoneEnabled: Bool, muted: Bool) -> [Float] {
            var result = [Float](repeating: 0, count: source.count)
            var limiter = CABPeakLimiter()
            cab_peak_limiter_init(&limiter, 48000)
            source.withUnsafeBufferPointer { source in
                microphone.withUnsafeBufferPointer { microphone in
                    result.withUnsafeMutableBufferPointer { output in
                        cab_mix_phone_limited(&limiter, microphone.baseAddress, source.baseAddress, output.baseAddress,
                            source.count, 1, 0.5,
                            ChromeMixPolicy.routes(microphoneEnabled: microphoneEnabled, muted: muted).rawValue)
                    }
                }
            }
            return result
        }
        XCTAssertEqual(mix(microphoneEnabled: false, muted: false), [0.25, 0.125, -0.25, 0])
        XCTAssertEqual(mix(microphoneEnabled: true, muted: false), [0.5, 0.375, -0.5, 0])
        XCTAssertEqual(mix(microphoneEnabled: true, muted: true), [0, 0, 0, 0])
        XCTAssertEqual(ChromeMixPolicy.gain(.nan), 0)
        XCTAssertEqual(ChromeMixPolicy.gain(100), 4)
        XCTAssertEqual(ChromeMixPolicy.gain(-1), 0)
    }
    func testReferenceBoostLimitsCombinedPeaksWithoutFlatToppingAndReleases() {
        var limiter = CABPeakLimiter()
        cab_peak_limiter_init(&limiter, 48000)
        let source: [Float] = [0.2, 0.5, 0.9, -0.9, -0.5, -0.2]
        let microphone = source
        var output = [Float](repeating: 0, count: source.count)
        cab_mix_phone_limited(&limiter, microphone, source, &output, source.count, 0.53, 3.15,
                             ChromeMixPolicy.routes(microphoneEnabled: true, muted: false).rawValue)
        XCTAssertEqual(output[2], 0.98, accuracy: 0.00001)
        XCTAssertEqual(output[3], -0.98, accuracy: 0.00001)
        // All samples in the limiting block retain the same proportion, rather
        // than clipping samples above the ceiling to a flat line.
        for i in source.indices { XCTAssertEqual(output[i] / source[i], 0.98 / 0.9, accuracy: 0.00001) }
        let attackGain = limiter.gain
        let quiet = [Float](repeating: 0.1, count: 48000)
        var released = [Float](repeating: 0, count: quiet.count)
        cab_mix_phone_limited(&limiter, nil, quiet, &released, quiet.count, 0.53, 3.15, 2)
        XCTAssertGreaterThan(released.last!, released.first!)
        XCTAssertGreaterThan(limiter.gain, attackGain)
        XCTAssertEqual(released.last!, 0.315, accuracy: 0.001)
        let invalid: [Float] = [.nan, .infinity, -.infinity]
        var sanitized = [Float](repeating: 1, count: invalid.count)
        cab_mix_phone_limited(&limiter, invalid, invalid, &sanitized, invalid.count, 4, 4, 3)
        XCTAssertEqual(sanitized, [0, 0, 0])
        cab_mix_phone_limited(&limiter, microphone, source, &output, source.count, 0.53, 3.15, 0)
        XCTAssertEqual(output, Array(repeating: 0, count: source.count))
        XCTAssertEqual(limiter.gain, 1)
    }
    func testGenerationFlushDiscardsQueuedMusicBeforeResume() throws {
        let ring = try AudioRing(capacity: 8, generation: 1)
        XCTAssertEqual(ring.write([0.75, 0.75], generation: 1), 2)
        ring.flush(2)
        XCTAssertEqual(ring.write([0.99], generation: 1), 0)
        XCTAssertEqual(ring.write([0.25, 0.25], generation: 2), 2)
        XCTAssertEqual(ring.read(4, generation: 2), [0.25, 0.25])
    }
    func testStopCancelsQueuedStartBeforeAnyDeviceLookup() throws {
        let runtime = ApplicationAudioRuntime()
        let revision = runtime.lifecycleRevision
        runtime.stopAsync()
        let source = ApplicationAudioSource(name: "never-open", bundlePath: "/not-a-real-app", mainProcessID: 1, audioProcessIDs: [123], bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV")
        XCTAssertThrowsError(try runtime.start(configuration: .init(source: source), expectedLifecycleRevision: revision)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cancelled before execution"))
        }
        try runtime.stopAndReport()
    }
    func testNoActiveAudioDoesNotRequestPermissionsOrOpenDevices() {
        let source = ApplicationAudioSource(name: "idle", bundlePath: root, mainProcessID: 100, audioProcessIDs: [], bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV")
        XCTAssertThrowsError(try ApplicationAudioRuntime.preflight(.init(source: source))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Play audio"))
        }
    }
}

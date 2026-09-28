import CoreAudio
import CallAudioDSP
import XCTest
@testable import CallAudio

final class FollowingDeviceTests: XCTestCase {
    final class Endpoint: FollowingAudioEndpoint {
        let id: UInt32
        var started = false
        var failClose = false
        var failStart = false
        var onStart: (() -> Void)?
        var onClose: (() -> Void)?
        init(_ id: UInt32) { self.id = id }
        func start() throws {
            started = true; onStart?()
            if failStart { throw CallAudioError("not ready yet") }
        }
        func close() throws {
            if failClose { throw CallAudioError("still owned") }
            started = false; onClose?()
        }
    }
    func device(_ id: UInt32, rate: Double = 48000) -> AudioEndpointTarget {
        var format = AudioStreamBasicDescription()
        format.mSampleRate = rate; format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsFloat; format.mBitsPerChannel = 32
        format.mChannelsPerFrame = 2; format.mBytesPerFrame = 8
        return .init(id: id, uid: "device-\(id)", name: "Device \(id)", format: format)
    }
    func testFollowsDefaultAndReopensOnSampleRateChangeWithoutTouchingOtherEndpoint() throws {
        let input = FollowingDevice<Endpoint>(), output = FollowingDevice<Endpoint>()
        var selected = device(1, rate: 44100)
        var events: [String] = []
        func refresh(_ follower: FollowingDevice<Endpoint>, _ target: AudioEndpointTarget) throws {
            try follower.refresh(selection: .automatic, enabled: true, now: 1,
                resolve: { _ in target }, make: { descriptor in
                    events.append("open \(descriptor.id)")
                    let endpoint = Endpoint(descriptor.id)
                    endpoint.onClose = { events.append("close \(descriptor.id)") }
                    return endpoint
                }, willChange: {}, didClose: { events.append("clear") })
        }
        try refresh(input, device(3)); let originalInput = input.endpoint
        try refresh(output, selected); let originalOutput = output.endpoint
        selected = device(2)
        try refresh(output, selected)
        XCTAssertFalse(try XCTUnwrap(originalOutput).started)
        XCTAssertEqual(Array(events.suffix(3)), ["close 1", "clear", "open 2"])
        XCTAssertTrue(input.endpoint === originalInput)
        let secondOutput = output.endpoint
        try refresh(output, selected)
        XCTAssertTrue(output.endpoint === secondOutput)
        selected = device(2, rate: 16000)
        try refresh(output, selected)
        XCTAssertFalse(output.endpoint === secondOutput)
        XCTAssertEqual(output.target?.format.mSampleRate, 16000)
    }
    func testDisabledMicrophoneNeverResolvesOrOpensAndAgentModeDoesNotUseIt() throws {
        let follower = FollowingDevice<Endpoint>()
        XCTAssertFalse(try follower.refresh(selection: .automatic, enabled: false, now: 0,
            resolve: { _ in XCTFail("disabled input queried"); return self.device(1) },
            make: { _ in XCTFail("disabled input opened"); return Endpoint(1) }, willChange: {}))
        var config = CallAudioConfiguration(virtualOutputUID: "phone", microphoneEnabled: true)
        XCTAssertFalse(config.usesMicrophone)
        for mode in [CallAudioMode.join, .takeOver, .privateAside] {
            config.mode = mode; XCTAssertTrue(config.usesMicrophone)
        }
        config.microphoneEnabled = false; XCTAssertFalse(config.usesMicrophone)
    }
    func testMissingAutomaticDeviceClosesOldEndpointThenResumesWithoutUserAction() throws {
        let follower = FollowingDevice<Endpoint>()
        var selected: AudioEndpointTarget? = device(1)
        var opened = 0
        func refresh(_ now: TimeInterval) throws {
            try follower.refresh(selection: .automatic, enabled: true, now: now,
                resolve: { _ in guard let selected else { throw CallAudioError("no device") }; return selected },
                make: { opened += 1; return Endpoint($0.id) }, willChange: {})
        }
        try refresh(0); let first = follower.endpoint
        selected = nil; try refresh(1)
        XCTAssertFalse(try XCTUnwrap(first).started); XCTAssertNil(follower.endpoint); XCTAssertTrue(follower.waiting)
        try refresh(2); XCTAssertEqual(opened, 1)
        selected = device(2); try refresh(3)
        XCTAssertEqual(follower.target?.id, 2); XCTAssertFalse(follower.waiting)
    }
    func testFixedSelectionNeverFollowsDefaultOrFallsBackWhenMissing() throws {
        let follower = FollowingDevice<Endpoint>()
        var currentDefault = device(1)
        var fixedAvailable = true
        func refresh() throws {
            try follower.refresh(selection: .fixed("device-9"), enabled: true, now: 0,
                resolve: { selection in
                    switch selection {
                    case .automatic: return currentDefault
                    case .fixed(let uid):
                        XCTAssertEqual(uid, "device-9")
                        guard fixedAvailable else { throw CallAudioError("missing fixed device") }
                        return self.device(9)
                    }
                }, make: { Endpoint($0.id) }, willChange: {})
        }
        try refresh(); currentDefault = device(2); try refresh()
        XCTAssertEqual(follower.endpoint?.id, 9)
        fixedAvailable = false
        XCTAssertThrowsError(try refresh())
        XCTAssertNotEqual(follower.endpoint?.id, 2)
        try follower.reset(); XCTAssertNil(follower.endpoint)
    }
    func testOpenFailureIsCleanedAndRetriedWithoutRepeatedOpening() throws {
        let follower = FollowingDevice<Endpoint>()
        var attempts = 0
        var failed: Endpoint?
        func refresh(_ now: Double) throws {
            try follower.refresh(selection: .automatic, enabled: true, now: now,
                resolve: { _ in self.device(1) }, make: { target in
                    attempts += 1
                    let endpoint = Endpoint(target.id)
                    if attempts == 1 { endpoint.failStart = true; failed = endpoint }
                    return endpoint
                }, willChange: {})
        }
        try refresh(0); XCTAssertTrue(follower.waiting)
        XCTAssertFalse(try XCTUnwrap(failed).started); XCTAssertNil(follower.endpoint)
        try refresh(0.1); XCTAssertEqual(attempts, 1)
        try refresh(0.6); XCTAssertEqual(attempts, 2); XCTAssertTrue(try XCTUnwrap(follower.endpoint).started)
    }
    func testFailedCloseRetainsOwnershipAndNeverOpensSecondWriter() throws {
        let follower = FollowingDevice<Endpoint>()
        var selected = device(1), attempts = 0
        func refresh() throws {
            try follower.refresh(selection: .automatic, enabled: true, now: 0,
                resolve: { _ in selected }, make: { attempts += 1; return Endpoint($0.id) }, willChange: {})
        }
        try refresh(); let old = try XCTUnwrap(follower.endpoint); old.failClose = true
        selected = device(2)
        XCTAssertThrowsError(try refresh()); XCTAssertEqual(attempts, 1)
        XCTAssertTrue(follower.endpoint === old)
        old.failClose = false; try follower.reset(); XCTAssertNil(follower.endpoint)
    }
    func testStopDuringOpenClosesNewEndpointAndDoesNotRetry() throws {
        let follower = FollowingDevice<Endpoint>()
        var cancelled = false
        let endpoint = Endpoint(1)
        XCTAssertThrowsError(try follower.refresh(selection: .automatic, enabled: true, now: 0,
            resolve: { _ in self.device(1) }, make: { _ in cancelled = true; return endpoint },
            willChange: {}, isCancelled: { cancelled }))
        XCTAssertFalse(endpoint.started); XCTAssertNil(follower.endpoint)
    }
    func testLegacyDeviceSelectionsRemainFixedAndNewSelectionsAreAutomatic() throws {
        var legacy = RoutingPreferences()
        legacy.microphoneUID = "saved-mic"; legacy.monitorUID = "saved-output"
        let restored = try JSONDecoder().decode(RoutingPreferences.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(AudioDeviceSelection(uid: restored.microphoneUID), .fixed("saved-mic"))
        XCTAssertEqual(AudioDeviceSelection(uid: restored.monitorUID), .fixed("saved-output"))
        XCTAssertEqual(AudioDeviceSelection(uid: RoutingPreferences().microphoneUID), .automatic)
        XCTAssertEqual(AudioDeviceSelection(uid: RoutingPreferences().monitorUID), .automatic)
        XCTAssertEqual(AudioDeviceSelection(uid: nil), .automatic)
    }
    func testDeviceSwitchPreservesMuteListeningAndStopAndFailedSwitchStaysClosed() {
        let controls = AudioControls()
        let intended = CallAudioRoutes.all.subtracting(.agentToUser).rawValue
        cab_controls_set_routes(controls.pointer, intended)
        cab_controls_set_send_muted(controls.pointer, true)
        let before = cab_controls_snapshot(controls.pointer).routes
        let transition = DeviceTransitionGate(controls)
        transition.begin(); XCTAssertEqual(cab_controls_snapshot(controls.pointer).routes, 0)
        transition.finish(success: true) { cab_controls_set_routes(controls.pointer, intended) }
        XCTAssertEqual(cab_controls_snapshot(controls.pointer).routes, before)
        XCTAssertEqual(before & CallAudioRoutes.agentToUser.rawValue, 0)
        XCTAssertEqual(before & CallAudioRoutes.microphoneToCaller.rawValue, 0)
        XCTAssertNotEqual(before & CallAudioRoutes.callerToUser.rawValue, 0)
        transition.begin(); cab_controls_cancel(controls.pointer)
        transition.finish(success: true) { cab_controls_set_routes(controls.pointer, intended) }
        XCTAssertEqual(cab_controls_snapshot(controls.pointer).routes, 0)
        let failure = DeviceTransitionGate(AudioControls())
        failure.begin()
        failure.finish(success: false) { XCTFail("failed switch reopened routes") }
        XCTAssertEqual(cab_controls_snapshot(failure.controls.pointer).routes, 0)
    }
}

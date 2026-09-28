import XCTest
@testable import CallAudio

final class PhoneInputObservationTests: XCTestCase {
    func testFadeRemainsVisibleInsteadOfBeingHiddenByWholeRunPeak() throws {
        var observation = PhoneInputObservation()
        observation.append([0.5, -0.5], elapsed: 0.1)
        let loud = observation.finishWindow(elapsed: 0.2, sampleRate: 48000)
        observation.append([0.05, -0.05], elapsed: 0.3)
        let quiet = observation.finishWindow(elapsed: 0.4, sampleRate: 48000)
        XCTAssertEqual(try XCTUnwrap(quiet.levels.rms) / XCTUnwrap(loud.levels.rms), 0.1, accuracy: 0.00001)
        XCTAssertEqual(observation.total.peak, 0.5)
        XCTAssertEqual(loud.levels.frames, 2)
        XCTAssertEqual(quiet.levels.frames, 2)
    }

    func testMissingDeliveriesAreNotMeasuredSilenceOrReusedPeak() throws {
        var observation = PhoneInputObservation()
        let startup = observation.finishWindow(elapsed: 0.2, sampleRate: 48000)
        XCTAssertNil(startup.levels.peak)
        XCTAssertNil(startup.lastFrameDeliveryAgeSeconds)
        observation.append([0.5], elapsed: 0.3)
        _ = observation.finishWindow(elapsed: 0.4, sampleRate: 48000)
        let gap = observation.finishWindow(elapsed: 0.6, sampleRate: 48000)
        XCTAssertEqual(gap.levels.frames, 0)
        XCTAssertNil(gap.levels.peak)
        XCTAssertNil(gap.levels.rms)
        XCTAssertEqual(gap.levels.zeroFrames, 0)
        XCTAssertEqual(gap.expectedFramesByWallClock, 9600)
        XCTAssertEqual(gap.frameShortfallEstimate, 9600)
        XCTAssertEqual(try XCTUnwrap(gap.lastFrameDeliveryAgeSeconds), 0.3, accuracy: 0.00001)
        observation.append([0, 0], elapsed: 0.7)
        let silence = observation.finishWindow(elapsed: 0.8, sampleRate: 48000)
        XCTAssertEqual(silence.levels.peak, 0)
        XCTAssertEqual(silence.levels.rms, 0)
        XCTAssertEqual(silence.levels.zeroFrames, 2)
        XCTAssertEqual(silence.levels.frames, 2)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: gap.json))
    }

    func testCallbackBurstsDoNotCreateNegativeShortfallsAndCountsReset() throws {
        var observation = PhoneInputObservation()
        observation.append([1, -1, 0, 0.25], elapsed: 0.05)
        let burst = observation.finishWindow(elapsed: 0.2, sampleRate: 10)
        XCTAssertEqual(burst.frameShortfallEstimate, 0)
        XCTAssertEqual(burst.levels.clippedFrames, 2)
        XCTAssertEqual(burst.levels.zeroFrames, 1)
        observation.append([.nan, .infinity], elapsed: 0.3)
        let invalid = observation.finishWindow(elapsed: 0.4, sampleRate: 10)
        XCTAssertNil(invalid.levels.peak)
        XCTAssertNil(invalid.levels.rms)
        XCTAssertEqual(invalid.levels.nonfiniteFrames, 2)
        XCTAssertEqual(invalid.levels.clippedFrames, 0)
        XCTAssertEqual(observation.total.frames, 6)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: observation.total.json))
    }
}

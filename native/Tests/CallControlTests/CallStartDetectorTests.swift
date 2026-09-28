import XCTest
@testable import CallControl

final class CallStartDetectorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFiresOnceWhenCallAudioStartsAfterPreparation() {
        var detector = CallStartDetector(preparedAt: start)
        XCTAssertFalse(detector.observe(callAudioRunning: false, at: start.addingTimeInterval(1)))
        XCTAssertTrue(detector.observe(callAudioRunning: true, at: start.addingTimeInterval(30)))
        XCTAssertFalse(detector.observe(callAudioRunning: false, at: start.addingTimeInterval(40)))
        XCTAssertFalse(detector.observe(callAudioRunning: true, at: start.addingTimeInterval(50)))
        XCTAssertTrue(detector.expired)
    }

    func testNeverJoinsACallAlreadyInProgress() {
        var detector = CallStartDetector(preparedAt: start)
        for second in 1...20 {
            XCTAssertFalse(detector.observe(callAudioRunning: true, at: start.addingTimeInterval(TimeInterval(second))))
        }
    }

    func testIgnoresCallsAfterThePreparationGoesStale() {
        var detector = CallStartDetector(preparedAt: start)
        XCTAssertFalse(detector.observe(callAudioRunning: false, at: start.addingTimeInterval(5)))
        let late = start.addingTimeInterval(CallStartDetector.window + 1)
        XCTAssertTrue(detector.stale(at: late))
        XCTAssertFalse(detector.observe(callAudioRunning: true, at: late))
    }
}

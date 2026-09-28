import XCTest
@testable import CallAudio

final class AudioAccessProbeTests: XCTestCase {
    func testCancelBeforeQueuedPermissionCheckDoesNotOpenDevices() {
        let probe = AudioAccessProbe()
        probe.cancel()
        XCTAssertThrowsError(try probe.run()) { error in
            XCTAssertTrue(error.localizedDescription.contains("cancelled before starting"))
        }
    }
}

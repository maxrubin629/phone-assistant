import XCTest
@testable import CallAudio

final class PhoneInputRouteTests: XCTestCase {
    func testActivePhoneWithCodexInputAndOutputOnlySpeakers() throws {
        // Observed live process list after choosing Phone's separate speaker:
        // Phone Assistant 136 plus BuiltInSpeakerDevice 124, even on input scope.
        try PhoneInputRoute.validate(running: true,
            devices: [.init(id: 136, inputStreamCount: 1), .init(id: 124, inputStreamCount: 0)], expected: 136)
    }
    func testWrongOrAmbiguousMicrophoneStillFailsClosed() {
        let virtual = PhoneProcessDevice(id: 136, inputStreamCount: 1)
        let microphone = PhoneProcessDevice(id: 131, inputStreamCount: 1)
        XCTAssertThrowsError(try PhoneInputRoute.validate(running: false, devices: [virtual], expected: 136))
        XCTAssertThrowsError(try PhoneInputRoute.validate(running: true, devices: [microphone], expected: 136))
        XCTAssertThrowsError(try PhoneInputRoute.validate(running: true, devices: [virtual, microphone], expected: 136))
        XCTAssertThrowsError(try PhoneInputRoute.validate(running: true, devices: [.init(id: 136, inputStreamCount: 0)], expected: 136))
    }
    func testPhoneMustNotPlayCallerAudioBackIntoItsOwnVirtualMicrophone() throws {
        let virtual = PhoneProcessDevice(id: 136, inputStreamCount: 1, outputStreamCount: 1)
        let speakers = PhoneProcessDevice(id: 124, inputStreamCount: 0, outputStreamCount: 1)
        XCTAssertThrowsError(try PhoneInputRoute.validate(running: true, devices: [virtual], expected: 136, outputs: [virtual]))
        try PhoneInputRoute.validate(running: true, devices: [virtual, speakers], expected: 136, outputs: [virtual, speakers])
        try PhoneInputRoute.validate(running: true, devices: [virtual], expected: 136, outputs: [speakers])
    }
}

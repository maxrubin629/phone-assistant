import XCTest
@testable import CallAutomation

@MainActor final class PhoneMicrophoneAutomationTests: XCTestCase {
    private let owner = UUID()

    func testSelectsAndRestoresPreviousMicrophone() async throws {
        let menu = FakeMenu()
        let subject = PhoneMicrophoneAutomation(menu: menu)
        try await subject.connect(owner: owner)
        XCTAssertEqual(menu.selected, menu.virtual)
        try await subject.disconnect(owner: owner)
        XCTAssertEqual(menu.selected, menu.physical)
        XCTAssertEqual(menu.writes, [menu.virtual, menu.physical])
    }

    func testPreservesUserChangeAndAlreadySelectedVirtualMicrophone() async throws {
        let menu = FakeMenu(), subject: PhoneMicrophoneAutomation
        subject = PhoneMicrophoneAutomation(menu: menu)
        try await subject.connect(owner: owner)
        menu.selected = menu.system
        try await subject.disconnect(owner: owner)
        XCTAssertEqual(menu.selected, menu.system)
        XCTAssertEqual(menu.writes.count, 1)
        menu.selected = menu.virtual; menu.writes = []
        try await subject.connect(owner: owner)
        try await subject.disconnect(owner: owner)
        XCTAssertEqual(menu.selected, menu.virtual)
        XCTAssertTrue(menu.writes.isEmpty)
    }

    func testRejectedSelectionDoesNotClaimSuccess() async throws {
        let menu = FakeMenu(); menu.ignoreSelection = true
        let subject = PhoneMicrophoneAutomation(menu: menu)
        do { try await subject.connect(owner: owner); XCTFail("Unchanged selection must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not confirm")) }
        try await subject.disconnect(owner: owner)
        XCTAssertEqual(menu.selected, menu.physical)
    }

    func testFailureAfterClickStillRestores() async throws {
        let menu = FakeMenu(); menu.failAfterSelection = true
        let subject = PhoneMicrophoneAutomation(menu: menu)
        do { try await subject.connect(owner: owner); XCTFail("Expected AX failure") } catch {}
        menu.failAfterSelection = false
        try await subject.disconnect(owner: owner)
        XCTAssertEqual(menu.selected, menu.physical)
    }

    func testMissingPreviousDeviceRetainsRecoveryForRetry() async throws {
        let menu = FakeMenu(), subject: PhoneMicrophoneAutomation
        subject = PhoneMicrophoneAutomation(menu: menu)
        try await subject.connect(owner: owner)
        menu.choices.removeAll { $0 == menu.physical }
        do { try await subject.disconnect(owner: owner); XCTFail("Missing device must fail cleanup") } catch {}
        do { try await subject.connect(owner: UUID()); XCTFail("Pending recovery must prevent another lease") } catch {}
        menu.choices.append(menu.physical)
        try await subject.disconnect(owner: owner)
        XCTAssertEqual(menu.selected, menu.physical)
    }

    func testOtherOwnerCannotSelectOrRestore() async throws {
        let menu = FakeMenu(), subject: PhoneMicrophoneAutomation
        subject = PhoneMicrophoneAutomation(menu: menu)
        try await subject.connect(owner: owner)
        let other = UUID()
        do { try await subject.connect(owner: other); XCTFail("Overlapping owner must fail") } catch {}
        try await subject.disconnect(owner: other)
        XCTAssertEqual(menu.selected, menu.virtual)
        try await subject.disconnect(owner: owner)
    }

    func testStopDuringVerificationRestoresBeforeReturning() async throws {
        let menu = FakeMenu(), subject: PhoneMicrophoneAutomation
        subject = PhoneMicrophoneAutomation(menu: menu)
        let connect = Task { try await subject.connect(owner: owner) }
        while menu.writes.isEmpty { await Task.yield() }
        try await subject.disconnect(owner: owner)
        if case .success = await connect.result { XCTFail("Cancelled startup must not succeed") }
        XCTAssertEqual(menu.selected, menu.physical)
        XCTAssertEqual(menu.writes, [menu.virtual, menu.physical])
    }

    func testUnavailableMenuDoesNotMutateAndCanRetry() async throws {
        let menu = FakeMenu(); menu.failOpening = true
        let subject = PhoneMicrophoneAutomation(menu: menu)
        do { try await subject.connect(owner: owner); XCTFail("Expected permission/menu failure") } catch {}
        try await subject.disconnect(owner: owner)
        XCTAssertTrue(menu.writes.isEmpty)
        menu.failOpening = false
        try await subject.connect(owner: owner)
        try await subject.disconnect(owner: owner)
    }
}

@MainActor private final class FakeMenu: PhoneMicrophoneMenu {
    let physical = MicrophoneChoice(title: "MacBook Pro Microphone", identifier: "physical")
    let virtual = MicrophoneChoice(title: "Phone Assistant", identifier: "codex_phone")
    let system = MicrophoneChoice(title: "Use System Setting", identifier: "use_system_setting")
    var choices: [MicrophoneChoice]
    var selected: MicrophoneChoice
    var writes: [MicrophoneChoice] = []
    var ignoreSelection = false
    var failAfterSelection = false
    var failOpening = false
    init() { choices = [physical, virtual, system]; selected = physical }
    func open() async throws {
        if failOpening { throw PhoneAutomationError("Permission unavailable") }
        try Task.checkCancellation()
    }
    func state() throws -> MicrophoneMenuState { .init(choices: choices, selected: selected) }
    func select(_ choice: MicrophoneChoice) throws {
        writes.append(choice)
        if !ignoreSelection { selected = choice }
        if failAfterSelection { throw PhoneAutomationError("AX timed out after applying the selection") }
    }
    func close() {}
}

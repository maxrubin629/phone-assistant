import CallPreferences
import Foundation
import XCTest

final class AssistantPreferencesTests: XCTestCase {
    func testFirstRunAndInterruptedSetupResumeWithoutAlteringExistingAudioPreferences() throws {
        let domain = "com.codexcall.tests.assistant." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let legacyAudio = Data("existing-device-identifiers-and-levels".utf8)
        defaults.set(legacyAudio, forKey: "audioRouting.v1")
        var profile = AssistantPreferences.load(from: defaults)
        XCTAssertFalse(profile.setupCompleted)
        XCTAssertEqual(profile.setupStep, .permissions)
        profile.name = "Robin"
        profile.setupStep = .assistant
        profile.save(to: defaults)
        let restored = AssistantPreferences.load(from: defaults)
        XCTAssertEqual(restored.name, "Robin")
        XCTAssertEqual(restored.setupStep, .assistant)
        XCTAssertFalse(restored.setupCompleted)
        XCTAssertEqual(defaults.data(forKey: "audioRouting.v1"), legacyAudio)
    }

    func testCompletedSetupAndIdentitySurviveRelaunch() throws {
        let domain = "com.codexcall.tests.assistant." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var profile = AssistantPreferences()
        XCTAssertFalse(profile.completeSetup())
        profile.name = " Robin "
        profile.ownerName = "Sam"
        profile.voiceStyle = .warm
        profile.pace = .relaxed
        profile.introduction = .assistant
        profile.setupStep = .introduction
        XCTAssertTrue(profile.completeSetup())
        profile.save(to: defaults)
        let restored = AssistantPreferences.load(from: defaults)
        XCTAssertTrue(restored.setupCompleted)
        XCTAssertEqual(restored.name, "Robin")
        XCTAssertEqual(restored.voiceStyle, .warm)
        XCTAssertEqual(restored.pace, .relaxed)
        XCTAssertEqual(restored.introductionPreview, "Hi, I'm Robin, Sam's assistant.")
        XCTAssertTrue(restored.sessionInstructions.contains("If asked whether you are AI, answer honestly."))
    }

    func testCustomIntroductionCannotFinishEmptyAndNoIntroductionIsExplicit() {
        var profile = AssistantPreferences()
        profile.setupStep = .introduction
        profile.introduction = .custom
        profile.customIntroduction = "  \n "
        XCTAssertFalse(profile.completeSetup())
        profile.customIntroduction = "Hello, I'm calling on Sam's behalf."
        XCTAssertTrue(profile.completeSetup())
        XCTAssertEqual(profile.introductionPreview, profile.customIntroduction)
        profile.introduction = .whenAsked
        XCTAssertTrue(profile.sessionInstructions.contains("No automatic introduction"))
        XCTAssertTrue(profile.sessionInstructions.contains("Do not claim to be human"))
    }

    func testInvalidSavedProfileReturnsToSetupAndCorruptDataRecovers() throws {
        let domain = "com.codexcall.tests.assistant." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var profile = AssistantPreferences()
        profile.setupStep = .introduction
        XCTAssertTrue(profile.completeSetup())
        profile.name = " \n "
        profile.save(to: defaults)
        XCTAssertFalse(AssistantPreferences.load(from: defaults).setupCompleted)
        defaults.set(Data("invalid".utf8), forKey: AssistantPreferences.storageKey)
        XCTAssertEqual(AssistantPreferences.load(from: defaults), AssistantPreferences())
    }
}

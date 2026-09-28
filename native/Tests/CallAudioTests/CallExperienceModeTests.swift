import XCTest
import CallAudioDSP
@testable import CallAudio

final class CallExperienceModeTests: XCTestCase {
    func testModesGrantExactlyTheirAdvertisedAudioPaths() {
        let expected: [(CallExperienceMode, CallAudioRoutes)] = [
            (.assistant, [.agentToCaller, .callerToAgent]),
            (.listen, [.agentToCaller, .callerToAgent, .callerToUser, .agentToUser]),
            (.join, [.microphoneToCaller, .agentToCaller, .callerToAgent,
                     .microphoneToAgent, .callerToUser, .agentToUser]),
            (.takeOver, [.microphoneToCaller, .callerToAgent, .microphoneToAgent, .callerToUser]),
            (.manual, [.microphoneToCaller, .callerToUser])
        ]
        XCTAssertEqual(expected.count, CallExperienceMode.allCases.count)
        for (mode, routes) in expected {
            XCTAssertEqual(mode.routing.routes, routes, mode.rawValue)
            XCTAssertEqual(mode.needsVoice, mode != .manual, mode.rawValue)
        }
    }

    func testEveryPresetRoundTripsAndCustomRoutesRemainCustom() {
        for mode in CallExperienceMode.allCases {
            XCTAssertEqual(CallExperienceMode(routing: mode.routing), mode)
        }
        for speaker in PhoneParticipant.allCases {
            for listener in PhoneParticipant.allCases {
                let routing = PhoneRouting(speaker: speaker, listener: listener)
                if let mode = CallExperienceMode(routing: routing) {
                    XCTAssertEqual(mode.routing, routing)
                } else {
                    XCTAssertFalse(CallExperienceMode.allCases.contains { $0.routing == routing })
                }
            }
        }
        XCTAssertNil(CallExperienceMode(routing: PhoneRouting(speaker: .agent, listener: .user)))
        XCTAssertNil(CallExperienceMode(routing: PhoneRouting(speaker: .user, listener: .agent)))
        XCTAssertNil(CallExperienceMode(routing: PhoneRouting(speaker: .both, listener: .agent)))
        XCTAssertNil(CallExperienceMode(routing: PhoneRouting(speaker: .both, listener: .user)))
    }

    func testListenDoesNotSendMicrophoneAndTakeOverBlocksAssistantAudioInMixers() throws {
        let mic: [Float] = [0.125], agent: [Float] = [0.25], caller: [Float] = [0.5]
        // Nonzero assistant audio represents a response already in flight when the owner takes over.
        let cases: [(CallExperienceMode, Float, Float, Float)] = [
            (.assistant, 0.25, 0, 0.5),
            (.listen, 0.25, 0.75, 0.5),
            (.join, 0.375, 0.75, 0.625),
            (.takeOver, 0.125, 0.5, 0.625),
            (.manual, 0.125, 0.5, 0)
        ]
        for (mode, expectedCaller, expectedUser, expectedAssistant) in cases {
            let routes = mode.routing.routes
            var outgoing: [Float] = [0], listening: [Float] = [0], model = Data()
            cab_mix_mono(mic, agent, &outgoing, nil, 1, 1, 1, 1, routes.rawValue)
            cab_mix_monitor(caller, agent, nil, &listening, 1, 1, 1, routes.rawValue)
            ModelFrameMixer.render(caller: caller, microphone: mic, frames: 1, routes: routes,
                                   callerGain: 1, microphoneGain: 1) { model = $0 }
            XCTAssertEqual(outgoing, [expectedCaller], mode.rawValue)
            XCTAssertEqual(listening, [expectedUser], mode.rawValue)
            XCTAssertEqual(try PCM24.decode(model), [expectedAssistant], mode.rawValue)
        }
    }

    func testModeInstructionsNameTheOwnerAndStateTheAssistantsRole() {
        let join = CallExperienceMode.join.routing.instructions(ownerName: " Sam ")
        XCTAssertTrue(join.hasPrefix("Mode: Join."))
        XCTAssertTrue(join.contains("Sam leads."))
        XCTAssertTrue(join.contains("don't guess"))
        XCTAssertTrue(CallExperienceMode.takeOver.routing.instructions(ownerName: "Sam").contains("Stay completely silent"))
        XCTAssertTrue(CallExperienceMode.assistant.routing.instructions(ownerName: "").contains("The owner can't hear it"))
        XCTAssertTrue(CallExperienceMode.listen.routing.instructions(ownerName: "").contains("every voice you hear besides your own is the caller"))
        let custom = PhoneRouting(speaker: .agent, listener: .user)
        XCTAssertEqual(custom.instructions(ownerName: "Sam"), custom.instructions)
    }
}

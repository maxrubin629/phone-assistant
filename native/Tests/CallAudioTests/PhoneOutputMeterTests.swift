import XCTest
import CallAudioDSP
@testable import CallAudio

final class PhoneOutputMeterTests: XCTestCase {
    func testCaptureWindowRetainsSpeechBeforeFinalQuietTickAndDistinguishesAbsentInput() {
        var window = CaptureMeterWindow()
        window.observe([0.25, -0.75])
        for _ in 0..<9 { window.observe([0, 0]) }
        XCTAssertEqual(window.peak, 0.75)
        XCTAssertEqual(window.frames, 20)
        window.reset()
        window.observe([])
        XCTAssertEqual(window.peak, 0)
        XCTAssertEqual(window.frames, 0)
        window.observe([0, 0])
        XCTAssertEqual(window.peak, 0)
        XCTAssertEqual(window.frames, 2)
    }

    func testHealthyMicrophoneDoesNotReportUnusedAgentRingAsUnderrun() throws {
        let microphone = try AudioRing(generation: 1), agent = try AudioRing(generation: 1)
        let meter = try XCTUnwrap(cab_phone_output_meter_create())
        defer { cab_phone_output_meter_destroy(meter) }
        let signal = [Float](repeating: 0.25, count: 480)
        var mic = signal, generated = signal, rendered = signal
        for _ in 0..<100 {
            XCTAssertEqual(microphone.write(signal, generation: 1), signal.count)
            let micFrames = cab_ring_read(microphone.pointer, &mic, 480, 1)
            let agentFrames = cab_ring_read(agent.pointer, &generated, 480, 1)
            cab_mix_mono(mic, generated, &rendered, nil, 480, 1, 1, 1, CallAudioRoutes.microphoneToCaller.rawValue)
            cab_phone_output_meter_record(meter, rendered, 480, micFrames, agentFrames, CallAudioRoutes.microphoneToCaller.rawValue)
        }
        let reading = cab_phone_output_meter_take(meter)
        // This is the original defect: the empty agent ring accumulates 48k
        // raw underrun frames even though the entire requested mic was sent.
        XCTAssertEqual(cab_ring_counters(agent.pointer).underrun_frames, 48000)
        XCTAssertEqual(reading.microphone_underrun_frames, 0)
        XCTAssertEqual(reading.agent_underrun_frames, 0)
        XCTAssertEqual(reading.rendered_frames, 48000)
        XCTAssertEqual(reading.peak, 0.25, accuracy: 0.00001)
        XCTAssertEqual(reading.rms, 0.25, accuracy: 0.00001)
    }

    func testShortagesAreAttributedOnlyToEnabledRoutes() throws {
        let meter = try XCTUnwrap(cab_phone_output_meter_create())
        defer { cab_phone_output_meter_destroy(meter) }
        cab_phone_output_meter_record(meter, [0.2, 0.2, 0, 0], 4, 2, 0, CallAudioRoutes.microphoneToCaller.rawValue)
        var reading = cab_phone_output_meter_take(meter)
        XCTAssertEqual(reading.microphone_underrun_frames, 2)
        XCTAssertEqual(reading.agent_underrun_frames, 0)
        cab_phone_output_meter_record(meter, [0.4, 0, 0, 0], 4, 0, 1, CallAudioRoutes.agentToCaller.rawValue)
        reading = cab_phone_output_meter_take(meter)
        XCTAssertEqual(reading.microphone_underrun_frames, 2)
        XCTAssertEqual(reading.agent_underrun_frames, 3)
        cab_phone_output_meter_record(meter, [0.1, 0, 0, 0], 4, 1, 2, CallAudioRoutes.all.rawValue)
        reading = cab_phone_output_meter_take(meter)
        XCTAssertEqual(reading.microphone_underrun_frames, 5)
        XCTAssertEqual(reading.agent_underrun_frames, 5)
    }

    func testStartupMuteAndCancellationCountRenderedSilenceWithoutShortages() throws {
        let meter = try XCTUnwrap(cab_phone_output_meter_create())
        defer { cab_phone_output_meter_destroy(meter) }
        let controls = AudioControls()
        cab_controls_set_routes(controls.pointer, CallAudioRoutes.all.rawValue)
        // New controls start send-muted. The render path passes effective,
        // not requested, routes to the meter.
        for _ in 0..<2 {
            let routes = cab_controls_snapshot(controls.pointer).routes
            cab_phone_output_meter_record(meter, [0, 0, 0, 0], 4, 0, 0, routes)
            cab_controls_set_send_muted(controls.pointer, false)
            cab_controls_cancel(controls.pointer)
        }
        let reading = cab_phone_output_meter_take(meter)
        XCTAssertEqual(reading.rendered_frames, 8)
        XCTAssertEqual(reading.microphone_underrun_frames, 0)
        XCTAssertEqual(reading.agent_underrun_frames, 0)
        XCTAssertEqual(reading.peak, 0)
        XCTAssertEqual(reading.rms, 0)
    }

    func testMeasuresPostMixSamplesWithFrameWeightedWindows() throws {
        let meter = try XCTUnwrap(cab_phone_output_meter_create())
        defer { cab_phone_output_meter_destroy(meter) }
        var clipped = [Float](repeating: 0, count: 2)
        cab_mix_mono([0.75, -0.75], nil, &clipped, nil, 2, 2, 0, 1, CallAudioRoutes.microphoneToCaller.rawValue)
        cab_phone_output_meter_record(meter, clipped, 2, 2, 0, CallAudioRoutes.microphoneToCaller.rawValue)
        cab_phone_output_meter_record(meter, [0, 0, 0, 0, 0, 0], 6, 6, 0, CallAudioRoutes.microphoneToCaller.rawValue)
        let reading = cab_phone_output_meter_take(meter)
        XCTAssertEqual(reading.rendered_frames, 8)
        XCTAssertEqual(reading.peak, 1)
        XCTAssertEqual(reading.rms, 0.5, accuracy: 0.00001)
        let empty = cab_phone_output_meter_take(meter)
        XCTAssertEqual(empty.rendered_frames, 0)
        XCTAssertEqual(empty.peak, 0)
        XCTAssertEqual(empty.rms, 0)
        cab_phone_output_meter_record(meter, [0.125, -0.125], 2, 2, 0, CallAudioRoutes.microphoneToCaller.rawValue)
        let next = cab_phone_output_meter_take(meter)
        XCTAssertEqual(next.rendered_frames, 2)
        XCTAssertEqual(next.peak, 0.125)
        XCTAssertEqual(next.rms, 0.125)
    }

    func testSlowMeterReaderReportsLossAndRecoversWithoutBlockingOutput() throws {
        let meter = try XCTUnwrap(cab_phone_output_meter_create())
        defer { cab_phone_output_meter_destroy(meter) }
        for _ in 0..<4096 {
            cab_phone_output_meter_record(meter, [0.5], 1, 0, 0, CallAudioRoutes.microphoneToCaller.rawValue)
        }
        let first = cab_phone_output_meter_take(meter)
        XCTAssertGreaterThan(first.dropped_blocks, 0)
        XCTAssertEqual(first.rendered_frames + first.dropped_blocks, 4096)
        XCTAssertEqual(first.microphone_underrun_frames, 4096)
        cab_phone_output_meter_record(meter, [0.125], 1, 1, 0, CallAudioRoutes.microphoneToCaller.rawValue)
        let next = cab_phone_output_meter_take(meter)
        XCTAssertEqual(next.rendered_frames, 1)
        XCTAssertEqual(next.peak, 0.125)
        XCTAssertEqual(next.rms, 0.125)
        XCTAssertEqual(next.dropped_blocks, first.dropped_blocks)
        XCTAssertEqual(next.microphone_underrun_frames, 4096)
    }

    func testUnmeasurableCallbackIsFlaggedRatherThanReportedAsMeasuredSilence() throws {
        let meter = try XCTUnwrap(cab_phone_output_meter_create())
        defer { cab_phone_output_meter_destroy(meter) }
        cab_phone_output_meter_unavailable(meter)
        let reading = cab_phone_output_meter_take(meter)
        XCTAssertEqual(reading.dropped_blocks, 1)
        XCTAssertEqual(reading.rendered_frames, 0)
        XCTAssertEqual(reading.microphone_underrun_frames, 0)
        XCTAssertEqual(reading.agent_underrun_frames, 0)
    }
}

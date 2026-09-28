import CoreAudio
import XCTest
import CallAudioDSP
@testable import CallAudio

final class PhoneReadbackTests: XCTestCase {
    private func format(planar: Bool = false) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: planar ? 4 : 8, mFramesPerPacket: 1, mBytesPerFrame: planar ? 4 : 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }
    private func decode(_ samples: [[Float]], format: AudioStreamBasicDescription?, channels: UInt32,
                        capacity: Int = 8, alter: ((UnsafeMutableAudioBufferListPointer) -> Void)? = nil) -> [Float] {
        let list = AudioBufferList.allocate(maximumBuffers: samples.count)
        list.count = samples.count
        let pointers = samples.map { values -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, values.count))
            pointer.initialize(from: values, count: values.count)
            return pointer
        }
        defer {
            for (index, pointer) in pointers.enumerated() { pointer.deinitialize(count: samples[index].count); pointer.deallocate() }
            list.unsafeMutablePointer.deallocate()
        }
        for index in samples.indices {
            list[index] = AudioBuffer(mNumberChannels: channels,
                mDataByteSize: UInt32(samples[index].count * 4), mData: pointers[index])
        }
        alter?(list)
        var result = [Float](repeating: -99, count: capacity)
        let count = PhoneReadbackDecoder.copy(list.unsafePointer, format: format, to: &result, capacity: capacity)
        return Array(result.prefix(count))
    }

    func testActualCallbackDecoderHandlesInterleavedAndPlanarStereo() {
        XCTAssertEqual(decode([[0.4, 0.2, -0.4, -0.2]], format: format(), channels: 2), [0.3, -0.3])
        XCTAssertEqual(decode([[0.4, -0.4], [0.2, -0.2]], format: format(planar: true), channels: 1), [0.3, -0.3])
        XCTAssertEqual(decode([[0, 0, 0, 0]], format: format(), channels: 2), [0, 0])
    }

    func testMissingMalformedAndOversizedBuffersAreUnavailable() {
        XCTAssertTrue(decode([[0, 0]], format: nil, channels: 2).isEmpty)
        XCTAssertTrue(decode([[0, 0]], format: format(), channels: 1).isEmpty)
        XCTAssertTrue(decode([[0, 0, 0]], format: format(), channels: 2).isEmpty)
        XCTAssertTrue(decode([[0, 0, 0, 0]], format: format(), channels: 2, capacity: 1).isEmpty)
        XCTAssertTrue(decode([[0, 0], [0]], format: format(planar: true), channels: 1).isEmpty)
        XCTAssertTrue(decode([[0, 0]], format: format(), channels: 2, alter: { $0[0].mData = nil }).isEmpty)
        XCTAssertTrue(decode([[0, .nan]], format: format(), channels: 2).isEmpty)
        var padded = format(); padded.mBytesPerFrame = 16
        XCTAssertTrue(decode([[0, 0]], format: padded, channels: 2).isEmpty)
        var integer = format(); integer.mFormatFlags = kAudioFormatFlagIsSignedInteger
        XCTAssertTrue(decode([[0, 0]], format: integer, channels: 2).isEmpty)
    }

    func testDuplexMeterKeepsIndependentFrameWeightedLevelsAndMeasuredSilence() throws {
        let meter = try XCTUnwrap(cab_phone_output_meter_create())
        defer { cab_phone_output_meter_destroy(meter) }
        cab_phone_output_meter_record_duplex(meter, [0.5, -0.5], 2, 2, 0, 0, [0.125, -0.125], 2)
        cab_phone_output_meter_record_duplex(meter, [0, 0], 2, 2, 0, 0, [0, 0, 0, 0, 0, 0], 6)
        // Unavailable input must not contribute fabricated zeros to RMS.
        cab_phone_output_meter_record_duplex(meter, [0, 0], 2, 2, 0, 0, nil, 100)
        let snapshot = cab_phone_output_meter_take(meter)
        XCTAssertEqual(snapshot.rendered_frames, 6)
        XCTAssertEqual(snapshot.peak, 0.5)
        XCTAssertEqual(snapshot.rms, sqrt(0.5 / 6), accuracy: 0.00001)
        XCTAssertEqual(snapshot.readback_frames, 8)
        XCTAssertEqual(snapshot.readback_zero_frames, 6)
        XCTAssertEqual(snapshot.readback_peak, 0.125)
        XCTAssertEqual(snapshot.readback_rms, 0.0625)
        XCTAssertEqual(snapshot.readback_unavailable_blocks, 1)
        let empty = cab_phone_output_meter_take(meter)
        XCTAssertEqual(empty.readback_frames, 0)
        XCTAssertEqual(empty.readback_unavailable_blocks, 0)
    }

    func testReadbackQueueLossIsPairedAndNeverBlocksOutput() throws {
        let meter = try XCTUnwrap(cab_phone_output_meter_create())
        defer { cab_phone_output_meter_destroy(meter) }
        for _ in 0..<4096 {
            cab_phone_output_meter_record_duplex(meter, [0.5], 1, 1, 0, 0, [0.125], 1)
        }
        let snapshot = cab_phone_output_meter_take(meter)
        XCTAssertEqual(snapshot.readback_frames, snapshot.rendered_frames)
        XCTAssertEqual(snapshot.readback_frames + snapshot.dropped_blocks, 4096)
        XCTAssertEqual(snapshot.readback_peak / snapshot.peak, 0.25)
        cab_phone_output_meter_record_duplex(meter, [0], 1, 1, 0, 0, [0], 1)
        let next = cab_phone_output_meter_take(meter)
        XCTAssertEqual(next.readback_frames, 1)
        XCTAssertEqual(next.readback_zero_frames, 1)
        XCTAssertEqual(next.readback_unavailable_blocks, 0)
    }
}

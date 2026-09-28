import AVFoundation
import Foundation

/// Stateful sample-rate conversion is worker-only. AVAudioConverter provides
/// filtering for downsampling; callbacks never allocate or invoke a converter.
final class MonoConverter {
    private let from: AVAudioFormat
    private let to: AVAudioFormat
    private let converter: AVAudioConverter?
    init(from source: Double, to destination: Double) throws {
        guard let from = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1),
              let to = AVAudioFormat(standardFormatWithSampleRate: destination, channels: 1) else {
            throw CallAudioError("Invalid PCM conversion format.")
        }
        self.from = from; self.to = to
        if source == destination { converter = nil }
        else {
            guard let converter = AVAudioConverter(from: from, to: to) else { throw CallAudioError("Sample-rate converter is unavailable.") }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = converter
        }
    }
    func reset() { converter?.reset() }
    func convert(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let converter else { return samples }
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * to.sampleRate / from.sampleRate) + 128)
        guard let input = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: capacity) else {
            throw CallAudioError("Could not allocate PCM conversion buffers.")
        }
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true; state.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { throw CallAudioError("PCM conversion failed: \(error?.localizedDescription ?? "unknown error")") }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

enum PCM24 {
    static func decode(_ data: Data) throws -> [Float] {
        guard data.count > 0, data.count % 2 == 0, data.count <= 48000 else {
            throw CallAudioError("Agent audio must contain at most one second of PCM16 mono at 24 kHz.")
        }
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / 2)).map {
                Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768
            }
        }
    }
    static func encode(_ values: [Float]) -> Data {
        let words: [Int16] = values.map {
            let value = $0.isFinite ? min(1, max(-1, $0)) : 0
            return Int16(min(32767, max(-32768, Int(value * 32768)))).littleEndian
        }
        return words.withUnsafeBytes { Data($0) }
    }
}

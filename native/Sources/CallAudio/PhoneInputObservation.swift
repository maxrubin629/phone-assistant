import Foundation

/// Receipt-time statistics, not a recording or an estimate of speech quality.
/// Empty windows have no amplitude measurement; delivered zeroes are measured
/// silence. Callback timestamps are not available through AudioRing, so frame
/// shortfalls and last-delivery age describe this observer, not a failed driver.
struct PhoneInputObservation {
    struct Levels {
        private(set) var frames = 0
        private(set) var zeroFrames = 0
        private(set) var clippedFrames = 0
        private(set) var nonfiniteFrames = 0
        private var maximum = 0.0
        private var sumSquares = 0.0

        var peak: Double? { frames > nonfiniteFrames ? maximum : nil }
        var rms: Double? {
            let finiteFrames = frames - nonfiniteFrames
            return finiteFrames > 0 ? sqrt(sumSquares / Double(finiteFrames)) : nil
        }
        mutating func append(_ samples: [Float]) {
            for sample in samples {
                frames += 1
                guard sample.isFinite else { nonfiniteFrames += 1; continue }
                let value = Double(sample)
                maximum = max(maximum, abs(value))
                sumSquares += value * value
                if sample == 0 { zeroFrames += 1 }
                // At the PCM rails after InputIO downmix/sanitization. This
                // does not prove that the original microphone was clipping.
                if abs(sample) >= 1 { clippedFrames += 1 }
            }
        }
        var json: [String: Any] {
            ["frames": frames, "peak": peak as Any? ?? NSNull(),
             "rms": rms as Any? ?? NSNull(), "zeroFrames": zeroFrames,
             "clippedFrames": clippedFrames, "nonfiniteFrames": nonfiniteFrames]
        }
    }
    struct Window {
        let startSeconds: Double
        let endSeconds: Double
        let levels: Levels
        let expectedFramesByWallClock: Int
        let frameShortfallEstimate: Int
        let lastFrameDeliveryAgeSeconds: Double?

        var json: [String: Any] {
            var result = levels.json
            result["startSeconds"] = startSeconds
            result["endSeconds"] = endSeconds
            result["expectedFramesByWallClock"] = expectedFramesByWallClock
            result["frameShortfallEstimate"] = frameShortfallEstimate
            result["lastFrameDeliveryAgeSeconds"] = lastFrameDeliveryAgeSeconds as Any? ?? NSNull()
            return result
        }
    }

    private(set) var total = Levels()
    private var current = Levels()
    private var windowStart = 0.0
    private var lastDelivery: Double?

    mutating func append(_ samples: [Float], elapsed: Double) {
        guard !samples.isEmpty else { return }
        current.append(samples)
        total.append(samples)
        lastDelivery = elapsed
    }

    mutating func finishWindow(elapsed: Double, sampleRate: Double) -> Window {
        let end = max(windowStart, elapsed)
        let expected = Int(((end - windowStart) * sampleRate).rounded())
        let result = Window(startSeconds: windowStart, endSeconds: end,
            levels: current, expectedFramesByWallClock: expected,
            frameShortfallEstimate: max(0, expected - current.frames),
            lastFrameDeliveryAgeSeconds: lastDelivery.map { max(0, end - $0) })
        current = Levels()
        windowStart = end
        return result
    }
}

import CoreGraphics

/// Shared by the AppKit window and SwiftUI shell. Both curves start at rest.
enum CallNotchTransition {
    struct Timing {
        let duration: Double
        let x1: Float, y1: Float, x2: Float, y2: Float

        func progress(at fraction: Double) -> CGFloat {
            let x = min(1, max(0, fraction))
            if x == 0 || x == 1 { return CGFloat(x) }
            func bezier(_ t: Double, _ a: Float, _ b: Float) -> Double {
                let u = 1 - t
                return 3 * u * u * t * Double(a) + 3 * u * t * t * Double(b) + t * t * t
            }
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let t = (low + high) / 2
                if bezier(t, x1, x2) < x { low = t } else { high = t }
            }
            return CGFloat(bezier((low + high) / 2, y1, y2))
        }

        func frame(from start: CGRect, to end: CGRect, at fraction: Double) -> CGRect {
            let p = progress(at: fraction)
            let width = start.width + (end.width - start.width) * p
            let height = start.height + (end.height - start.height) * p
            let top = start.maxY + (end.maxY - start.maxY) * p
            return CGRect(x: start.minX + (end.minX - start.minX) * p,
                          y: top - height, width: width, height: height)
        }
    }

    static func timing(expanding: Bool) -> Timing {
        expanding
            ? Timing(duration: 0.24, x1: 0.28, y1: 0, x2: 0.22, y2: 1)
            : Timing(duration: 0.24, x1: 0.4, y1: 0, x2: 0.2, y2: 1)
    }
}

/// Repeated requests for an in-flight target must not snap the window to it.
/// Completion of a superseded animation must not finish its replacement.
struct CallNotchFrameAnimation {
    private(set) var target: CGRect?
    private(set) var generation = 0
    private(set) var isAnimating = false

    mutating func begin(target: CGRect, animated: Bool) -> Int? {
        guard !isAnimating || self.target != target else { return nil }
        generation += 1
        self.target = target
        isAnimating = animated
        return generation
    }

    @discardableResult mutating func complete(_ generation: Int) -> Bool {
        guard self.generation == generation else { return false }
        isAnimating = false
        return true
    }

    mutating func cancel() {
        generation += 1
        target = nil
        isAnimating = false
    }
}

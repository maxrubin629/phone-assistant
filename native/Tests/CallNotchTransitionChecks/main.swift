import Foundation
import CoreGraphics

let collapsed = CGRect(x: 770, y: 1085, width: 188, height: 32)
let expanded = CGRect(x: 544, y: 977, width: 640, height: 140)
var animation = CallNotchFrameAnimation()
_ = animation.begin(target: collapsed, animated: false)
let opening = animation.begin(target: expanded, animated: true)!
// Hover opens, then a click pins the same target. The controller must leave
// the in-flight animation alone instead of setting the final frame directly.
precondition(animation.begin(target: expanded, animated: false) == nil)
precondition(animation.isAnimating && animation.generation == opening)

// Reversing direction supersedes the old completion, without finishing early.
let closing = animation.begin(target: collapsed, animated: true)!
precondition(!animation.complete(opening) && animation.isAnimating)
precondition(animation.complete(closing) && !animation.isAnimating)
let nextOpening = animation.begin(target: expanded, animated: true)!
animation.cancel()
precondition(!animation.complete(nextOpening) && !animation.isAnimating)
// Reduced Motion and screen changes are immediate rather than animated.
precondition(animation.begin(target: expanded, animated: false) != nil)
precondition(!animation.isAnimating)
// A live resize must keep the screen-space top fixed on every frame,
// including reversals that begin from a partially expanded frame.
for expanding in [true, false] {
    let timing = CallNotchTransition.timing(expanding: expanding)
    let start = expanding ? collapsed : expanded
    let end = expanding ? expanded : collapsed
    precondition(timing.frame(from: start, to: end, at: 0) == start)
    precondition(timing.frame(from: start, to: end, at: 1) == end)
    var previous: CGFloat = 0
    for step in 0...120 {
        let fraction = Double(step) / 120
        let progress = timing.progress(at: fraction)
        precondition(progress >= previous && progress <= 1)
        previous = progress
        let frame = timing.frame(from: start, to: end, at: fraction)
        precondition(abs(frame.maxY - start.maxY) < 0.0001)
        let reverse = timing.frame(from: frame, to: start, at: 0.5)
        precondition(abs(reverse.maxY - start.maxY) < 0.0001)
    }
}
print("PASS: live resize preserves the top edge, easing order, endpoints, and partial reversals")
print("PASS: pinning during hover-open preserves motion; reversals ignore stale completions; hide cancels motion; immediate placement remains available")

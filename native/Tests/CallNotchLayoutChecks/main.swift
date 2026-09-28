import Foundation
import CoreGraphics

let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
let visible = CGRect(x: 0, y: 0, width: 1728, height: 1084)
let left = CGRect(x: 0, y: 1085, width: 771.5, height: 32)
let right = CGRect(x: 956.5, y: 1085, width: 771.5, height: 32)

func layout(expanded: Bool = false, ears: Bool = true, height: CGFloat? = nil) -> CallNotchLayout {
    .make(screenFrame: screen, visibleFrame: visible, safeTop: 32,
          auxiliaryLeft: left, auxiliaryRight: right, expanded: expanded, showsEars: ears, preferredExpandedHeight: height)
}

let compact = layout()
precondition(compact.isHardwareNotch && compact.notchWidth == 185 && compact.notchHeight == 32)
precondition(compact.frame == CGRect(x: 707, y: 1085, width: 314, height: 32), "\(compact.frame)")
precondition(compact.frame.maxY == screen.maxY, "Hardware attachment must reach the physical screen edge")
precondition(compact.frame.minY == left.minY, "Collapsed lower edge must meet the housing's lower edge")
precondition(compact.frame.midX == left.maxX + compact.notchWidth / 2, "Camera gap must be centered on the housing")
precondition(compact.frame.minX.rounded() == compact.frame.minX, "Whole-point origin avoids WindowServer rounding")

let idle = layout(ears: false)
precondition(idle.frame == CGRect(x: 771, y: 1085, width: 186, height: 32), "\(idle.frame)")
precondition(idle.frame.minX <= left.maxX && idle.frame.maxX >= right.minX && idle.frame.minX > left.maxX - 1
             && idle.frame.maxX < right.minX + 1, "Idle panel must stay within half a point of the housing")

let expanded = layout(expanded: true)
precondition(expanded.frame.width == 500 && expanded.frame.height == 140)
precondition(expanded.frame.midX == 864 && expanded.frame.maxY == 1117)
precondition(layout(expanded: true, height: 288).frame.height == 288, "Measured height already includes the camera inset")
precondition(layout(expanded: true, height: 1000).frame.height == 420)

let external = CallNotchLayout.make(screenFrame: CGRect(x: -1920, y: 120, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: 120, width: 1920, height: 1055), safeTop: 0,
    auxiliaryLeft: nil, auxiliaryRight: nil, expanded: false, preferredExpandedHeight: nil)
precondition(!external.isHardwareNotch && external.notchWidth == 0 && external.notchHeight == 0)
precondition(external.frame.midX == -960 && external.frame.maxY == 1169)

let unavailableAreas = CallNotchLayout.make(screenFrame: screen, visibleFrame: visible, safeTop: 32,
    auxiliaryLeft: nil, auxiliaryRight: nil, expanded: false, preferredExpandedHeight: nil)
precondition(!unavailableAreas.isHardwareNotch && unavailableAreas.frame.maxY == visible.maxY - 6)

let narrow = CallNotchLayout.make(screenFrame: CGRect(x: 0, y: 0, width: 280, height: 600),
    visibleFrame: CGRect(x: 0, y: 0, width: 280, height: 575), safeTop: 0,
    auxiliaryLeft: nil, auxiliaryRight: nil, expanded: true, preferredExpandedHeight: 900)
precondition(narrow.frame.width == 280 && narrow.frame.minX == 0 && narrow.frame.maxY == 569)

print("PASS: hardware attachment, housing-height collapse, housing-sized idle, whole-point centering, expansion, measured-height contract, cap, external display, missing-area fallback, narrow display")

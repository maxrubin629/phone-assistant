import Foundation
import CoreGraphics

/// Pure screen geometry. Controls stay clear of the camera housing, while the
/// continuous panel reaches the physical top edge only on a notched display.
/// On a notch the collapsed panel is exactly the housing's height, so its lower
/// edge continues the hardware outline instead of hanging below it. Without
/// activity it is also the housing's width: invisible, and it covers no menu
/// bar items. Ears grow out only when there is something to show.
struct CallNotchLayout {
    static let compactEar: CGFloat = 64
    static let expandedWidth: CGFloat = 500
    static let floatingCompactSize = CGSize(width: 280, height: 38)
    static let maximumHeight: CGFloat = 420

    let frame: CGRect
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let isHardwareNotch: Bool

    static func minimumExpandedHeight(notchHeight: CGFloat) -> CGFloat {
        notchHeight > 0 ? notchHeight + 108 : 148
    }

    static func make(screenFrame: CGRect, visibleFrame: CGRect, safeTop: CGFloat,
                     auxiliaryLeft: CGRect?, auxiliaryRight: CGRect?, expanded: Bool,
                     showsEars: Bool = true, preferredExpandedHeight: CGFloat?) -> Self {
        let notch: CGRect?
        if safeTop > 0, let left = auxiliaryLeft, let right = auxiliaryRight,
           left.maxX < right.minX, left.maxX >= screenFrame.minX, right.minX <= screenFrame.maxX {
            notch = CGRect(x: left.maxX, y: screenFrame.maxY - safeTop,
                           width: right.minX - left.maxX, height: safeTop)
        } else {
            notch = nil
        }

        let notchWidth = notch?.width ?? 0
        let notchHeight = notch?.height ?? 0
        let bounds = notch == nil ? visibleFrame : screenFrame
        let centerX = notch?.midX ?? bounds.midX
        let availableWidth = max(1, bounds.width)
        // Even widths keep both halves on whole points, so the reserved camera
        // gap stays centered on the housing after WindowServer rounding.
        let desiredWidth: CGFloat = expanded ? expandedWidth
            : notch == nil ? floatingCompactSize.width : evenCeil(notchWidth + (showsEars ? 2 * compactEar : 0))
        let width = min(desiredWidth, availableWidth)
        let minimumExpandedHeight = minimumExpandedHeight(notchHeight: notchHeight)
        let requestedHeight = preferredExpandedHeight.flatMap { $0.isFinite ? $0 : nil } ?? minimumExpandedHeight
        let expandedHeight = max(minimumExpandedHeight, min(maximumHeight, ceil(requestedHeight)))
        let desiredHeight: CGFloat = expanded ? expandedHeight
            : notch == nil ? floatingCompactSize.height : notchHeight
        let height = min(desiredHeight, max(1, bounds.height))
        let top = notch == nil ? visibleFrame.maxY - 6 : screenFrame.maxY
        let x = min(max((centerX - width / 2).rounded(), bounds.minX), bounds.maxX - width)
        return Self(frame: CGRect(x: x, y: top - height, width: width, height: height),
                    notchWidth: notchWidth, notchHeight: notchHeight, isHardwareNotch: notch != nil)
    }

    private static func evenCeil(_ value: CGFloat) -> CGFloat { ceil(value / 2) * 2 }
}

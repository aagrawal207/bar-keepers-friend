import CoreGraphics
import Foundation

/// Pure geometry for reasoning about the camera-notch region of a display's menu bar.
///
/// macOS silently drops menu bar items that don't fit between the right-hand status area
/// and the notch — there is no overflow UI. The app must therefore know where the notch is
/// and never place its own control items inside it. The live values come from
/// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` / `safeAreaInsets`; this type
/// holds only the extracted rectangles so the placement math is testable without a screen.
public struct NotchGeometry: Equatable, Sendable {
    /// The full frame of the display, in global coordinates.
    public let displayFrame: CGRect

    /// The usable menu bar region to the *left* of the notch, or `nil` on a notchless display.
    public let leftArea: CGRect?

    /// The usable menu bar region to the *right* of the notch, or `nil` on a notchless display.
    public let rightArea: CGRect?

    public init(displayFrame: CGRect, leftArea: CGRect?, rightArea: CGRect?) {
        self.displayFrame = displayFrame
        self.leftArea = leftArea
        self.rightArea = rightArea
    }

    /// Whether this display has a camera notch.
    public var hasNotch: Bool {
        leftArea != nil && rightArea != nil
    }

    /// The horizontal span occupied by the notch itself, if any.
    /// Returns `nil` on notchless displays.
    public var notchXRange: ClosedRange<CGFloat>? {
        guard let left = leftArea, let right = rightArea else { return nil }
        let start = left.maxX
        let end = right.minX
        guard end > start else { return nil }
        return start...end
    }

    /// Returns `true` if an item with the given horizontal midpoint would fall under the
    /// notch (and thus be clipped / dropped by the system).
    ///
    /// The notch occupies the *open* interval between the two usable areas: a point exactly
    /// on a usable area's inner edge (`leftArea.maxX` or `rightArea.minX`) is considered
    /// safe, so `safePlacement` can clamp to those edges.
    public func isUnderNotch(midX: CGFloat) -> Bool {
        guard let range = notchXRange else { return false }
        return midX > range.lowerBound && midX < range.upperBound
    }

    /// Clamps a desired x-position so a control item never lands under the notch.
    ///
    /// If the desired position is inside the notch span, it is pushed to the nearest edge
    /// of the notch (whichever side is closer), keeping the divider visible and functional.
    public func safePlacement(desiredMidX: CGFloat) -> CGFloat {
        guard let range = notchXRange, range.contains(desiredMidX) else {
            return desiredMidX
        }
        let distanceToLeftEdge = desiredMidX - range.lowerBound
        let distanceToRightEdge = range.upperBound - desiredMidX
        return distanceToLeftEdge <= distanceToRightEdge ? range.lowerBound : range.upperBound
    }
}

import CoreGraphics
import Foundation

/// Whether the menu bar on the anchor's display is currently drawn.
///
/// A fullscreen Space or an auto-hidden bar keeps every status window enumerable at its normal
/// frame while nothing is visible, so a screenshot of the strip photographs whatever covers it
/// (opaque black in a fullscreen Space on a notch display). Capturing then can only produce
/// fallbacks, and revealing the hidden section flashes the real items when the bar slides in.
public enum MenuBarVisibility: Equatable, Sendable {
    case visible
    case hidden
    /// No anchor, or an anchor pushed off its display: callers keep their previous behavior.
    case unknown

    /// The anchor never leaves its display, so an anchor inside `displayXRange` that reports
    /// off screen means the whole bar is hidden. `displayXRange` nil falls back to the primary
    /// display's leading edge, the single-display case.
    public static func of(anchor: MenuBarItemSnapshot?, displayXRange: ClosedRange<CGFloat>?) -> MenuBarVisibility {
        guard let anchor else { return .unknown }
        let onDisplay = displayXRange.map { $0.contains(anchor.frame.midX) } ?? (anchor.frame.minX >= 0)
        guard onDisplay else { return .unknown }
        return anchor.isOnScreen ? .visible : .hidden
    }
}

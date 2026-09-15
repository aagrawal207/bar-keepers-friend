import CoreGraphics
import Foundation

/// An immutable description of a single menu bar status item at one moment in time.
///
/// This is the value type every higher layer reasons about. It is deliberately free of
/// any live system handle (no `NSStatusItem`, no `AXUIElement`, no window connection), so
/// the section logic, ordering, and notch math can all be unit-tested from synthetic
/// fixtures without touching the window server.
public struct MenuBarItemSnapshot: Equatable, Hashable, Sendable, Codable {
    /// The CoreGraphics window id backing this status item (`kCGWindowNumber`).
    public let windowID: CGWindowID

    /// PID of the owning process. On macOS 26 the raw `kCGWindowOwnerPID` is unreliable
    /// (FB18327911 reports everything as Control Center), so this is the *attributed*
    /// owner resolved by frame matching — see `AXMenuBarReader`.
    public let ownerPID: pid_t

    /// Bundle identifier of the owning app, if known. `nil` until attribution runs.
    public let ownerBundleID: String?

    /// The item's title (`kCGWindowName`), readable only with Screen Recording permission.
    /// `nil` is a useful signal: a non-owned item with a `nil` title means we lack capture
    /// permission, which the permission layer probes for.
    public let title: String?

    /// The item's frame in global (screen) coordinates.
    public let frame: CGRect

    /// `kCGWindowIsOnscreen`: false for an item pushed past its display's edge, and for every item
    /// while the menu bar itself is hidden (a fullscreen Space, auto-hide). Frames stay valid then.
    public let isOnScreen: Bool

    public init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        ownerBundleID: String? = nil,
        title: String? = nil,
        frame: CGRect,
        isOnScreen: Bool = true
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
    }
}

public extension MenuBarItemSnapshot {
    /// Horizontal midpoint — the value used for section classification and ordering.
    /// The menu bar lays out right-to-left, so a larger `midX` sits further right.
    var midX: CGFloat { frame.midX }

    /// Whether the item is positioned on-screen on its OWN display and so can receive a
    /// synthesized click. `displayMinX` is the global x-origin of the item's display — 0 for the
    /// primary, and the single-display default. The hide mechanism pushes hidden items left of
    /// their display's leading edge (off-screen), so a clickable item is one at or right of that
    /// edge. A plain `minX >= 0` test was wrong on a display positioned left of / above the primary
    /// (negative global x-origin): every legitimate item there has `minX < 0`, so activation was
    /// rejected and the whole "click a mirrored item" feature was dead on that display. Mirrors the
    /// display-relative fixes already applied to the plausibility filter and the move planner.
    func isClickableOnScreen(displayMinX: CGFloat = 0) -> Bool {
        frame.minX >= displayMinX && frame.width > 0
    }

    /// Returns a copy with the owner attribution filled in.
    func attributed(bundleID: String?, pid: pid_t) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: windowID,
            ownerPID: pid,
            ownerBundleID: bundleID ?? ownerBundleID,
            title: title,
            frame: frame,
            isOnScreen: isOnScreen
        )
    }
}

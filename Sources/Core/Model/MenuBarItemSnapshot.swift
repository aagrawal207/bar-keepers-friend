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

    public init(
        windowID: CGWindowID,
        ownerPID: pid_t,
        ownerBundleID: String? = nil,
        title: String? = nil,
        frame: CGRect
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerBundleID = ownerBundleID
        self.title = title
        self.frame = frame
    }
}

public extension MenuBarItemSnapshot {
    /// Horizontal midpoint — the value used for section classification and ordering.
    /// The menu bar lays out right-to-left, so a larger `midX` sits further right.
    var midX: CGFloat { frame.midX }

    /// Returns a copy with the owner attribution filled in.
    func attributed(bundleID: String?, pid: pid_t) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: windowID,
            ownerPID: pid,
            ownerBundleID: bundleID ?? ownerBundleID,
            title: title,
            frame: frame
        )
    }
}

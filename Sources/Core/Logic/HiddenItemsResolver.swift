import CoreGraphics
import Foundation

/// Determines which menu bar items belong to the hidden section — those positioned to the
/// left of the anchor control item — so the floating bar can mirror them.
///
/// "Hidden" is defined by position relative to the anchor, not by being fully off-screen.
/// This is robust to how far the expanded divider has pushed items (off-screen at negative
/// x when expanded, or just left of the anchor when not) and naturally excludes the
/// always-visible right-side system items (clock, Control Center).
///
/// Pure: given the enumerated snapshots and the anchor's leading edge, it returns the
/// hidden items in left-to-right order. No window-server access, fully unit-testable.
public enum HiddenItemsResolver {

    /// Window-name prefix the app gives its own control items (the `autosaveName`, which
    /// surfaces as `kCGWindowName`). Used to exclude our own items by name — robust on
    /// Tahoe where owner PID is unreliable (FB18327911) and window-id sets can be stale.
    public static let controlItemNamePrefix = "BKF"

    /// Returns the hidden items: those lying entirely to the left of `anchorMinX` (the
    /// anchor control item's leading edge). The app's own control items are excluded by
    /// window id AND by name prefix, and system items that must not be touched are dropped
    /// via the immovable denylist.
    ///
    /// Results are ordered left-to-right by position, the order the user sees in the menu bar.
    public static func hiddenItems(
        from items: [MenuBarItemSnapshot],
        leftOfAnchorX anchorMinX: CGFloat,
        excludingControlItems controlItemWindowIDs: Set<CGWindowID> = []
    ) -> [MenuBarItemSnapshot] {
        items
            .filter { !controlItemWindowIDs.contains($0.windowID) }
            .filter { !isOwnControlItem($0) }
            .filter { !ImmovableItems.isImmovable($0) }
            .filter { $0.frame.maxX <= anchorMinX }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Whether a snapshot is one of the app's own control items, identified by its window
    /// name prefix (`BKFAnchor` / `BKFHidden` / `BKFAlwaysHidden`).
    public static func isOwnControlItem(_ item: MenuBarItemSnapshot) -> Bool {
        guard let title = item.title else { return false }
        return title.hasPrefix(controlItemNamePrefix)
    }
}

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
            .filter { isPlausibleMenuBarItem($0) }
            .filter { !controlItemWindowIDs.contains($0.windowID) }
            .filter { !isOwnControlItem($0) }
            .filter { !ImmovableItems.isImmovable($0) }
            .filter { $0.frame.maxX <= anchorMinX }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Rejects windows that sit at the status-window layer but aren't real menu bar glyphs:
    /// 1×1 placeholder/junk windows, and tall popover panels (e.g. a clipboard manager's
    /// 450×800 popup) that an app parks at the status layer. A genuine status item is about
    /// as tall as the menu bar (notch items report ~24 pt, normal items ~33 pt; test
    /// fixtures use 22 pt) and at least a few points wide.
    ///
    /// Bounds are fixed absolutes, deliberately NOT tied to `NSStatusBar.thickness`: that is a
    /// single value and can't bracket both the 24 pt notch item and 33 pt normal items within
    /// one tolerance band. There is no upper width bound — legitimately wide items exist (Now
    /// Playing, date/time, iStat Menus), and height alone already rejects the popup panels.
    public static func isPlausibleMenuBarItem(_ item: MenuBarItemSnapshot) -> Bool {
        let minHeight: CGFloat = 18
        let maxHeight: CGFloat = 40
        let minWidth: CGFloat = 6
        // The menu bar sits at the top of the display (global top-left origin → y ≈ 0). A
        // status-layer window far down the screen is not a menu bar item — e.g. an app's
        // transient notification window (observed at y≈916) that shares the status layer.
        // (Single-display assumption, matching the rest of the app; a display positioned
        // below the primary would need the per-display menu-bar y instead of this constant.)
        let maxTop: CGFloat = 40
        return item.frame.height >= minHeight
            && item.frame.height <= maxHeight
            && item.frame.width >= minWidth
            && item.frame.minY <= maxTop
    }

    /// Whether a snapshot is one of the app's own control items, identified by its window
    /// name prefix (`BKFAnchor` / `BKFHidden` / `BKFAlwaysHidden`).
    public static func isOwnControlItem(_ item: MenuBarItemSnapshot) -> Bool {
        guard let title = item.title else { return false }
        return title.hasPrefix(controlItemNamePrefix)
    }

    /// Collapses co-located windows that back the same visible status item into one.
    ///
    /// On Tahoe `CGWindowListCopyWindowInfo` can return more than one status-layer window at
    /// effectively the same position for a single visible icon (a backing window plus the
    /// glyph window), which otherwise shows up as a duplicate row in the floating bar
    /// (e.g. "Maccy" / "Maccy"). Items whose horizontal midpoints fall within `tolerance`
    /// points of an already-kept item are treated as duplicates and dropped.
    ///
    /// The first item in the input order wins. Callers pass the list already ordered
    /// left-to-right, and the sort is stable, so co-located windows keep their enumeration
    /// (front-to-back) order — the frontmost, interactive window is retained.
    ///
    /// `tolerance` is deliberately small: genuine duplicates share a midpoint to within a
    /// pixel or two, while distinct neighbouring icons sit ~24 pt apart, so a 7 pt window
    /// separates the two cases without ever merging real neighbours.
    public static func deduplicateByMidXProximity(
        _ items: [MenuBarItemSnapshot],
        tolerance: CGFloat = 7
    ) -> [MenuBarItemSnapshot] {
        var kept: [MenuBarItemSnapshot] = []
        for item in items {
            let isDuplicate = kept.contains { abs($0.frame.midX - item.frame.midX) <= tolerance }
            if !isDuplicate { kept.append(item) }
        }
        return kept
    }
}

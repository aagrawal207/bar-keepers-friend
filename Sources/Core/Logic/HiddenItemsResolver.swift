import CoreGraphics
import Foundation

/// Determines which menu bar items are currently hidden — i.e. pushed off the visible menu
/// bar by an expanded divider — so the floating bar can mirror them.
///
/// Pure: given the enumerated status-item snapshots and where the visible menu bar starts,
/// it returns the off-screen items in their natural left-to-right order. No window-server
/// access, so it is fully unit-testable from fixtures.
public enum HiddenItemsResolver {

    /// Returns the hidden items: those lying entirely to the left of `visibleMinX`
    /// (the left edge of the on-screen menu bar, normally `0`). The app's own control
    /// items are excluded by window id, and system items that must not be touched are
    /// dropped via the immovable denylist.
    ///
    /// Results are ordered left-to-right by their original on-screen position, which is the
    /// order the user is used to seeing in the menu bar.
    public static func hiddenItems(
        from items: [MenuBarItemSnapshot],
        visibleMinX: CGFloat = 0,
        excludingControlItems controlItemWindowIDs: Set<CGWindowID> = []
    ) -> [MenuBarItemSnapshot] {
        items
            .filter { !controlItemWindowIDs.contains($0.windowID) }
            .filter { !ImmovableItems.isImmovable($0) }
            .filter { $0.frame.maxX <= visibleMinX }
            .sorted { $0.frame.minX < $1.frame.minX }
    }
}

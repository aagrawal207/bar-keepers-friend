import CoreGraphics
import Foundation

/// Plans explicit Hidden/Shown intent using pure geometry: Hidden is entirely left of the divider;
/// Shown is entirely right of the anchor. Items between the controls satisfy neither placement.
public enum HiddenLayoutPlanner {

    /// `targetX` is a cursor drop position in CG global coordinates, not the item's leading edge.
    public struct Move: Equatable, Sendable {
        public let item: MenuBarItemSnapshot
        public let targetX: CGFloat
        public init(item: MenuBarItemSnapshot, targetX: CGFloat) {
            self.item = item
            self.targetX = targetX
        }
    }

    /// Requires attributed items and live control edges. An optional display range excludes mirrors;
    /// `displayMenuBarTop` scopes plausibility to that display's menu-bar row.
    public static func moves(
        for items: [MenuBarItemSnapshot],
        anchorMinX: CGFloat,
        anchorMaxX: CGFloat,
        dividerMinX: CGFloat,
        controls: ItemControlStore,
        excludingWindowIDs: Set<CGWindowID> = [],
        immovablePIDs: Set<pid_t> = [],
        displayXRange: ClosedRange<CGFloat>? = nil,
        displayMenuBarTop: CGFloat = 0
    ) -> [Move] {
        guard dividerMinX <= anchorMinX, anchorMinX < anchorMaxX else { return [] }
        let hiddenTargetX = dividerMinX - hiddenMargin
        let shownTargetX = anchorMaxX + shownMargin

        var result: [Move] = []
        for item in items {
            guard !excludingWindowIDs.contains(item.windowID), !HiddenItemsResolver.isOwnControlItem(item) else { continue }
            // Other displays' mirror windows cannot be rearranged from the anchor's display.
            if let range = displayXRange, !range.contains(item.frame.midX) { continue }
            // Transient status-layer windows can share an app's intent key without being glyphs.
            guard HiddenItemsResolver.isPlausibleMenuBarItem(item, displayMenuBarTop: displayMenuBarTop) else { continue }
            // No stable identity → intent can't be keyed to it → leave it where the user put it.
            guard ItemControlStore.key(for: item) != nil else { continue }
            // PID/display-label exclusions are safe only after ownership attribution.
            guard !ImmovableItems.isImmovable(item, immovablePIDs: immovablePIDs) else { continue }
            // Never rearrange an unconfigured neighbor as a side effect of another item's intent.
            guard controls.hasPlacementIntent(item) else { continue }

            let wantHidden = controls.isHidden(item)
            guard !isPlacementSatisfied(
                item: item, hidden: wantHidden, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX
            ) else { continue }

            result.append(Move(item: item, targetX: wantHidden ? hiddenTargetX : shownTargetX))
        }
        return result
    }

    public static func isPlacementSatisfied(
        item: MenuBarItemSnapshot, hidden: Bool, anchorMaxX: CGFloat, dividerMinX: CGFloat
    ) -> Bool {
        hidden ? item.frame.maxX <= dividerMinX : item.frame.minX >= anchorMaxX
    }

    /// Cursor-drop margin left of the divider, which pushes only its left neighbors off-screen.
    public static let hiddenMargin: CGFloat = 8
    /// How far past the anchor's trailing edge a newly-shown item is dragged.
    public static let shownMargin: CGFloat = 8
}

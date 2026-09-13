import CoreGraphics
import Foundation

/// Plans explicit placement intent using pure geometry: each tier is entirely on its side of its
/// control (Hidden also right of the always-hidden divider). Items between controls satisfy none.
public enum HiddenLayoutPlanner {

    /// `targetX` is a cursor drop position in CG global coordinates, not the item's leading edge.
    /// `placement` is the tier the drop targets, already degraded when its divider is absent.
    public struct Move: Equatable, Sendable {
        public let item: MenuBarItemSnapshot
        public let targetX: CGFloat
        public let placement: ItemPlacement
        public init(item: MenuBarItemSnapshot, targetX: CGFloat, placement: ItemPlacement = .hidden) {
            self.item = item
            self.targetX = targetX
            self.placement = placement
        }
    }

    /// Requires attributed items and live control edges. An optional display range excludes mirrors;
    /// `displayMenuBarTop` scopes plausibility to that display's menu-bar row. Without an
    /// always-hidden divider frame the output matches the two-tier planner exactly.
    public static func moves(
        for items: [MenuBarItemSnapshot],
        anchorMinX: CGFloat,
        anchorMaxX: CGFloat,
        dividerMinX: CGFloat,
        controls: ItemControlStore,
        excludingWindowIDs: Set<CGWindowID> = [],
        immovablePIDs: Set<pid_t> = [],
        displayXRange: ClosedRange<CGFloat>? = nil,
        displayMenuBarTop: CGFloat = 0,
        alwaysHiddenDividerFrame: CGRect? = nil
    ) -> [Move] {
        guard dividerMinX <= anchorMinX, anchorMinX < anchorMaxX else { return [] }
        if let frame = alwaysHiddenDividerFrame {
            // An always-hidden divider right of the hidden divider would invert the tiers.
            guard frame.minX <= frame.maxX, frame.maxX <= dividerMinX else { return [] }
        }

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
            guard let intent = controls.placement(for: item) else { continue }

            let placement = effectivePlacement(intent, hasAlwaysHiddenDivider: alwaysHiddenDividerFrame != nil)
            guard !isPlacementSatisfied(
                item: item, placement: placement, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
                alwaysHiddenDividerFrame: alwaysHiddenDividerFrame
            ) else { continue }

            result.append(Move(
                item: item,
                targetX: targetX(
                    for: placement, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
                    alwaysHiddenDividerFrame: alwaysHiddenDividerFrame
                ),
                placement: placement
            ))
        }
        return result
    }

    /// Without its divider the always-hidden tier can only be approximated by the hidden one.
    public static func effectivePlacement(_ placement: ItemPlacement, hasAlwaysHiddenDivider: Bool) -> ItemPlacement {
        placement == .alwaysHidden && !hasAlwaysHiddenDivider ? .hidden : placement
    }

    public static func isPlacementSatisfied(
        item: MenuBarItemSnapshot, hidden: Bool, anchorMaxX: CGFloat, dividerMinX: CGFloat
    ) -> Bool {
        isPlacementSatisfied(
            item: item, placement: ItemPlacement(hidden: hidden), anchorMaxX: anchorMaxX,
            dividerMinX: dividerMinX, alwaysHiddenDividerFrame: nil
        )
    }

    /// Full-edge postcondition per tier. Hidden must also clear the always-hidden divider's trailing
    /// edge when that divider exists, otherwise a tucked item would count as merely hidden.
    public static func isPlacementSatisfied(
        item: MenuBarItemSnapshot, placement: ItemPlacement, anchorMaxX: CGFloat, dividerMinX: CGFloat,
        alwaysHiddenDividerFrame: CGRect?
    ) -> Bool {
        switch effectivePlacement(placement, hasAlwaysHiddenDivider: alwaysHiddenDividerFrame != nil) {
        case .shown:
            return item.frame.minX >= anchorMaxX
        case .hidden:
            guard item.frame.maxX <= dividerMinX else { return false }
            guard let frame = alwaysHiddenDividerFrame else { return true }
            return item.frame.minX >= frame.maxX
        case .alwaysHidden:
            guard let frame = alwaysHiddenDividerFrame else { return item.frame.maxX <= dividerMinX }
            return item.frame.maxX <= frame.minX
        }
    }

    /// The cursor drop position that lands an item in `placement`, given live control edges.
    public static func targetX(
        for placement: ItemPlacement, anchorMaxX: CGFloat, dividerMinX: CGFloat, alwaysHiddenDividerFrame: CGRect?
    ) -> CGFloat {
        switch effectivePlacement(placement, hasAlwaysHiddenDivider: alwaysHiddenDividerFrame != nil) {
        case .shown: return anchorMaxX + shownMargin
        case .hidden: return dividerMinX - hiddenMargin
        case .alwaysHidden: return (alwaysHiddenDividerFrame?.minX ?? dividerMinX) - hiddenMargin
        }
    }

    /// Cursor-drop margin left of a divider, which pushes only its left neighbors off-screen.
    public static let hiddenMargin: CGFloat = 8
    /// How far past the anchor's trailing edge a newly-shown item is dragged.
    public static let shownMargin: CGFloat = 8
}

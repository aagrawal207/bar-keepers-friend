import CoreGraphics
import Foundation

/// Whether shown items may be swapped past the notch so a revealed hidden section fits on screen.
/// Raw values are persisted under the `notchOverflow` preference key; never rename them.
public enum NotchOverflowMode: String, Codable, Sendable, CaseIterable {
    case never
    case whenNeeded
}

/// The bar packs right-to-left and macOS drops whatever reaches the notch, so swapping the shown items
/// nearest the anchor to the far left of a revealed section frees exactly their width for hidden items.
public enum NotchOverflowPlanner {

    /// The revealed layout on the anchor's display, classified by live control edges. Items in the gap
    /// between the divider and the anchor, off the display, or implausible as glyphs are in neither list.
    public struct RevealedLayout: Equatable, Sendable {
        /// Items entirely inside the hidden section, left to right.
        public let hidden: [MenuBarItemSnapshot]
        /// Items entirely right of the anchor, left to right (nearest the anchor first).
        public let shown: [MenuBarItemSnapshot]
        public let anchor: CGRect
        public let divider: CGRect
        public let alwaysHiddenDivider: CGRect?

        public init(
            hidden: [MenuBarItemSnapshot], shown: [MenuBarItemSnapshot],
            anchor: CGRect, divider: CGRect, alwaysHiddenDivider: CGRect?
        ) {
            self.hidden = hidden
            self.shown = shown
            self.anchor = anchor
            self.divider = divider
            self.alwaysHiddenDivider = alwaysHiddenDivider
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Shown items to tuck, nearest the anchor first.
        public let victims: [MenuBarItemSnapshot]
        /// Width the victims free once they leave the shown section.
        public let freedWidth: CGFloat
        /// Width the hidden section lacked right of the notch before any move.
        public let requiredWidth: CGFloat
        /// Width still missing after every victim moves; positive when nothing movable remains.
        public let deficit: CGFloat

        public init(victims: [MenuBarItemSnapshot], freedWidth: CGFloat, requiredWidth: CGFloat, deficit: CGFloat) {
            self.victims = victims
            self.freedWidth = freedWidth
            self.requiredWidth = requiredWidth
            self.deficit = deficit
        }

        public static let empty = Plan(victims: [], freedWidth: 0, requiredWidth: 0, deficit: 0)

        public var isEmpty: Bool { victims.isEmpty }
        public var isSatisfied: Bool { deficit <= 0 }
        public var victimWindowIDs: [CGWindowID] { victims.map(\.windowID) }

        /// Furthest from the anchor first: each victim drops left of the section's current leftmost
        /// item, so this order keeps the victims' relative order once they are all at the far left.
        public var tuckSequence: [MenuBarItemSnapshot] { victims.reversed() }

        /// Original left-to-right order: restoring each victim right of its predecessor (the anchor
        /// for the first) recreates the arrangement regardless of which tucks succeeded.
        public var restoreSequence: [MenuBarItemSnapshot] { victims }
    }

    /// Classifies raw snapshots against the controls of one display. Only items whose midpoint is on
    /// `notch.displayFrame` count, matching the move planner's convention for other displays' mirrors.
    public static func classify(
        items: [MenuBarItemSnapshot],
        anchor: CGRect,
        divider: CGRect,
        alwaysHiddenDivider: CGRect?,
        notch: NotchGeometry,
        displayMenuBarTop: CGFloat = 0,
        excludingWindowIDs: Set<CGWindowID> = []
    ) -> RevealedLayout {
        let display = notch.displayFrame
        let candidates: [MenuBarItemSnapshot]
        if display.minX.isFinite, display.maxX.isFinite, display.minX < display.maxX {
            let range = display.minX...display.maxX
            candidates = items.filter {
                !excludingWindowIDs.contains($0.windowID)
                    && !HiddenItemsResolver.isOwnControlItem($0)
                    && HiddenItemsResolver.isPlausibleMenuBarItem($0, displayMenuBarTop: displayMenuBarTop)
                    && range.contains($0.frame.midX)
            }
        } else {
            candidates = []
        }
        let hidden = candidates.filter { item in
            item.frame.maxX <= divider.minX
                && (alwaysHiddenDivider.map { item.frame.minX >= $0.maxX } ?? true)
        }
        let shown = candidates.filter { $0.frame.minX >= anchor.maxX }
        let byMinX: (MenuBarItemSnapshot, MenuBarItemSnapshot) -> Bool = { $0.frame.minX < $1.frame.minX }
        return RevealedLayout(
            // Co-located backing windows move with their glyph, so they must not be counted twice.
            hidden: HiddenItemsResolver.deduplicateByMidXProximity(hidden.sorted(by: byMinX)),
            shown: HiddenItemsResolver.deduplicateByMidXProximity(shown.sorted(by: byMinX)),
            anchor: anchor,
            divider: divider,
            alwaysHiddenDivider: alwaysHiddenDivider
        )
    }

    /// A revealed divider sits at its natural width on its display; an expanded one is wider than the
    /// display, with its midpoint pushed off the left edge.
    public static func isDividerRevealed(_ divider: CGRect, displayFrame: CGRect) -> Bool {
        guard divider.minX.isFinite, divider.maxX.isFinite, divider.width.isFinite,
              displayFrame.width.isFinite, displayFrame.width > 0 else { return false }
        return divider.width < displayFrame.width
            && divider.midX >= displayFrame.minX && divider.midX <= displayFrame.maxX
    }

    /// Width the hidden section lacks right of the notch: the distance from its leftmost item's leading
    /// edge to the right usable area. An item straddling the notch edge counts, not just one centered on it.
    public static func deficit(hidden: [MenuBarItemSnapshot], notch: NotchGeometry) -> CGFloat {
        guard notch.hasNotch, let rightArea = notch.rightArea,
              let leftmost = hidden.map(\.frame.minX).min(), leftmost.isFinite else { return 0 }
        return max(0, rightArea.minX - leftmost)
    }

    public static func needsRoom(hidden: [MenuBarItemSnapshot], notch: NotchGeometry) -> Bool {
        deficit(hidden: hidden, notch: notch) > 0
    }

    /// Greedy from the anchor outwards: moving the nearest shown items frees space exactly where the
    /// hidden items appear. `immovable` runs on the caller's attributed snapshots.
    public static func plan(
        layout: RevealedLayout,
        notch: NotchGeometry,
        immovable: (MenuBarItemSnapshot) -> Bool
    ) -> Plan {
        let required = deficit(hidden: layout.hidden, notch: notch)
        guard required > 0 else { return .empty }
        var victims: [MenuBarItemSnapshot] = []
        var freed: CGFloat = 0
        for item in layout.shown where !immovable(item) {
            victims.append(item)
            freed += item.frame.width
            if freed >= required { break }
        }
        return Plan(victims: victims, freedWidth: freed, requiredWidth: required, deficit: max(0, required - freed))
    }

    /// Cursor drop position that lands an item as the immediate left neighbor of `reference`.
    public static func tuckTargetX(leftOf reference: CGRect) -> CGFloat {
        reference.minX - HiddenLayoutPlanner.hiddenMargin
    }

    /// Cursor drop position that lands an item as the immediate right neighbor of `reference`.
    public static func restoreTargetX(rightOf reference: CGRect) -> CGFloat {
        reference.maxX + HiddenLayoutPlanner.shownMargin
    }

    /// Full-edge postcondition for a tuck: left of the reference it was dropped beside and still inside
    /// the hidden section, so a drop that overshot into the always-hidden tier does not count.
    public static func isTucked(
        _ item: MenuBarItemSnapshot, leftOf reference: CGRect, dividerMinX: CGFloat, alwaysHiddenDividerMaxX: CGFloat?
    ) -> Bool {
        guard item.frame.maxX <= reference.minX, item.frame.maxX <= dividerMinX else { return false }
        return alwaysHiddenDividerMaxX.map { item.frame.minX >= $0 } ?? true
    }

    /// Full-edge postcondition for a restore: right of the reference it was dropped beside and of the anchor.
    public static func isRestored(_ item: MenuBarItemSnapshot, rightOf referenceMaxX: CGFloat, anchorMaxX: CGFloat) -> Bool {
        item.frame.minX >= referenceMaxX && item.frame.minX >= anchorMaxX
    }

    /// The anchor or nearest shown-section item left of a victim (own group/widget icons count), so it can
    /// return to its slot; nil when the anchor is missing or the victim is not in the shown section.
    public static func leftNeighbor(
        of item: MenuBarItemSnapshot,
        in items: [MenuBarItemSnapshot],
        anchorWindowID: CGWindowID,
        displayMenuBarTop: CGFloat = 0
    ) -> MenuBarItemSnapshot? {
        guard let anchor = items.first(where: { $0.windowID == anchorWindowID }),
              item.windowID != anchorWindowID, item.frame.minX >= anchor.frame.maxX else { return nil }
        // The victim's own co-located backing windows end near its trailing edge, so they never qualify.
        let candidates = items.filter { candidate in
            candidate.windowID != item.windowID
                && candidate.frame.maxX <= item.frame.minX + neighborTolerance
                && (candidate.windowID == anchorWindowID
                    || (candidate.frame.minX >= anchor.frame.maxX
                        && HiddenItemsResolver.isPlausibleMenuBarItem(candidate, displayMenuBarTop: displayMenuBarTop)))
        }
        return candidates.max { $0.frame.maxX < $1.frame.maxX }
    }

    /// Sub-item slack for abutting edges; real neighbors touch, distinct icons sit tens of points apart.
    public static let neighborTolerance: CGFloat = 1
}

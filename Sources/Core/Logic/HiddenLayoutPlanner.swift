import CoreGraphics
import Foundation

/// Turns the user's per-item hide intent into the concrete menu-bar moves needed to realize it.
///
/// The model is positional, like Bartender/Ice: an item is "hidden" when it sits to the LEFT of
/// our anchor (where the expanded divider pushes it off-screen and the floating bar mirrors it),
/// and "shown" when it sits to the RIGHT of the anchor. The user toggles intent per item; this
/// planner compares that intent against where each item currently is and emits a move for every
/// item on the wrong side. Everything here is pure geometry over value types, so it's unit-tested
/// against fixtures — the fragile part (actually performing a move) lives behind `WindowServer`.
///
/// Why a planner rather than moving inline: deciding *what* to move is separable from *how*, and
/// the "what" has real edge cases (immovable system items must never be targeted; an item with no
/// stable identity can't carry intent; items already on the correct side must not be disturbed,
/// or every refresh would needlessly drag icons around). Isolating it makes those rules testable.
public enum HiddenLayoutPlanner {

    /// One planned move: drag `item` so its leading edge lands at `targetX` (CG global x).
    public struct Move: Equatable, Sendable {
        public let item: MenuBarItemSnapshot
        public let targetX: CGFloat
        public init(item: MenuBarItemSnapshot, targetX: CGFloat) {
            self.item = item
            self.targetX = targetX
        }
    }

    /// Computes the moves that reconcile the live menu bar with the user's hide intent.
    ///
    /// - Parameters:
    ///   - items: the current status items in any order, with live frames (CG global, top-left).
    ///   - anchorMinX: the leading (left) edge of our anchor — the hide/show boundary.
    ///   - anchorMaxX: the trailing (right) edge of our anchor.
    ///   - controls: the user's per-item hide intent (`hiddenInMenuBar`).
    ///   - excludingWindowIDs: our own control items (anchor + divider), never moved.
    ///   - displayXRange: the global x-range of the display the anchor currently lives on. On a
    ///     multi-display rig each display has its own menu bar, so `menuBarItems()` enumerates the
    ///     status windows of ALL of them — but only the copy on the anchor's display is movable
    ///     (the others are static mirrors at far-away x). When provided, items whose midpoint falls
    ///     outside this range are skipped, so a reconcile never burns the retry budget failing on an
    ///     off-display window. `nil` (the default) disables the filter for single-display callers
    ///     and the `FakeWindowServer` tests, whose fixtures are all on one notional display.
    ///
    /// An item is left alone unless three things hold: it has a stable identity (so intent can be
    /// keyed to it), it isn't a system item we must not move, and it's currently on the WRONG side
    /// of the anchor for its intent. Hidden-but-currently-shown items get a target left of the
    /// anchor; shown-but-currently-hidden items get a target right of it.
    public static func moves(
        for items: [MenuBarItemSnapshot],
        anchorMinX: CGFloat,
        anchorMaxX: CGFloat,
        controls: ItemControlStore,
        excludingWindowIDs: Set<CGWindowID> = [],
        immovablePIDs: Set<pid_t> = [],
        displayXRange: ClosedRange<CGFloat>? = nil,
        displayMenuBarTop: CGFloat = 0
    ) -> [Move] {
        // Targets just past each anchor edge. The window server snaps a dragged item into the
        // nearest real slot, so these need only land unambiguously on the correct side — a small
        // margin past the edge is enough and keeps us clear of the anchor itself.
        let hiddenTargetX = anchorMinX - hiddenMargin
        let shownTargetX = anchorMaxX + shownMargin

        var result: [Move] = []
        for item in items {
            guard !excludingWindowIDs.contains(item.windowID) else { continue }
            // Skip items on a different display than the anchor. Each display has its own menu bar,
            // so the enumeration includes mirror copies at the other displays' coordinates; only the
            // copy sharing the anchor's display is movable. Filtering here keeps the move from
            // failing-and-retrying against an off-display window (the multi-display flakiness).
            if let range = displayXRange, !range.contains(item.frame.midX) { continue }
            // Not a real menu bar glyph → never try to move it. Some apps park transient windows at
            // the status-window layer (e.g. Karabiner's notification window, observed far down the
            // screen, and tall popover panels). These share their app's owner key, so without this
            // guard a "hide Karabiner" intent would also target the notification window, which can't
            // move — burning the full retry budget per stray window. `isPlausibleMenuBarItem`
            // (height/width/top-edge bounds) is the same filter the floating-bar resolver uses.
            // `displayMenuBarTop` makes the top-edge test relative to the anchor's display, so an
            // item on a display stacked above/below the primary isn't wrongly rejected.
            guard HiddenItemsResolver.isPlausibleMenuBarItem(item, displayMenuBarTop: displayMenuBarTop) else { continue }
            // No stable identity → intent can't be keyed to it → leave it where the user put it.
            guard ItemControlStore.key(for: item) != nil else { continue }
            // System items that corrupt the layout if moved are never targeted. Pass the
            // immovable-pid set so every Control Center module (they all share Control Center's pid)
            // and the app's own status windows are refused in one check — locale-independent, and it
            // stops a stray "Hide All" from trying (and forever failing) to relocate them.
            guard !ImmovableItems.isImmovable(item, immovablePIDs: immovablePIDs) else { continue }
            // Only move items the user has EXPLICITLY placed (Hidden or Shown). An item the user
            // never toggled has no intent, so we leave it exactly where it is — otherwise hiding a
            // single item would yank every other not-hidden item to the shown side of the anchor.
            guard controls.hasPlacementIntent(item) else { continue }

            let wantHidden = controls.isHidden(item)
            let isHidden = item.frame.minX < anchorMinX
            guard wantHidden != isHidden else { continue } // already on the correct side

            result.append(Move(item: item, targetX: wantHidden ? hiddenTargetX : shownTargetX))
        }
        return result
    }

    /// How far past the anchor's leading edge a newly-hidden item is dragged. A few points is
    /// plenty: it only has to be unambiguously left of the boundary before the divider expands.
    public static let hiddenMargin: CGFloat = 8
    /// How far past the anchor's trailing edge a newly-shown item is dragged.
    public static let shownMargin: CGFloat = 8
}

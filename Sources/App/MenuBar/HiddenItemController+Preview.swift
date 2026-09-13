import AppKit
import BarKeepersFriendCore

extension HiddenItemController {
    /// The moves `reconcile` would plan now, with its exact filters but no reveal or move; `nil`
    /// means unreadable or cancelled, never "satisfied". Dividers may still be expanded here.
    func previewMoves(
        anchorWindowID: CGWindowID,
        dividerWindowID: CGWindowID,
        alwaysHiddenDividerWindowID: CGWindowID? = nil,
        controls: ItemControlStore,
        displayXRange: ClosedRange<CGFloat>? = nil,
        displayMenuBarTop: CGFloat = 0
    ) async -> Int? {
        do {
            let plan = try await observeAndPlan(
                controls: ControlWindows(anchor: anchorWindowID, divider: dividerWindowID, alwaysHidden: alwaysHiddenDividerWindowID),
                intent: controls, displayXRange: displayXRange, displayMenuBarTop: displayMenuBarTop,
                tolerateExpandedDividers: true
            )
            DebugLog.log("HiddenItemController: preview \(plan.snapshots.count) items, plan=\(plan.moves.count) moves")
            return plan.moves.count
        } catch {
            DebugLog.log("HiddenItemController: preview unavailable: \(error)")
            return nil
        }
    }
}

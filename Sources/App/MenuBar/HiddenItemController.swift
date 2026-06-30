import AppKit
import BarKeepersFriendCore

/// Reconciles the live menu bar with the user's per-item Shown/Hidden intent by physically
/// moving items across the anchor.
///
/// This is the app-side glue for the Bartender-style per-item control. The DECISION of what to
/// move is the pure `HiddenLayoutPlanner`; this type performs the resulting moves through the
/// `WindowServer` seam (the only place the fragile synthesized-drag private API is touched) and
/// reports the outcome. It is deliberately small: enumerate → plan → move each → report.
///
/// ## Why moves can fail, and what we do about it
///
/// Moving another app's status item relies on undocumented window-server behavior that Apple has
/// broken before and may break again. So every move is best-effort and self-validating:
/// `WindowServer.move` confirms the item's frame actually changed and retries, throwing if it
/// can't. We collect failures rather than trapping, so one stubborn item never blocks the rest,
/// and the caller can surface "couldn't move N items" and fall back to leaving them where they are.
@MainActor
final class HiddenItemController {
    private let windowServer: WindowServer

    /// Resolves each raw snapshot's REAL owning app (pid + name). On macOS 26 the snapshots from
    /// `WindowServer.menuBarItems()` carry the broken `kCGWindowOwnerPID` (Control Center / -1,
    /// FB18327911); the synthesized move's "scromble" relay must target the item's TRUE owning pid
    /// or it taps the wrong process and the move silently fails. The app injects an Accessibility-
    /// based attributor here; the default is identity so `FakeWindowServer`-backed tests (whose
    /// snapshots already carry correct pids) are unaffected.
    private let attribute: ([MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot]

    /// Our own control-item window ids (anchor + divider), never moved. Refreshed by the engine.
    var controlItemWindowIDs: Set<CGWindowID> = []

    init(
        windowServer: WindowServer,
        attribute: @escaping ([MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot] = { $0 }
    ) {
        self.windowServer = windowServer
        self.attribute = attribute
    }

    /// The result of a reconcile pass: how many moves were planned, how many succeeded, and the
    /// items that wouldn't budge (so the caller can decide whether to warn or fall back).
    struct ReconcileResult {
        var planned: Int = 0
        var succeeded: Int = 0
        var failed: [MenuBarItemSnapshot] = []
        var allSucceeded: Bool { failed.isEmpty }
    }

    /// Whether the app can physically move items right now (Accessibility granted). When false,
    /// the per-item Hidden control can't take effect, so the UI should route the user to grant it
    /// rather than silently doing nothing.
    var canMoveItems: Bool { windowServer.canSynthesizeClicks }

    /// Brings the live menu bar in line with `controls`: every item on the wrong side of the
    /// anchor for its intent is moved to the correct side. Returns what happened.
    ///
    /// `anchorMinX`/`anchorMaxX` are the anchor's current global edges (the hide/show boundary).
    /// `displayXRange`, when set, scopes moves to the display the anchor lives on — essential on a
    /// multi-display rig, where the enumeration includes the other displays' (immovable) mirror
    /// copies of each item. No-op (empty result) when nothing needs moving, so it's cheap to call on
    /// every settings change or menu-bar refresh.
    @discardableResult
    func reconcile(anchorMinX: CGFloat, anchorMaxX: CGFloat, controls: ItemControlStore, displayXRange: ClosedRange<CGFloat>? = nil, displayMenuBarTop: CGFloat = 0) async -> ReconcileResult {
        var result = ReconcileResult()

        // Attribute first so each snapshot carries its REAL owning pid (not Tahoe's broken
        // Control-Center pid). The move's relay targets that pid, so wrong attribution = the move
        // taps the wrong process and fails. The planner's side-of-anchor decision is unaffected by
        // attribution (it's pure geometry), but the moved snapshot must carry the true pid.
        let snapshots = await attribute((try? windowServer.menuBarItems()) ?? [])
        let plan = HiddenLayoutPlanner.moves(
            for: snapshots,
            anchorMinX: anchorMinX,
            anchorMaxX: anchorMaxX,
            controls: controls,
            excludingWindowIDs: controlItemWindowIDs,
            // Never plan a move for Control Center's modules (one shared pid) or our own status
            // windows. Without this a "Hide All" that swept them in makes reconcile re-plan the same
            // un-relocatable moves on every pass and never converge — the bug where the anchor walks
            // across the bar and nothing settles. Snapshots are attributed just above, so each
            // carries its real owning pid (the only state in which a pid set is valid).
            immovablePIDs: ImmovableProcessIDs.current(),
            displayXRange: displayXRange,
            displayMenuBarTop: displayMenuBarTop
        )
        result.planned = plan.count
        DebugLog.log("reconcile: \(snapshots.count) items, plan=\(plan.count) moves; anchorMinX=\(anchorMinX) hidden=\(controls.hiddenInMenuBar)")
        guard !plan.isEmpty else { return result }

        // Moves run sequentially, NOT concurrently: each one synthesizes events the window server
        // routes by windowID, and overlapping two moves races the shared menu-bar layout (the
        // research notes the mechanism goes sluggish/flaky under load). A failure on one must not
        // abort the others — collect failures and continue. We re-target the SAME planned
        // destinations even though earlier moves shift neighbors, because the window server snaps
        // the item to the nearest real slot on the correct side of the anchor; the exact x only
        // has to land on the right side, which the planner's margins guarantee.
        for move in plan {
            do {
                try await windowServer.move(item: move.item, toX: move.targetX)
                result.succeeded += 1
                DebugLog.log("HiddenItemController: move OK for \(move.item.windowID) (\(move.item.ownerBundleID ?? "?")) pid=\(move.item.ownerPID) -> x=\(move.targetX)")
            } catch {
                DebugLog.log("HiddenItemController: move failed for \(move.item.windowID) (\(move.item.ownerBundleID ?? "?")) pid=\(move.item.ownerPID): \(error)")
                result.failed.append(move.item)
            }
        }
        DebugLog.log("HiddenItemController: reconcile planned=\(result.planned) ok=\(result.succeeded) failed=\(result.failed.count)")
        return result
    }
}

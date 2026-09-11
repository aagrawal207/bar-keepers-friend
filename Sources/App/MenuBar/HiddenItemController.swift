import AppKit
import BarKeepersFriendCore

/// Applies explicit placement intent sequentially through `WindowServer`, using live control edges.
/// Native return values are not proof of placement: each success requires a fresh side check.
@MainActor
final class HiddenItemController {
    private let windowServer: WindowServer

    /// Tahoe's raw owner PID/name are unreliable; the relay needs AX-attributed ownership.
    /// Identity attribution is suitable only for fixtures that already carry trusted owners.
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
        var cancelled = false
        var observationFailed: Bool = false
        var allSucceeded: Bool { !cancelled && !observationFailed && failed.isEmpty }
    }

    /// Whether the app can physically move items right now (Accessibility granted). When false,
    /// the per-item Hidden control can't take effect, so the UI should route the user to grant it
    /// rather than silently doing nothing.
    var canMoveItems: Bool { windowServer.canSynthesizeClicks }

    func controlWindowIDs(
        displayXRange: ClosedRange<CGFloat>? = nil, displayMenuBarTop: CGFloat = 0
    ) -> (anchor: CGWindowID, divider: CGWindowID)? {
        guard let snapshots = try? windowServer.menuBarItems() else { return nil }
        let controls = snapshots.filter {
            $0.windowID != 0 && $0.frame.height >= 18 && $0.frame.height <= 40
                && abs($0.frame.minY - displayMenuBarTop) <= 40
                && (displayXRange?.contains($0.frame.midX) ?? true)
        }
        let anchors = controls.filter { $0.title == ControlItem.Identifier.anchor.rawValue }
        let dividers = controls.filter { $0.title == ControlItem.Identifier.hiddenDivider.rawValue }
        guard anchors.count == 1, dividers.count == 1 else { return nil }
        return (anchors[0].windowID, dividers[0].windowID)
    }

    /// Hidden items belong entirely left of the divider; Shown items entirely right of the anchor.
    /// Control window IDs, rather than cached edges, keep destinations valid as neighbors move.
    @discardableResult
    func reconcile(
        anchorWindowID: CGWindowID,
        dividerWindowID: CGWindowID,
        controls: ItemControlStore,
        displayXRange: ClosedRange<CGFloat>? = nil,
        displayMenuBarTop: CGFloat = 0
    ) async -> ReconcileResult {
        var result = ReconcileResult()
        defer {
            DebugLog.log("HiddenItemController: reconcile planned=\(result.planned) ok=\(result.succeeded) failed=\(result.failed.count) cancelled=\(result.cancelled) observationFailed=\(result.observationFailed)")
        }
        guard !Task.isCancelled else {
            result.cancelled = true
            return result
        }

        let excludedIDs = controlItemWindowIDs.union([anchorWindowID, dividerWindowID])
        func observe() throws -> (items: [MenuBarItemSnapshot], anchor: CGRect, divider: CGRect) {
            let raw = try windowServer.menuBarItems()
            // A revealed divider may have zero width, but must still precede the anchor on its row.
            guard anchorWindowID != dividerWindowID,
                  let anchor = raw.first(where: { $0.windowID == anchorWindowID }),
                  let divider = raw.first(where: { $0.windowID == dividerWindowID }),
                  HiddenItemsResolver.isPlausibleMenuBarItem(anchor, displayMenuBarTop: displayMenuBarTop),
                  [anchor.frame, divider.frame].allSatisfy({ frame in
                      frame.minX.isFinite && frame.maxX.isFinite
                          && frame.minY.isFinite && frame.maxY.isFinite
                          && frame.width >= 0 && frame.height > 0
                          && (displayXRange?.contains(frame.midX) ?? true)
                  }),
                  divider.frame.maxX <= anchor.frame.minX,
                  divider.frame.minY < anchor.frame.maxY,
                  anchor.frame.minY < divider.frame.maxY else {
                throw WindowServerError.invalidServerResponse("missing or invalid placement controls")
            }
            let candidates = raw.filter {
                !excludedIDs.contains($0.windowID)
                    && !HiddenItemsResolver.isOwnControlItem($0)
                    && HiddenItemsResolver.isPlausibleMenuBarItem($0, displayMenuBarTop: displayMenuBarTop)
                    && (displayXRange?.contains($0.frame.midX) ?? true)
                    && !ImmovableItems.isImmovableOnRawSnapshot($0)
            }
            return (candidates, anchor.frame, divider.frame)
        }

        do {
            var observation = try observe()
            var snapshots: [MenuBarItemSnapshot] = []
            for attempt in 0..<2 {
                try Task.checkCancellation()
                let candidates = HiddenItemsResolver.deduplicateByMidXProximity(observation.items)
                snapshots = await attribute(candidates)
                guard !Task.isCancelled else {
                    result.cancelled = true
                    return result
                }
                let fresh = try observe()
                // AX ownership is tied to the enumerated positions, not to a later layout.
                let oldFrames = Dictionary(observation.items.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
                let freshFrames = Dictionary(fresh.items.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
                let freshRepresentatives = HiddenItemsResolver.deduplicateByMidXProximity(fresh.items)
                let unchanged = observation.anchor == fresh.anchor && observation.divider == fresh.divider
                    && oldFrames == freshFrames
                    && Set(candidates.map(\.windowID)) == Set(freshRepresentatives.map(\.windowID))
                observation = fresh
                if unchanged { break }
                guard attempt == 0 else {
                    throw WindowServerError.invalidServerResponse("placement geometry changed during both attribution attempts")
                }
                DebugLog.log("HiddenItemController: discarding attribution after placement geometry changed")
            }
            let plan = HiddenLayoutPlanner.moves(
                for: snapshots,
                anchorMinX: observation.anchor.minX,
                anchorMaxX: observation.anchor.maxX,
                dividerMinX: observation.divider.minX,
                controls: controls,
                excludingWindowIDs: excludedIDs,
                immovablePIDs: ImmovableProcessIDs.current(),
                displayXRange: displayXRange,
                displayMenuBarTop: displayMenuBarTop
            )
            result.planned = plan.count
            DebugLog.log("reconcile: \(snapshots.count) items, plan=\(plan.count) moves; anchorMinX=\(observation.anchor.minX) dividerMinX=\(observation.divider.minX) hidden=\(controls.hiddenInMenuBar)")

            // Each candidate gets one sequential attempt; the native implementation owns retries.
            for move in plan {
                guard !Task.isCancelled else {
                    result.cancelled = true
                    break
                }
                let live = try observe()
                guard let raw = live.items.first(where: { $0.windowID == move.item.windowID }) else {
                    result.failed.append(move.item)
                    DebugLog.log("HiddenItemController: candidate disappeared or became unsafe: \(move.item.windowID)")
                    continue
                }
                let item = raw.attributed(bundleID: move.item.ownerBundleID, pid: move.item.ownerPID)
                let hidden = controls.isHidden(item)
                if HiddenLayoutPlanner.isPlacementSatisfied(
                    item: item, hidden: hidden, anchorMaxX: live.anchor.maxX, dividerMinX: live.divider.minX
                ) {
                    DebugLog.log("HiddenItemController: placement already satisfied for \(item.windowID)")
                    continue
                }
                let targetX = hidden
                    ? live.divider.minX - HiddenLayoutPlanner.hiddenMargin
                    : live.anchor.maxX + HiddenLayoutPlanner.shownMargin
                do {
                    try Task.checkCancellation()
                    try await windowServer.move(
                        item: item, toX: targetX, relativeTo: hidden ? dividerWindowID : anchorWindowID
                    )
                } catch is CancellationError {
                    result.cancelled = true
                    break
                } catch {
                    DebugLog.log("HiddenItemController: move failed for \(item.windowID) (\(item.ownerBundleID ?? "?")) pid=\(item.ownerPID): \(error)")
                    result.failed.append(item)
                    continue
                }
                let verified = try observe()
                if let placed = verified.items.first(where: { $0.windowID == item.windowID }),
                   HiddenLayoutPlanner.isPlacementSatisfied(
                       item: placed, hidden: hidden,
                       anchorMaxX: verified.anchor.maxX, dividerMinX: verified.divider.minX
                   ) {
                    result.succeeded += 1
                    DebugLog.log("HiddenItemController: placement verified for \(item.windowID) (\(item.ownerBundleID ?? "?")) pid=\(item.ownerPID) -> x=\(targetX)")
                } else {
                    result.failed.append(item)
                    DebugLog.log("HiddenItemController: move returned without satisfying placement for \(item.windowID)")
                }
            }
        } catch is CancellationError {
            result.cancelled = true
        } catch {
            result.observationFailed = true
            DebugLog.log("HiddenItemController: observation failed: \(error)")
        }
        result.cancelled = result.cancelled || Task.isCancelled
        return result
    }
}

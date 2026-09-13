import BarKeepersFriendCore
import CoreGraphics
import Foundation

/// Swaps shown items to the far left of a revealed hidden section so the notch clips them instead, and
/// puts them back before the section collapses. A native return value alone never counts as placement.
@MainActor
final class NotchOverflowCoordinator {
    typealias Observe = () throws -> [MenuBarItemSnapshot]
    typealias Move = (MenuBarItemSnapshot, CGFloat, CGWindowID) async throws -> Void
    typealias Attribute = ([MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot]

    /// Live window ids of the placement controls; a nil tier id means the hidden section has no
    /// left boundary other than the display edge (tier absent, or revealed together with the section).
    struct Controls: Equatable, Sendable {
        var anchor: CGWindowID
        var divider: CGWindowID
        var alwaysHidden: CGWindowID?

        init(anchor: CGWindowID, divider: CGWindowID, alwaysHidden: CGWindowID? = nil) {
            self.anchor = anchor
            self.divider = divider
            self.alwaysHidden = alwaysHidden
        }
    }

    struct MakeRoomResult: Equatable, Sendable {
        enum Skip: Equatable, Sendable {
            case modeNever
            case noNotch
            case controlsUnavailable
            case dividerNotRevealed
            case observationFailed
        }

        /// Why the pass could not start or continue; a read that fails after some tucks also lands here.
        var skipped: Skip?
        /// Width the hidden section lacked right of the notch before any move; 0 means nothing was clipped.
        var requiredWidth: CGFloat = 0
        var planned: [CGWindowID] = []
        var tucked: [MenuBarItemSnapshot] = []
        var failed: [MenuBarItemSnapshot] = []
        /// Measured after the moves when possible, otherwise the plan's arithmetic remainder.
        var remainingDeficit: CGFloat = 0
        var cancelled = false

        var needed: Bool { requiredWidth > 0 }
        var allSucceeded: Bool { skipped == nil && failed.isEmpty && !cancelled }
    }

    struct RestoreResult: Equatable, Sendable {
        var restored: [MenuBarItemSnapshot] = []
        var failed: [MenuBarItemSnapshot] = []
        var cancelled = false
        var observationFailed = false
        /// Victims still recorded after this pass; a later `restore()` retries them.
        var remaining = 0

        var allRestored: Bool { failed.isEmpty && !cancelled && !observationFailed && remaining == 0 }
    }

    /// A victim whose move was submitted; kept until a fresh read shows it right of the anchor again.
    struct TuckedItem: Equatable, Sendable {
        var item: MenuBarItemSnapshot
        /// Original distance from the anchor across every make-room pass (0 nearest).
        var rank: Int
        /// The window it abutted on the right side of the anchor, so restore can put it back in place.
        var neighborWindowID: CGWindowID
    }

    private(set) var tucked: [TuckedItem] = []
    var hasTuckedItems: Bool { !tucked.isEmpty }
    /// Mode snapshot for callers that run make-room off a detached task.
    var currentMode: NotchOverflowMode = .never

    private let observe: Observe
    private let move: Move
    private let controls: () -> Controls?
    private let notch: () -> NotchGeometry?
    private let displayMenuBarTop: () -> CGFloat
    private let excludedWindowIDs: () -> Set<CGWindowID>
    private let immovable: (MenuBarItemSnapshot) -> Bool
    /// Tahoe's raw owner pid is unreliable; the relay needs AX-attributed ownership to reach an item.
    private let attribute: Attribute

    /// Serializes make-room and restore so a restore never interleaves with a tuck still in flight.
    private var chain: Task<Void, Never> = Task {}

    init(
        observe: @escaping Observe,
        move: @escaping Move,
        controls: @escaping () -> Controls?,
        notch: @escaping () -> NotchGeometry?,
        displayMenuBarTop: @escaping () -> CGFloat = { 0 },
        excludedWindowIDs: @escaping () -> Set<CGWindowID> = { [] },
        immovable: @escaping (MenuBarItemSnapshot) -> Bool,
        attribute: @escaping Attribute = { $0 }
    ) {
        self.observe = observe
        self.move = move
        self.controls = controls
        self.notch = notch
        self.displayMenuBarTop = displayMenuBarTop
        self.excludedWindowIDs = excludedWindowIDs
        self.immovable = immovable
        self.attribute = attribute
    }

    // MARK: - Public operations

    /// Call once the hidden divider has settled at its natural width. Never observes or moves in
    /// `.never`; otherwise tucks the planned victims one at a time, stopping between moves on cancellation.
    func makeRoomIfNeeded(mode: NotchOverflowMode) async -> MakeRoomResult {
        guard mode == .whenNeeded else { return MakeRoomResult(skipped: .modeNever) }
        return await serialized { await self.makeRoom() }
    }

    /// Moves every recorded victim back right of the anchor in its original order. A no-op without a
    /// record; independent of the mode so turning the setting off can never strand a victim.
    @discardableResult
    func restore() async -> RestoreResult {
        guard hasTuckedItems else { return RestoreResult() }
        return await serialized { await self.restoreTucked() }
    }

    // MARK: - Serialization

    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = chain
        let task = Task { @MainActor in
            await previous.value
            return await body()
        }
        chain = Task { _ = await task.value }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Observation

    private enum ObservationError: Error {
        case controlsUnavailable
        case dividerNotRevealed
        case geometryChanged
    }

    private struct Observation {
        var raw: [MenuBarItemSnapshot]
        var layout: NotchOverflowPlanner.RevealedLayout
        /// The section without victims already tucked: they are clipped by design and must not
        /// count as a deficit, or every pass would tuck the next shown item.
        var pendingHidden: [MenuBarItemSnapshot]
    }

    private var tuckedWindowIDs: Set<CGWindowID> { Set(tucked.map(\.item.windowID)) }

    private static func isFinite(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.maxX.isFinite && frame.minY.isFinite && frame.maxY.isFinite
            && frame.width >= 0 && frame.height > 0
    }

    private func observeLayout(controls windows: Controls, notch: NotchGeometry) throws -> Observation {
        let raw = try observe()
        let top = displayMenuBarTop()
        guard windows.anchor != windows.divider,
              let anchor = raw.first(where: { $0.windowID == windows.anchor }),
              let divider = raw.first(where: { $0.windowID == windows.divider }),
              Self.isFinite(anchor.frame), Self.isFinite(divider.frame),
              HiddenItemsResolver.isPlausibleMenuBarItem(anchor, displayMenuBarTop: top),
              divider.frame.maxX <= anchor.frame.minX,
              divider.frame.minY < anchor.frame.maxY, anchor.frame.minY < divider.frame.maxY else {
            throw ObservationError.controlsUnavailable
        }
        guard NotchOverflowPlanner.isDividerRevealed(divider.frame, displayFrame: notch.displayFrame) else {
            throw ObservationError.dividerNotRevealed
        }
        var excluded = excludedWindowIDs().union([windows.anchor, windows.divider])
        var alwaysHidden: CGRect?
        if let tierID = windows.alwaysHidden {
            guard tierID != windows.anchor, tierID != windows.divider,
                  let tier = raw.first(where: { $0.windowID == tierID }),
                  Self.isFinite(tier.frame), tier.frame.maxX <= divider.frame.minX else {
                throw ObservationError.controlsUnavailable
            }
            alwaysHidden = tier.frame
            excluded.insert(tierID)
        }
        let layout = NotchOverflowPlanner.classify(
            items: raw, anchor: anchor.frame, divider: divider.frame, alwaysHiddenDivider: alwaysHidden,
            notch: notch, displayMenuBarTop: top, excludingWindowIDs: excluded
        )
        let tuckedIDs = tuckedWindowIDs
        return Observation(
            raw: raw, layout: layout,
            pendingHidden: layout.hidden.filter { !tuckedIDs.contains($0.windowID) }
        )
    }

    /// AX ownership is tied to the enumerated positions, so a layout that shifted underneath one
    /// attribution attempt discards it; a second shift gives up rather than trusting either read.
    private func attributedShown(
        from initial: Observation, controls windows: Controls, notch: NotchGeometry
    ) async throws -> (observation: Observation, shown: [MenuBarItemSnapshot]) {
        var observation = initial
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let attributed = await attribute(observation.layout.shown)
            try Task.checkCancellation()
            let fresh = try observeLayout(controls: windows, notch: notch)
            let unchanged = Self.sameGeometry(fresh.layout, observation.layout)
            observation = fresh
            if unchanged { return (fresh, attributed) }
            guard attempt == 0 else { throw ObservationError.geometryChanged }
            DebugLog.log("NotchOverflowCoordinator: discarding attribution after the layout changed")
        }
        throw ObservationError.geometryChanged
    }

    private static func sameGeometry(
        _ lhs: NotchOverflowPlanner.RevealedLayout, _ rhs: NotchOverflowPlanner.RevealedLayout
    ) -> Bool {
        func frames(_ items: [MenuBarItemSnapshot]) -> [CGWindowID: CGRect] {
            Dictionary(items.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        }
        return lhs.anchor == rhs.anchor && lhs.divider == rhs.divider
            && lhs.alwaysHiddenDivider == rhs.alwaysHiddenDivider
            && frames(lhs.hidden) == frames(rhs.hidden) && frames(lhs.shown) == frames(rhs.shown)
    }

    // MARK: - Make room

    private func makeRoom() async -> MakeRoomResult {
        var result = MakeRoomResult()
        defer {
            DebugLog.log("NotchOverflowCoordinator: makeRoom skipped=\(result.skipped.map { "\($0)" } ?? "none") required=\(result.requiredWidth) planned=\(result.planned.count) tucked=\(result.tucked.count) failed=\(result.failed.count) remaining=\(result.remainingDeficit) cancelled=\(result.cancelled)")
        }
        guard !Task.isCancelled else {
            result.cancelled = true
            return result
        }
        guard let notch = notch(), notch.hasNotch else {
            result.skipped = .noNotch
            return result
        }
        guard let windows = controls() else {
            result.skipped = .controlsUnavailable
            return result
        }
        do {
            let initial = try observeLayout(controls: windows, notch: notch)
            result.requiredWidth = NotchOverflowPlanner.deficit(hidden: initial.pendingHidden, notch: notch)
            guard result.requiredWidth > 0 else { return result }

            let (observation, shown) = try await attributedShown(from: initial, controls: windows, notch: notch)
            let layout = NotchOverflowPlanner.RevealedLayout(
                hidden: observation.pendingHidden, shown: shown, anchor: observation.layout.anchor,
                divider: observation.layout.divider, alwaysHiddenDivider: observation.layout.alwaysHiddenDivider
            )
            let plan = NotchOverflowPlanner.plan(layout: layout, notch: notch) { [immovable] item in
                HiddenItemsResolver.isOwnControlItem(item) || immovable(item)
            }
            result.planned = plan.victimWindowIDs
            result.remainingDeficit = plan.deficit
            let rankBase = (tucked.map(\.rank).max() ?? -1) + 1
            DebugLog.log("NotchOverflowCoordinator: deficit=\(plan.requiredWidth) victims=\(plan.victimWindowIDs) freed=\(plan.freedWidth) remaining=\(plan.deficit)")

            for victim in plan.tuckSequence {
                guard !Task.isCancelled else {
                    result.cancelled = true
                    break
                }
                let live = try observeLayout(controls: windows, notch: notch)
                guard let raw = live.raw.first(where: { $0.windowID == victim.windowID }) else {
                    result.failed.append(victim)
                    DebugLog.log("NotchOverflowCoordinator: victim disappeared: \(victim.windowID)")
                    continue
                }
                let item = raw.attributed(bundleID: victim.ownerBundleID, pid: victim.ownerPID)
                // Each victim becomes the new leftmost item, so the next one drops beside it.
                guard let reference = live.layout.hidden.first else { break }
                let rank = rankBase + (plan.victims.firstIndex(where: { $0.windowID == victim.windowID }) ?? 0)
                let neighbor = NotchOverflowPlanner.leftNeighbor(
                    of: item, in: live.raw, anchorWindowID: windows.anchor, displayMenuBarTop: displayMenuBarTop()
                )
                // Recorded before the gesture: a move that returns without satisfying the
                // postcondition may still have displaced the item, and restore must reach it.
                tucked.append(TuckedItem(item: item, rank: rank, neighborWindowID: neighbor?.windowID ?? windows.anchor))
                do {
                    try Task.checkCancellation()
                    try await move(item, NotchOverflowPlanner.tuckTargetX(leftOf: reference.frame), reference.windowID)
                } catch is CancellationError {
                    result.cancelled = true
                    break
                } catch {
                    result.failed.append(item)
                    DebugLog.log("NotchOverflowCoordinator: tuck failed for \(item.windowID) (\(item.ownerBundleID ?? "?")) pid=\(item.ownerPID): \(error)")
                    continue
                }
                let verified = try observeLayout(controls: windows, notch: notch)
                if let placed = verified.raw.first(where: { $0.windowID == item.windowID }),
                   let freshReference = verified.raw.first(where: { $0.windowID == reference.windowID }),
                   NotchOverflowPlanner.isTucked(
                       placed, leftOf: freshReference.frame, dividerMinX: verified.layout.divider.minX,
                       alwaysHiddenDividerMaxX: verified.layout.alwaysHiddenDivider?.maxX
                   ) {
                    result.tucked.append(placed.attributed(bundleID: item.ownerBundleID, pid: item.ownerPID))
                } else {
                    result.failed.append(item)
                    DebugLog.log("NotchOverflowCoordinator: tuck returned without placing \(item.windowID) left of \(reference.windowID)")
                }
            }
            if let final = try? observeLayout(controls: windows, notch: notch) {
                result.remainingDeficit = NotchOverflowPlanner.deficit(hidden: final.pendingHidden, notch: notch)
            }
        } catch is CancellationError {
            result.cancelled = true
        } catch ObservationError.dividerNotRevealed {
            result.skipped = .dividerNotRevealed
        } catch ObservationError.controlsUnavailable {
            result.skipped = .controlsUnavailable
        } catch {
            result.skipped = .observationFailed
            DebugLog.log("NotchOverflowCoordinator: observation failed: \(error)")
        }
        result.cancelled = result.cancelled || Task.isCancelled
        return result
    }

    // MARK: - Restore

    private func restoreTucked() async -> RestoreResult {
        var result = await restoreRecordedVictims()
        result.remaining = tucked.count
        DebugLog.log("NotchOverflowCoordinator: restore restored=\(result.restored.count) failed=\(result.failed.count) remaining=\(result.remaining) cancelled=\(result.cancelled) observationFailed=\(result.observationFailed)")
        return result
    }

    private func restoreRecordedVictims() async -> RestoreResult {
        var result = RestoreResult()
        guard !tucked.isEmpty else { return result }
        guard let windows = controls() else {
            result.observationFailed = true
            return result
        }
        // Nearest the anchor first, each beside its original neighbor; a neighbor that is gone or
        // still tucked yields to the last restored victim, then the anchor, to keep the order close.
        var lastRestoredID: CGWindowID?
        do {
            for entry in tucked.sorted(by: { $0.rank < $1.rank }) {
                guard !Task.isCancelled else {
                    result.cancelled = true
                    break
                }
                let raw = try observe()
                guard let anchor = raw.first(where: { $0.windowID == windows.anchor }), Self.isFinite(anchor.frame) else {
                    throw ObservationError.controlsUnavailable
                }
                guard let current = raw.first(where: { $0.windowID == entry.item.windowID }) else {
                    // The owner quit; there is nothing left to put back.
                    tucked.removeAll { $0 == entry }
                    DebugLog.log("NotchOverflowCoordinator: tucked item disappeared: \(entry.item.windowID)")
                    continue
                }
                let reference = Self.restoreReference(
                    for: entry, in: raw, anchor: anchor, lastRestoredID: lastRestoredID
                )
                let item = current.attributed(bundleID: entry.item.ownerBundleID, pid: entry.item.ownerPID)
                if NotchOverflowPlanner.isRestored(item, rightOf: reference.frame.maxX, anchorMaxX: anchor.frame.maxX) {
                    tucked.removeAll { $0 == entry }
                    result.restored.append(item)
                    lastRestoredID = item.windowID
                    continue
                }
                do {
                    try Task.checkCancellation()
                    try await move(item, NotchOverflowPlanner.restoreTargetX(rightOf: reference.frame), reference.windowID)
                } catch is CancellationError {
                    result.cancelled = true
                    break
                } catch {
                    result.failed.append(item)
                    DebugLog.log("NotchOverflowCoordinator: restore failed for \(item.windowID) (\(item.ownerBundleID ?? "?")) pid=\(item.ownerPID): \(error)")
                    continue
                }
                let after = try observe()
                guard let freshAnchor = after.first(where: { $0.windowID == windows.anchor }) else {
                    throw ObservationError.controlsUnavailable
                }
                let freshReference = after.first(where: { $0.windowID == reference.windowID }) ?? freshAnchor
                if let placed = after.first(where: { $0.windowID == item.windowID }),
                   NotchOverflowPlanner.isRestored(placed, rightOf: freshReference.frame.maxX, anchorMaxX: freshAnchor.frame.maxX) {
                    tucked.removeAll { $0 == entry }
                    result.restored.append(placed.attributed(bundleID: item.ownerBundleID, pid: item.ownerPID))
                    lastRestoredID = item.windowID
                } else {
                    result.failed.append(item)
                    DebugLog.log("NotchOverflowCoordinator: restore returned without placing \(item.windowID) right of \(reference.windowID)")
                }
            }
        } catch is CancellationError {
            result.cancelled = true
        } catch {
            result.observationFailed = true
            DebugLog.log("NotchOverflowCoordinator: restore observation failed: \(error)")
        }
        result.cancelled = result.cancelled || Task.isCancelled
        return result
    }

    /// The recorded neighbor only qualifies while it sits in the shown section itself.
    private static func restoreReference(
        for entry: TuckedItem, in raw: [MenuBarItemSnapshot], anchor: MenuBarItemSnapshot, lastRestoredID: CGWindowID?
    ) -> MenuBarItemSnapshot {
        if entry.neighborWindowID == anchor.windowID { return anchor }
        if let neighbor = raw.first(where: { $0.windowID == entry.neighborWindowID }),
           neighbor.frame.minX >= anchor.frame.maxX {
            return neighbor
        }
        if let lastRestoredID, let last = raw.first(where: { $0.windowID == lastRestoredID }),
           last.frame.minX >= anchor.frame.maxX {
            return last
        }
        return anchor
    }
}

import BarKeepersFriendCore
import CoreGraphics
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NotchOverflowCoordinatorTests {
    private let anchorID: CGWindowID = 90
    private let dividerID: CGWindowID = 91
    private let tierID: CGWindowID = 92
    private let systemID: CGWindowID = 95
    private let itemWidth: CGFloat = 30
    private let rightEdge: CGFloat = 1512

    /// A 14" MacBook-style display: the usable status area starts at x = 812.
    private let notched = NotchGeometry(
        displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        leftArea: CGRect(x: 0, y: 957, width: 700, height: 25),
        rightArea: CGRect(x: 812, y: 957, width: 700, height: 25)
    )
    private let notchless = NotchGeometry(
        displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), leftArea: nil, rightArea: nil
    )

    private func item(
        _ id: CGWindowID, width: CGFloat = 30, owner: String? = nil, pid: pid_t = 1, title: String? = nil
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id, ownerPID: pid, ownerBundleID: owner ?? "test.app.\(id)", title: title,
            frame: CGRect(x: 0, y: 0, width: width, height: 24)
        )
    }

    /// Left-to-right order with the anchor packed to end at x = 1024: `hidden` items (ids 100... nearest
    /// the divider first), the divider, the anchor, `shown` items (ids 1... nearest the anchor first),
    /// then a Control Center cluster filling the rest of the bar.
    private func bar(
        hidden hiddenCount: Int, shown shownItems: [MenuBarItemSnapshot], alwaysHidden: [MenuBarItemSnapshot] = [],
        tierDividerWidth: CGFloat? = nil, dividerWidth: CGFloat = 8
    ) -> [MenuBarItemSnapshot] {
        let hidden = (0..<hiddenCount).map { item(CGWindowID(100 + $0)) }.reversed()
        let shownWidth = shownItems.map(\.frame.width).reduce(0, +)
        let system = item(systemID, width: rightEdge - 1024 - shownWidth, owner: "Control Center", pid: 500, title: "BentoBox")
        var items: [MenuBarItemSnapshot] = []
        if let tierDividerWidth {
            items += alwaysHidden.reversed()
            items.append(item(tierID, width: tierDividerWidth, title: "BKFAlwaysHidden"))
        }
        items += hidden
        items.append(item(dividerID, width: dividerWidth, title: "BKFHidden"))
        items.append(item(anchorID, width: 24, title: "BKFAnchor"))
        items += shownItems
        items.append(system)
        return items
    }

    private func shown(_ count: Int) -> [MenuBarItemSnapshot] {
        (0..<count).map { item(CGWindowID(1 + $0)) }
    }

    private func makeCoordinator(
        _ menuBar: RepackingMenuBar,
        controls: NotchOverflowCoordinator.Controls? = nil,
        notch: NotchGeometry? = nil,
        immovable: @escaping (MenuBarItemSnapshot) -> Bool = { ImmovableItems.isImmovable($0, immovablePIDs: [500]) },
        attribute: @escaping ([MenuBarItemSnapshot]) async -> [MenuBarItemSnapshot] = { $0 }
    ) -> NotchOverflowCoordinator {
        let controls = controls ?? NotchOverflowCoordinator.Controls(anchor: anchorID, divider: dividerID)
        let notch = notch ?? notched
        return NotchOverflowCoordinator(
            observe: { try menuBar.observe() },
            move: { try await menuBar.move($0, toX: $1, relativeTo: $2) },
            controls: { controls },
            notch: { notch },
            immovable: immovable,
            attribute: attribute
        )
    }

    private func hiddenFrames(_ menuBar: RepackingMenuBar) -> [CGRect] {
        menuBar.items.filter { (100..<200).contains($0.windowID) }.map(\.frame)
    }

    private func orderRightOfAnchor(_ menuBar: RepackingMenuBar) -> [CGWindowID] {
        let anchorMaxX = menuBar.frame(of: anchorID)!.maxX
        return menuBar.items.filter { $0.frame.minX >= anchorMaxX && $0.windowID != systemID }
            .sorted { $0.frame.minX < $1.frame.minX }.map(\.windowID)
    }

    // MARK: - Gates

    @Test func neverModeDoesNotObserveOrMove() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        let result = await coordinator.makeRoomIfNeeded(mode: .never)
        #expect(result == NotchOverflowCoordinator.MakeRoomResult(skipped: .modeNever))
        #expect(!result.needed)
        #expect(!result.allSucceeded)
        #expect(menuBar.readCount == 0)
        #expect(menuBar.moveRequests.isEmpty)
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func notchlessDisplaySkipsWithoutObserving() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar, notch: notchless)
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.skipped == .noNotch)
        #expect(menuBar.readCount == 0)
        #expect(menuBar.moveRequests.isEmpty)
    }

    @Test func missingControlsSkipBeforeAnyMove() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = NotchOverflowCoordinator(
            observe: { try menuBar.observe() },
            move: { try await menuBar.move($0, toX: $1, relativeTo: $2) },
            controls: { nil },
            notch: { [notched] in notched },
            immovable: { _ in false }
        )
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.skipped == .controlsUnavailable)
        #expect(menuBar.moveRequests.isEmpty)
    }

    @Test func enoughRoomObservesButMovesNothing() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 6, shown: shown(5)), rightEdge: rightEdge)
        #expect(hiddenFrames(menuBar).map(\.minX).min() == 812)
        let coordinator = makeCoordinator(menuBar)
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.skipped == nil)
        #expect(!result.needed)
        #expect(result.allSucceeded)
        #expect(result.tucked.isEmpty)
        #expect(menuBar.readCount == 1)
        #expect(menuBar.moveRequests.isEmpty)
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func anExpandedDividerIsNotRevealedAndNothingMoves() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5), dividerWidth: 1712), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.skipped == .dividerNotRevealed)
        #expect(menuBar.readCount == 1)
        #expect(menuBar.moveRequests.isEmpty)
    }

    @Test func enumerationFailureIsReportedNotSwallowed() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        menuBar.enumerationError = .invalidServerResponse("unavailable")
        let coordinator = makeCoordinator(menuBar)
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.skipped == .observationFailed)
        #expect(menuBar.moveRequests.isEmpty)
    }

    // MARK: - Make room and restore

    @Test func tucksNearestShownItemsUntilHiddenItemsClearTheNotchThenRestoresTheOriginalOrder() async throws {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        #expect(hiddenFrames(menuBar).map(\.minX).min() == 722)
        let leftmostHidden = try #require(menuBar.frame(of: 108))
        let coordinator = makeCoordinator(menuBar)

        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)

        #expect(result.skipped == nil)
        #expect(result.requiredWidth == 90)
        #expect(result.planned == [1, 2, 3])
        #expect(result.tucked.map(\.windowID) == [3, 2, 1])
        #expect(result.failed.isEmpty)
        #expect(result.remainingDeficit == 0)
        #expect(result.allSucceeded)
        // Furthest first, each dropped beside the section's current leftmost item.
        #expect(menuBar.moveRequests.map(\.item.windowID) == [3, 2, 1])
        #expect(menuBar.moveRequests.map(\.targetWindowID) == [108, 3, 2])
        #expect(menuBar.moveRequests[0].targetX == leftmostHidden.minX - HiddenLayoutPlanner.hiddenMargin)
        #expect(hiddenFrames(menuBar).allSatisfy { $0.minX >= 812 })
        let hiddenMinX = try #require(hiddenFrames(menuBar).map(\.minX).min())
        for id: CGWindowID in [1, 2, 3] {
            #expect(try #require(menuBar.frame(of: id)).maxX <= hiddenMinX)
        }
        #expect(orderRightOfAnchor(menuBar) == [4, 5])
        #expect(coordinator.tucked.map { $0.item.windowID } == [3, 2, 1])
        #expect(coordinator.tucked.map(\.rank) == [2, 1, 0])
        #expect(coordinator.hasTuckedItems)
        // The whole bar shifted right by the freed width while the victims sit at the far left.
        let anchorWhileTucked = try #require(menuBar.frame(of: anchorID))
        #expect(anchorWhileTucked.maxX == 1114)

        let restored = await coordinator.restore()

        #expect(restored.restored.map(\.windowID) == [1, 2, 3])
        #expect(restored.failed.isEmpty)
        #expect(restored.remaining == 0)
        #expect(restored.allRestored)
        #expect(menuBar.moveRequests.count == 6)
        #expect(menuBar.moveRequests[3...].map(\.item.windowID) == [1, 2, 3])
        #expect(menuBar.moveRequests[3...].map(\.targetWindowID) == [anchorID, 1, 2])
        #expect(menuBar.moveRequests[3].targetX == anchorWhileTucked.maxX + HiddenLayoutPlanner.shownMargin)
        #expect(try #require(menuBar.frame(of: anchorID)).maxX == 1024)
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3, 4, 5])
        #expect(hiddenFrames(menuBar).map(\.minX).min() == 722)
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func restoreWithoutPriorMakeRoomIsANoOp() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        let result = await coordinator.restore()
        #expect(result == NotchOverflowCoordinator.RestoreResult())
        #expect(result.allRestored)
        #expect(menuBar.readCount == 0)
        #expect(menuBar.moveRequests.isEmpty)
    }

    @Test func secondPassFindsNoDeficitAndLeavesTheRecordAlone() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        _ = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        let recorded = coordinator.tucked
        let again = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(again.skipped == nil)
        #expect(!again.needed)
        #expect(again.tucked.isEmpty)
        #expect(menuBar.moveRequests.count == 3)
        #expect(coordinator.tucked == recorded)
        let restored = await coordinator.restore()
        #expect(restored.allRestored)
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3, 4, 5])
    }

    @Test func immovableAndOwnItemsAreSkippedInFavorOfTheNextMovableNeighbor() async {
        let controlCenter = item(1, owner: "Control Center", pid: 500)
        let group = item(2, title: "BKFGroup-1234")
        let items = bar(hidden: 7, shown: [controlCenter, group, item(3), item(4)])
        let menuBar = RepackingMenuBar(items: items, rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.requiredWidth == 30)
        #expect(result.planned == [3])
        #expect(result.tucked.map(\.windowID) == [3])
        #expect(result.remainingDeficit == 0)
        #expect(menuBar.moveRequests.map(\.item.windowID) == [3])
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 4])
        let restored = await coordinator.restore()
        #expect(restored.allRestored)
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3, 4])
    }

    @Test func nothingMovableReportsTheOutstandingDeficitWithoutMoving() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(3)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar, immovable: { _ in true })
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.skipped == nil)
        #expect(result.requiredWidth == 90)
        #expect(result.planned.isEmpty)
        #expect(result.remainingDeficit == 90)
        #expect(result.allSucceeded)
        #expect(menuBar.moveRequests.isEmpty)
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func tooLittleMovableWidthTucksEverythingMovableAndMeasuresTheRemainder() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 10, shown: shown(2)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.requiredWidth == 120)
        #expect(result.planned == [1, 2])
        #expect(result.tucked.map(\.windowID) == [2, 1])
        #expect(result.remainingDeficit == 60)
        #expect(hiddenFrames(menuBar).map(\.minX).min() == 752)
        #expect(result.allSucceeded)
    }

    @Test func alwaysHiddenTierBoundsTheSectionAndVictimsLandRightOfItsDivider() async throws {
        let items = bar(hidden: 7, shown: shown(3), alwaysHidden: [item(300), item(301)], tierDividerWidth: 1712)
        let menuBar = RepackingMenuBar(items: items, rightEdge: rightEdge)
        let tierBefore = try #require(menuBar.frame(of: tierID))
        #expect(tierBefore.maxX == 782)
        #expect(tierBefore.minX < 0)
        let controls = NotchOverflowCoordinator.Controls(anchor: anchorID, divider: dividerID, alwaysHidden: tierID)
        let coordinator = makeCoordinator(menuBar, controls: controls)

        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)

        // Only the seven hidden items count, not the off-screen always-hidden pair behind the tier divider.
        #expect(result.requiredWidth == 30)
        #expect(result.tucked.map(\.windowID) == [1])
        #expect(result.allSucceeded)
        let victim = try #require(menuBar.frame(of: 1))
        let tierAfter = try #require(menuBar.frame(of: tierID))
        #expect(victim.minX >= tierAfter.maxX)
        #expect(victim.maxX <= 812)
        #expect(hiddenFrames(menuBar).allSatisfy { $0.minX >= 812 })
        #expect(menuBar.moveRequests.map(\.targetWindowID) == [106])

        let restored = await coordinator.restore()
        #expect(restored.allRestored)
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3])
        #expect(try #require(menuBar.frame(of: tierID)).maxX == 782)
    }

    // MARK: - Failures

    @Test func aFailedVictimMoveIsReportedAndTheOthersStillMove() async throws {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        menuBar.onMove = { [unowned menuBar] item, targetX, targetWindowID in
            if item.windowID == 2 { throw WindowServerError.moveFailed(windowID: 2) }
            try menuBar.applyMove(item, toX: targetX, relativeTo: targetWindowID)
        }
        let coordinator = makeCoordinator(menuBar)

        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)

        #expect(result.planned == [1, 2, 3])
        #expect(result.tucked.map(\.windowID) == [3, 1])
        #expect(result.failed.map(\.windowID) == [2])
        #expect(!result.allSucceeded)
        // Two victims freed 60 of the 90 needed; the shortfall is measured, not assumed.
        #expect(result.remainingDeficit == 30)
        #expect(hiddenFrames(menuBar).map(\.minX).min() == 782)
        #expect(orderRightOfAnchor(menuBar) == [2, 4, 5])
        // The failed victim stays recorded: a move can displace an item even when it throws.
        #expect(coordinator.tucked.map { $0.item.windowID } == [3, 2, 1])

        let restored = await coordinator.restore()
        #expect(restored.allRestored)
        #expect(restored.restored.map(\.windowID) == [1, 2, 3])
        // Item 2 never left, so it needs no gesture; the others return beside it in order.
        #expect(menuBar.moveRequests[3...].map(\.item.windowID) == [1, 3])
        #expect(menuBar.moveRequests[3...].map(\.targetWindowID) == [anchorID, 2])
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3, 4, 5])
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func aMoveThatReturnsWithoutPlacingTheVictimIsAFailure() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 7, shown: shown(3)), rightEdge: rightEdge)
        menuBar.onMove = { _, _, _ in }
        let coordinator = makeCoordinator(menuBar)
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(result.planned == [1])
        #expect(result.tucked.isEmpty)
        #expect(result.failed.map(\.windowID) == [1])
        #expect(result.remainingDeficit == 30)
        #expect(!result.allSucceeded)
        #expect(coordinator.tucked.map { $0.item.windowID } == [1])
        let restored = await coordinator.restore()
        #expect(restored.allRestored)
        #expect(restored.restored.map(\.windowID) == [1])
        #expect(menuBar.moveRequests.count == 1)
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func restoreKeepsAFailedVictimForTheNextAttempt() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        _ = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        menuBar.onMove = { [unowned menuBar] item, targetX, targetWindowID in
            if item.windowID == 2 { throw WindowServerError.moveFailed(windowID: 2) }
            try menuBar.applyMove(item, toX: targetX, relativeTo: targetWindowID)
        }

        let first = await coordinator.restore()
        #expect(first.restored.map(\.windowID) == [1, 3])
        #expect(first.failed.map(\.windowID) == [2])
        #expect(first.remaining == 1)
        #expect(!first.allRestored)
        // Item 3 returns beside the last restored victim, so the order is right without item 2.
        #expect(orderRightOfAnchor(menuBar) == [1, 3, 4, 5])
        #expect(coordinator.tucked.map { $0.item.windowID } == [2])

        menuBar.onMove = nil
        let second = await coordinator.restore()
        #expect(second.restored.map(\.windowID) == [2])
        #expect(second.allRestored)
        // Its original neighbor is back in the shown section, so item 2 returns to its exact slot.
        #expect(menuBar.moveRequests.last?.targetWindowID == 1)
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3, 4, 5])
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func restoreDropsAVictimWhoseOwnerQuit() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        _ = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        menuBar.remove(2)
        let restored = await coordinator.restore()
        #expect(restored.restored.map(\.windowID) == [1, 3])
        #expect(restored.failed.isEmpty)
        #expect(restored.allRestored)
        #expect(orderRightOfAnchor(menuBar) == [1, 3, 4, 5])
        #expect(!coordinator.hasTuckedItems)
    }

    @Test func restoreObservationFailureRetainsTheRecord() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        _ = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        menuBar.enumerationError = .invalidServerResponse("unavailable")
        let result = await coordinator.restore()
        #expect(result.observationFailed)
        #expect(result.remaining == 3)
        #expect(!result.allRestored)
        #expect(coordinator.tucked.count == 3)
        #expect(menuBar.moveRequests.count == 3)
    }

    // MARK: - Cancellation and serialization

    @Test func cancellationBetweenMovesStopsBeforeTheNextVictim() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let started = AsyncGate()
        let finish = AsyncGate()
        menuBar.onMove = { [unowned menuBar] item, targetX, targetWindowID in
            try menuBar.applyMove(item, toX: targetX, relativeTo: targetWindowID)
            await started.open()
            await finish.wait()
        }
        let coordinator = makeCoordinator(menuBar)
        let task = Task { await coordinator.makeRoomIfNeeded(mode: .whenNeeded) }
        await started.wait()
        task.cancel()
        await finish.open()
        let result = await task.value

        // The submitted move completed and was verified; no second gesture started.
        #expect(result.cancelled)
        #expect(!result.allSucceeded)
        #expect(result.tucked.map(\.windowID) == [3])
        #expect(result.failed.isEmpty)
        #expect(menuBar.moveRequests.count == 1)
        #expect(coordinator.tucked.map { $0.item.windowID } == [3])

        menuBar.onMove = nil
        let restored = await coordinator.restore()
        #expect(restored.allRestored)
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3, 4, 5])
    }

    @Test func cancellationDuringRestoreLeavesTheRestForALaterPass() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let coordinator = makeCoordinator(menuBar)
        _ = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        let started = AsyncGate()
        let finish = AsyncGate()
        menuBar.onMove = { [unowned menuBar] item, targetX, targetWindowID in
            try menuBar.applyMove(item, toX: targetX, relativeTo: targetWindowID)
            await started.open()
            await finish.wait()
        }
        let task = Task { await coordinator.restore() }
        await started.wait()
        task.cancel()
        await finish.open()
        let result = await task.value
        #expect(result.cancelled)
        #expect(result.restored.map(\.windowID) == [1])
        #expect(result.remaining == 2)
        #expect(coordinator.tucked.map { $0.item.windowID } == [3, 2])

        menuBar.onMove = nil
        let again = await coordinator.restore()
        #expect(again.allRestored)
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3, 4, 5])
    }

    @Test func restoreWaitsForAnInFlightMakeRoomInsteadOfInterleaving() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        let started = AsyncGate()
        let finish = AsyncGate()
        menuBar.onMove = { [unowned menuBar] item, targetX, targetWindowID in
            try menuBar.applyMove(item, toX: targetX, relativeTo: targetWindowID)
            if item.windowID == 3 {
                await started.open()
                await finish.wait()
            }
        }
        let coordinator = makeCoordinator(menuBar)
        let makeRoom = Task { await coordinator.makeRoomIfNeeded(mode: .whenNeeded) }
        await started.wait()
        let restore = Task { await coordinator.restore() }
        await Task.yield()
        #expect(menuBar.moveRequests.count == 1)
        await finish.open()
        let roomResult = await makeRoom.value
        let restoreResult = await restore.value

        #expect(roomResult.allSucceeded)
        #expect(roomResult.tucked.map(\.windowID) == [3, 2, 1])
        #expect(restoreResult.allRestored)
        #expect(menuBar.moveRequests.map(\.item.windowID) == [3, 2, 1, 1, 2, 3])
        #expect(orderRightOfAnchor(menuBar) == [1, 2, 3, 4, 5])
        #expect(!coordinator.hasTuckedItems)
    }

    // MARK: - Attribution

    @Test func attributedOwnershipDrivesBothImmovabilityAndTheRelayTarget() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 7, shown: shown(3)), rightEdge: rightEdge)
        var attributedBatches: [[CGWindowID]] = []
        let coordinator = makeCoordinator(
            menuBar,
            immovable: { ImmovableItems.isImmovable($0, immovablePIDs: [500]) },
            attribute: { snapshots in
                attributedBatches.append(snapshots.map(\.windowID))
                return snapshots.map { snapshot in
                    snapshot.windowID == 1
                        ? snapshot.attributed(bundleID: "Control Center", pid: 500)
                        : snapshot.attributed(bundleID: "Real App \(snapshot.windowID)", pid: 4000 + pid_t(snapshot.windowID))
                }
            }
        )
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        // Every shown candidate is attributed, including the system cluster; attribution then reveals
        // the nearest item as a Control Center module that raw ownership could not identify.
        #expect(attributedBatches == [[1, 2, 3, 95]])
        #expect(result.planned == [2])
        #expect(menuBar.moveRequests.map(\.item.windowID) == [2])
        #expect(menuBar.moveRequests.first?.item.ownerPID == 4002)
        #expect(menuBar.moveRequests.first?.item.ownerBundleID == "Real App 2")
        #expect(coordinator.tucked.first?.item.ownerPID == 4002)
        let restored = await coordinator.restore()
        #expect(restored.allRestored)
        #expect(menuBar.moveRequests.last?.item.ownerPID == 4002)
    }

    @Test func aLayoutShiftDuringAttributionDiscardsThatAttempt() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 7, shown: shown(3)), rightEdge: rightEdge)
        var calls = 0
        let coordinator = makeCoordinator(menuBar, attribute: { [unowned menuBar] snapshots in
            calls += 1
            // A hidden item quits mid-sweep: the deficit and every position change underneath us.
            if calls == 1 { menuBar.remove(106) }
            return snapshots
        })
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(calls == 2)
        #expect(result.skipped == nil)
        #expect(result.requiredWidth == 30)
        // After the shift only six hidden items remain, ending exactly at the notch edge.
        #expect(result.planned.isEmpty)
        #expect(result.remainingDeficit == 0)
        #expect(menuBar.moveRequests.isEmpty)
    }

    @Test func twoLayoutShiftsDuringAttributionGiveUp() async {
        let menuBar = RepackingMenuBar(items: bar(hidden: 9, shown: shown(5)), rightEdge: rightEdge)
        var calls = 0
        let coordinator = makeCoordinator(menuBar, attribute: { [unowned menuBar] snapshots in
            calls += 1
            menuBar.remove(CGWindowID(106 + calls))
            return snapshots
        })
        let result = await coordinator.makeRoomIfNeeded(mode: .whenNeeded)
        #expect(calls == 2)
        #expect(result.skipped == .observationFailed)
        #expect(menuBar.moveRequests.isEmpty)
        #expect(!coordinator.hasTuckedItems)
    }
}

/// Models the menu bar's right-to-left packing on top of `FakeWindowServer`: a drop beside a reference
/// window makes the item that window's immediate neighbor, and every item is then re-laid out
/// contiguously from the right edge, so freed width really shifts the hidden items right.
@MainActor
private final class RepackingMenuBar {
    private(set) var base: FakeWindowServer
    private(set) var readCount = 0
    private(set) var moveRequests: [(item: MenuBarItemSnapshot, targetX: CGFloat, targetWindowID: CGWindowID)] = []
    var onMove: ((MenuBarItemSnapshot, CGFloat, CGWindowID) async throws -> Void)?
    var enumerationError: WindowServerError? {
        get { base.enumerationError }
        set { base.enumerationError = newValue }
    }
    private let rightEdge: CGFloat

    /// `items` in left-to-right order; frames are assigned by packing.
    init(items: [MenuBarItemSnapshot], rightEdge: CGFloat) {
        self.rightEdge = rightEdge
        base = FakeWindowServer(items: Self.packed(items, rightEdge: rightEdge))
    }

    var items: [MenuBarItemSnapshot] { base.items }

    func frame(of id: CGWindowID) -> CGRect? {
        items.first { $0.windowID == id }?.frame
    }

    func observe() throws -> [MenuBarItemSnapshot] {
        readCount += 1
        return try base.menuBarItems()
    }

    func move(_ item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        moveRequests.append((item, targetX, targetWindowID))
        if let onMove {
            try await onMove(item, targetX, targetWindowID)
        } else {
            try applyMove(item, toX: targetX, relativeTo: targetWindowID)
        }
    }

    /// The server's drop semantics: left or right of the reference by drop side, then repack.
    func applyMove(_ item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) throws {
        var order = items.sorted { $0.frame.minX < $1.frame.minX }
        guard let moving = order.first(where: { $0.windowID == item.windowID }),
              let reference = order.first(where: { $0.windowID == targetWindowID }),
              moving.windowID != reference.windowID else {
            throw WindowServerError.moveFailed(windowID: item.windowID)
        }
        order.removeAll { $0.windowID == moving.windowID }
        let referenceIndex = order.firstIndex { $0.windowID == targetWindowID }!
        order.insert(moving, at: targetX < reference.frame.midX ? referenceIndex : referenceIndex + 1)
        base = FakeWindowServer(items: Self.packed(order, rightEdge: rightEdge))
        base.enumerationError = enumerationError
    }

    func remove(_ id: CGWindowID) {
        let error = enumerationError
        base = FakeWindowServer(items: Self.packed(items.filter { $0.windowID != id }.sorted { $0.frame.minX < $1.frame.minX }, rightEdge: rightEdge))
        base.enumerationError = error
    }

    private static func packed(_ ordered: [MenuBarItemSnapshot], rightEdge: CGFloat) -> [MenuBarItemSnapshot] {
        var cursor = rightEdge
        var result: [MenuBarItemSnapshot] = []
        for item in ordered.reversed() {
            let frame = CGRect(x: cursor - item.frame.width, y: item.frame.minY, width: item.frame.width, height: item.frame.height)
            result.append(MenuBarItemSnapshot(
                windowID: item.windowID, ownerPID: item.ownerPID, ownerBundleID: item.ownerBundleID,
                title: item.title, frame: frame
            ))
            cursor -= item.frame.width
        }
        return result.reversed()
    }
}

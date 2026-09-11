import BarKeepersFriendCore
import CoreGraphics
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HiddenItemControllerTests {
    private let anchorWindowID: CGWindowID = 90
    private let dividerWindowID: CGWindowID = 91

    private func item(
        _ id: CGWindowID, x: CGFloat, y: CGFloat = 0, width: CGFloat = 22, height: CGFloat = 22,
        owner: String? = nil, pid: pid_t = 1, title: String? = nil
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id, ownerPID: pid, ownerBundleID: owner ?? "test.app.\(id)", title: title,
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }
    private var items: [MenuBarItemSnapshot] {
        [item(1, x: 1130), item(2, x: 1160)]
    }
    private var controlItems: [MenuBarItemSnapshot] {
        [
            item(anchorWindowID, x: 1000, width: 24, title: "BKFAnchor"),
            item(dividerWindowID, x: 976, width: 8, title: "BKFHidden"),
        ]
    }
    private var controls: ItemControlStore {
        ItemControlStore(hiddenInMenuBar: Set(items.compactMap(\.ownerBundleID)))
    }

    @Test func cancellingBeforeStartSkipsAttributionAndMoves() async {
        let server = FakeWindowServer(items: items + controlItems)
        var attributed = false
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributed = true
            return snapshots
        }
        let task = Task {
            await controller.reconcile(anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls)
        }
        task.cancel()
        let result = await task.value

        #expect(!attributed)
        #expect(server.moveRequests.isEmpty)
        #expect(result.cancelled)
        #expect(!result.allSucceeded)
        #expect(result.failed.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellingDuringAMoveStopsBeforeTheNextItem(cooperativeMove: Bool) async {
        let server = ScriptedWindowServer(items: items + controlItems)
        let started = AsyncGate()
        let finish = AsyncGate()
        server.onMove = { [unowned server] item, targetX, targetWindowID in
            try await server.base.move(item: item, toX: targetX, relativeTo: targetWindowID)
            await started.open()
            await finish.wait()
            if cooperativeMove { try Task.checkCancellation() }
        }
        let controller = HiddenItemController(windowServer: server)
        let task = Task {
            await controller.reconcile(anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls)
        }
        await started.wait()
        task.cancel()
        await finish.open()
        let result = await task.value

        #expect(server.moveRequests.count == 1)
        #expect(result.planned == 2)
        #expect(result.succeeded == (cooperativeMove ? 0 : 1))
        #expect(result.cancelled)
        #expect(!result.allSucceeded)
        #expect(result.failed.isEmpty)
        #expect(!result.observationFailed)
    }

    @Test(arguments: [false, true])
    func uncancelledReconcileStillAttemptsEveryPlannedMove(failMoves: Bool) async {
        let server = FakeWindowServer(items: items + controlItems)
        if failMoves { server.moveError = .moveFailed(windowID: 1) }
        let controller = HiddenItemController(windowServer: server)
        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(result.planned == 2)
        #expect(result.succeeded == (failMoves ? 0 : 2))
        #expect(result.failed.count == (failMoves ? 2 : 0))
        #expect(result.allSucceeded == !failMoves)
        #expect(!result.cancelled)
        #expect(!result.observationFailed)
    }

    @Test func shownOnlyIntentRestoresAnItemWithoutHiddenIntent() async throws {
        let server = FakeWindowServer(items: [item(1, x: 800)] + controlItems)
        let controller = HiddenItemController(windowServer: server)
        let controls = ItemControlStore(shownInMenuBar: ["test.app.1"])

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(controls.hiddenInMenuBar.isEmpty)
        #expect(result.planned == 1)
        #expect(result.succeeded == 1)
        #expect(result.allSucceeded)
        #expect(server.moveRequests.first?.targetX == 1032)
        #expect(server.moveRequests.first?.targetWindowID == anchorWindowID)
        let placed = try #require(server.items.first(where: { $0.windowID == 1 }))
        #expect(placed.frame.minX >= 1024)

        let repeated = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )
        #expect(repeated.planned == 0)
        #expect(repeated.allSucceeded)
        #expect(server.moveRequests.count == 1)
    }

    @Test func nativeControlDiscoveryUsesExactNamesAndRejectsAmbiguity() {
        let server = ScriptedWindowServer(items: items + controlItems)
        let controller = HiddenItemController(windowServer: server)
        let discovered = controller.controlWindowIDs(displayXRange: 0...1500)
        #expect(discovered?.anchor == anchorWindowID)
        #expect(discovered?.divider == dividerWindowID)
        server.base = FakeWindowServer(items: items + controlItems + [item(99, x: 1100, title: "BKFAnchor")])
        #expect(controller.controlWindowIDs(displayXRange: 0...1500) == nil)
        server.base.enumerationError = .invalidServerResponse("unavailable")
        #expect(controller.controlWindowIDs() == nil)
    }

    @Test func enumerationOrderChangesDoNotInvalidateUnchangedGeometry() async {
        let server = ScriptedWindowServer(items: items + controlItems)
        server.beforeRead = { [unowned server] _ in
            let snapshots = try server.base.menuBarItems()
            server.base = FakeWindowServer(items: Array(snapshots.reversed()))
        }
        let controller = HiddenItemController(windowServer: server)
        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )
        #expect(result.allSucceeded)
        #expect(result.succeeded == 2)
        #expect(!result.observationFailed)
        #expect(server.moveRequests.count == 2)
    }

    @Test func mixedDirectionsRefreshControlEdgesAndKeepTrustedOwnership() async throws {
        let initial = [item(1, x: 1130), item(2, x: 900), item(3, x: 1190)] + controlItems
        let afterFirst = [
            item(1, x: 980), item(2, x: 940), item(3, x: 1250),
            item(anchorWindowID, x: 1080, width: 24, title: "BKFAnchor"),
            item(dividerWindowID, x: 1056, width: 8, title: "BKFHidden"),
        ].map { $0.attributed(bundleID: "Control Center", pid: -1) }
        let afterSecond = [
            item(1, x: 970), item(2, x: 1100), item(3, x: 1180),
            item(anchorWindowID, x: 1040, width: 24, title: "BKFAnchor"),
            item(dividerWindowID, x: 1016, width: 8, title: "BKFHidden"),
        ].map { $0.attributed(bundleID: "Control Center", pid: -1) }
        let server = ScriptedWindowServer(items: initial.map { $0.attributed(bundleID: "Control Center", pid: -1) })
        server.onMove = { [unowned server] item, targetX, targetWindowID in
            try await server.base.move(item: item, toX: targetX, relativeTo: targetWindowID)
            if server.moveRequests.count == 1 { server.base = FakeWindowServer(items: afterFirst) }
            if server.moveRequests.count == 2 { server.base = FakeWindowServer(items: afterSecond) }
        }
        var attributionCalls = 0
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributionCalls += 1
            return snapshots.map { $0.attributed(bundleID: "test.app.\($0.windowID)", pid: 1) }
        }
        let controls = ItemControlStore(hiddenInMenuBar: ["test.app.1", "test.app.3"], shownInMenuBar: ["test.app.2"])

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(attributionCalls == 1)
        #expect(result.planned == 3)
        #expect(result.succeeded == 3)
        #expect(result.allSucceeded)
        #expect(server.moveRequests.map { $0.item.windowID } == [1, 2, 3])
        #expect(server.moveRequests.map(\.targetX) == [968, 1112, 1008])
        #expect(server.moveRequests.map(\.targetWindowID) == [dividerWindowID, anchorWindowID, dividerWindowID])
        #expect(server.moveRequests.map { $0.item.frame.minX } == [1130, 940, 1180])
        #expect(server.moveRequests.map { $0.item.ownerPID } == [1, 1, 1])
        #expect(server.moveRequests.map { $0.item.ownerBundleID } == ["test.app.1", "test.app.2", "test.app.3"])
        let hidden = try #require(server.base.items.first(where: { $0.windowID == 3 }))
        let shown = try #require(server.base.items.first(where: { $0.windowID == 2 }))
        #expect(hidden.frame.maxX <= 1016)
        #expect(shown.frame.minX >= 1064)
    }

    @Test(arguments: [false, true], [CGFloat(0), CGFloat(8), CGFloat(-8)])
    func nativeReturnWithoutReachingTheRequestedSideFails(hidden: Bool, distance: CGFloat) async {
        let startX: CGFloat = hidden ? 1130 : 800
        let landed = item(1, x: startX + (hidden ? -distance : distance))
        let finalItems = [landed] + controlItems
        let server = ScriptedWindowServer(items: [item(1, x: startX)] + controlItems)
        server.onMove = { [unowned server] _, _, _ in
            server.base = FakeWindowServer(items: finalItems)
        }
        let controller = HiddenItemController(windowServer: server)
        var controls = ItemControlStore()
        controls.setHidden(hidden, forKey: "test.app.1")

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(result.planned == 1)
        #expect(result.succeeded == 0)
        #expect(result.failed.map(\.windowID) == [1])
        #expect(!result.allSucceeded)
        #expect(!result.observationFailed)
        #expect(server.moveRequests.count == 1)
    }

    @Test(arguments: [false, true])
    func anItemOverlappingItsBoundaryDoesNotCountAsSuccessfullyPlaced(hidden: Bool) async {
        let landed = [item(1, x: hidden ? 975 : 1023)] + controlItems
        let server = ScriptedWindowServer(items: [item(1, x: hidden ? 1130 : 800)] + controlItems)
        server.onMove = { [unowned server] _, _, _ in
            server.base = FakeWindowServer(items: landed)
        }
        let controller = HiddenItemController(windowServer: server)
        var controls = ItemControlStore()
        controls.setHidden(hidden, forKey: "test.app.1")

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(server.moveRequests.count == 1)
        #expect(result.succeeded == 0)
        #expect(result.failed.map(\.windowID) == [1])
        #expect(!result.allSucceeded)
        #expect(!result.observationFailed)
    }

    @Test func aMoveErrorDoesNotPreventTheNextCandidateFromSucceeding() async {
        let server = ScriptedWindowServer(items: items + controlItems)
        server.onMove = { [unowned server] item, targetX, targetWindowID in
            if item.windowID == 1 { throw WindowServerError.moveFailed(windowID: item.windowID) }
            try await server.base.move(item: item, toX: targetX, relativeTo: targetWindowID)
        }
        let controller = HiddenItemController(windowServer: server)

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(server.moveRequests.map { $0.item.windowID } == [1, 2])
        #expect(result.planned == 2)
        #expect(result.succeeded == 1)
        #expect(result.failed.map(\.windowID) == [1])
        #expect(!result.allSucceeded)
        #expect(!result.cancelled)
        #expect(!result.observationFailed)
    }

    @Test func aNeighborAlreadyPlacedByReflowIsNotMovedAgain() async {
        let server = ScriptedWindowServer(items: items + controlItems)
        let reflowed = [item(1, x: 946), item(2, x: 900)] + controlItems
        server.onMove = { [unowned server] _, _, _ in
            server.base = FakeWindowServer(items: reflowed)
        }
        let controller = HiddenItemController(windowServer: server)

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(server.moveRequests.map { $0.item.windowID } == [1])
        #expect(result.planned == 2)
        #expect(result.succeeded == 1)
        #expect(result.failed.isEmpty)
        #expect(result.allSucceeded)
    }

    @Test(arguments: [false, true])
    func aMissingControlFailsObservationBeforeAttribution(missingAnchor: Bool) async {
        let missingID = missingAnchor ? anchorWindowID : dividerWindowID
        let server = FakeWindowServer(items: items + controlItems.filter { $0.windowID != missingID })
        var attributed = false
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributed = true
            return snapshots
        }

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(!attributed)
        #expect(server.moveRequests.isEmpty)
        #expect(result.planned == 0)
        #expect(result.observationFailed)
        #expect(!result.allSucceeded)
        #expect(!result.cancelled)
    }

    @Test(arguments: [CGFloat(995), CGFloat(1100)])
    func overlappingOrInvertedControlsFailObservation(dividerX: CGFloat) async {
        let invalidControls = [
            controlItems[0], item(dividerWindowID, x: dividerX, width: 8, title: "BKFHidden"),
        ]
        let server = FakeWindowServer(items: items + invalidControls)
        let controller = HiddenItemController(windowServer: server)

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(server.moveRequests.isEmpty)
        #expect(result.observationFailed)
        #expect(!result.allSucceeded)
    }

    @Test func aZeroWidthRevealedDividerStillDefinesTheHiddenBoundary() async {
        let revealedControls = [
            controlItems[0], item(dividerWindowID, x: 976, width: 0, title: "BKFHidden"),
        ]
        let server = FakeWindowServer(items: items + revealedControls)
        let controller = HiddenItemController(windowServer: server)

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(result.succeeded == 2)
        #expect(result.allSucceeded)
        #expect(server.moveRequests.map(\.targetX) == [968, 968])
        #expect(server.moveRequests.map(\.targetWindowID) == [dividerWindowID, dividerWindowID])
    }

    @Test(arguments: 1...6)
    func enumerationErrorsCannotReportSuccessOrStartLaterMoves(failingRead: Int) async {
        let server = ScriptedWindowServer(items: items + controlItems)
        server.beforeRead = { read in
            if read == failingRead { throw WindowServerError.invalidServerResponse("enumeration failed") }
        }
        let controller = HiddenItemController(windowServer: server)

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(server.readCount == failingRead)
        #expect(server.moveRequests.count == max(0, (failingRead - 2) / 2))
        #expect(result.planned == (failingRead > 2 ? 2 : 0))
        #expect(result.succeeded == (failingRead > 4 ? 1 : 0))
        #expect(result.observationFailed)
        #expect(!result.allSucceeded)
        #expect(!result.cancelled)
    }

    @Test(arguments: [false, true])
    func controlLossOrInversionDuringAMoveStopsVerificationAndTheNextMove(inverted: Bool) async {
        let invalidControls = inverted
            ? [controlItems[0], item(dividerWindowID, x: 1100, width: 8, title: "BKFHidden")]
            : [controlItems[0]]
        let finalItems = [item(1, x: 946), item(2, x: 1160)] + invalidControls
        let server = ScriptedWindowServer(items: items + controlItems)
        server.onMove = { [unowned server] _, _, _ in
            server.base = FakeWindowServer(items: finalItems)
        }
        let controller = HiddenItemController(windowServer: server)

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(server.moveRequests.map { $0.item.windowID } == [1])
        #expect(result.planned == 2)
        #expect(result.succeeded == 0)
        #expect(result.observationFailed)
        #expect(!result.allSucceeded)
    }

    @Test(arguments: [3, 4])
    func aCandidateLostBeforeMovementOrVerificationFailsWithoutBlockingItsNeighbor(disappearingRead: Int) async {
        let remaining = [item(2, x: 1160)] + controlItems
        let server = ScriptedWindowServer(items: items + controlItems)
        server.beforeRead = { [unowned server] read in
            if read == disappearingRead { server.base = FakeWindowServer(items: remaining) }
        }
        let controller = HiddenItemController(windowServer: server)

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(server.moveRequests.map { $0.item.windowID } == (disappearingRead == 3 ? [2] : [1, 2]))
        #expect(result.planned == 2)
        #expect(result.succeeded == 1)
        #expect(result.failed.map(\.windowID) == [1])
        #expect(!result.observationFailed)
        #expect(!result.allSucceeded)
    }

    @Test func ownControlsTransientWindowsAndOtherDisplaysAreFilteredBeforeAttribution() async {
        let raw = [
            item(92, x: 1130),
            item(93, x: 1130, title: "BKFAnchor"),
            item(94, x: 1130, height: 120),
            item(95, x: 1130, width: 1, height: 1),
            item(96, x: 1130, y: 982),
            item(97, x: 3130),
            item(98, x: 1130, owner: "com.apple.controlcenter"),
            item(99, x: 1130, title: "Clock"),
            item(1, x: 1130),
        ] + controlItems
        let server = FakeWindowServer(items: raw)
        var attributedIDs: [CGWindowID] = []
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributedIDs = snapshots.map(\.windowID)
            return snapshots
        }
        controller.controlItemWindowIDs = [92]

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls,
            displayXRange: 0...1512, displayMenuBarTop: 0
        )

        #expect(attributedIDs == [1])
        #expect(server.moveRequests.map(\.windowID) == [1])
        #expect(result.planned == 1)
        #expect(result.succeeded == 1)
        #expect(result.allSucceeded)
    }

    @Test func aNegativeOriginDisplayUsesItsOwnMenuBarRowAndControls() async {
        let server = FakeWindowServer(items: [
            item(1, x: -382, y: -982),
            item(2, x: -382, y: 0),
            item(3, x: 1130, y: -982),
            item(anchorWindowID, x: -512, y: -982, width: 24, title: "BKFAnchor"),
            item(dividerWindowID, x: -536, y: -982, width: 8, title: "BKFHidden"),
        ])
        var attributedIDs: [CGWindowID] = []
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributedIDs = snapshots.map(\.windowID)
            return snapshots
        }

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls,
            displayXRange: -1512...0, displayMenuBarTop: -982
        )

        #expect(attributedIDs == [1])
        #expect(server.moveRequests.map(\.windowID) == [1])
        #expect(server.moveRequests.first?.targetX == -544)
        #expect(server.moveRequests.first?.targetWindowID == dividerWindowID)
        #expect(result.succeeded == 1)
        #expect(result.allSucceeded)
    }

    @Test func controlCenterLabelsAndImmovablePIDsAreExcludedOnlyAfterAttribution() async {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let raw = [
            item(1, x: 1130, owner: "Control Center", pid: ownPID),
            item(2, x: 1160, owner: "Control Center", pid: ownPID),
            item(3, x: 1190, owner: "Control Center", pid: ownPID),
        ] + controlItems
        let server = ScriptedWindowServer(items: raw)
        var attributedIDs: [CGWindowID] = []
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributedIDs = snapshots.map(\.windowID)
            return snapshots.map {
                switch $0.windowID {
                case 2: return $0.attributed(bundleID: "Battery", pid: ownPID)
                case 3: return $0.attributed(bundleID: "Control Center", pid: 1)
                default: return $0.attributed(bundleID: "test.app.1", pid: 1)
                }
            }
        }
        let controls = ItemControlStore(hiddenInMenuBar: ["test.app.1", "Battery", "Control Center"])

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(attributedIDs == [1, 2, 3])
        #expect(server.moveRequests.map { $0.item.windowID } == [1])
        #expect(server.moveRequests.first?.item.ownerPID == 1)
        #expect(server.moveRequests.first?.item.ownerBundleID == "test.app.1")
        #expect(result.planned == 1)
        #expect(result.succeeded == 1)
        #expect(result.allSucceeded)
    }

    @Test(arguments: [false, true])
    func coLocatedBackingWindowsKeepTheFirstEnumeratedGlyph(reversed: Bool) async throws {
        let windows = [
            item(2, x: 1131, owner: "Control Center", pid: -1),
            item(1, x: 1130, owner: "Control Center", pid: -1),
        ]
        let ordered = reversed ? Array(windows.reversed()) : windows
        let server = FakeWindowServer(items: ordered + controlItems)
        var attributedIDs: [CGWindowID] = []
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributedIDs = snapshots.map(\.windowID)
            return snapshots.map { $0.attributed(bundleID: "test.app.1", pid: 1) }
        }

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(attributedIDs == [ordered[0].windowID])
        #expect(server.moveRequests.map(\.windowID) == [ordered[0].windowID])
        #expect(result.planned == 1)
        #expect(result.succeeded == 1)
        #expect(result.allSucceeded)
        let backing = try #require(server.items.first(where: { $0.windowID == ordered[1].windowID }))
        #expect(backing == ordered[1])
    }

    @Test(arguments: [false, true])
    func geometryChangedDuringAttributionIsDiscardedAndRetriedOnce(controlsMoved: Bool) async {
        let changedControls = controlsMoved ? [
            item(anchorWindowID, x: 1064, width: 24, title: "BKFAnchor"),
            item(dividerWindowID, x: 1040, width: 8, title: "BKFHidden"),
        ] : controlItems
        let changedItem = item(1, x: controlsMoved ? 1130 : 1190, owner: "Control Center", pid: -1)
        let changed = [changedItem] + changedControls
        let server = ScriptedWindowServer(items: [item(1, x: 1130, owner: "Control Center", pid: -1)] + controlItems)
        var attributionCalls = 0
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributionCalls += 1
            if attributionCalls == 1 {
                server.base = FakeWindowServer(items: changed)
                return snapshots.map { $0.attributed(bundleID: "stale.owner", pid: 1) }
            }
            return snapshots.map { $0.attributed(bundleID: "test.app.1", pid: 1) }
        }
        let controls = ItemControlStore(hiddenInMenuBar: ["test.app.1", "stale.owner"])

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(attributionCalls == 2)
        #expect(server.moveRequests.count == 1)
        #expect(server.moveRequests.first?.item.frame == changedItem.frame)
        #expect(server.moveRequests.first?.item.ownerBundleID == "test.app.1")
        #expect(server.moveRequests.first?.targetX == (controlsMoved ? 1032 : 968))
        #expect(result.succeeded == 1)
        #expect(result.allSucceeded)
    }

    @Test func aSecondGeometryChangeDuringAttributionFailsWithoutAnotherRetry() async {
        let changed = [
            [item(1, x: 1190)] + controlItems,
            [item(1, x: 1220)] + controlItems,
        ]
        let server = ScriptedWindowServer(items: [item(1, x: 1130)] + controlItems)
        var attributionCalls = 0
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributionCalls += 1
            server.base = FakeWindowServer(items: changed[min(attributionCalls - 1, 1)])
            return snapshots
        }

        let result = await controller.reconcile(
            anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls
        )

        #expect(attributionCalls == 2)
        #expect(server.readCount == 3)
        #expect(server.moveRequests.isEmpty)
        #expect(result.planned == 0)
        #expect(result.succeeded == 0)
        #expect(result.observationFailed)
        #expect(!result.allSucceeded)
    }

    @Test func cancellingDuringAttributionSkipsFurtherObservationAndMoves() async {
        let server = ScriptedWindowServer(items: items + controlItems)
        let started = AsyncGate()
        let finish = AsyncGate()
        let controller = HiddenItemController(windowServer: server) { snapshots in
            await started.open()
            await finish.wait()
            return snapshots
        }
        let task = Task {
            await controller.reconcile(anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls)
        }
        await started.wait()
        task.cancel()
        await finish.open()
        let result = await task.value

        #expect(server.readCount == 1)
        #expect(server.moveRequests.isEmpty)
        #expect(result.planned == 0)
        #expect(result.cancelled)
        #expect(!result.allSucceeded)
        #expect(!result.observationFailed)
        #expect(result.failed.isEmpty)
    }

    @Test(arguments: 1...3)
    func cancellationDuringObservationDoesNotStartNativeWork(cancellingRead: Int) async {
        let server = ScriptedWindowServer(items: items + controlItems)
        server.beforeRead = { read in
            if read == cancellingRead { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var attributionCalls = 0
        let controller = HiddenItemController(windowServer: server) { snapshots in
            attributionCalls += 1
            return snapshots
        }
        let task = Task {
            await controller.reconcile(anchorWindowID: anchorWindowID, dividerWindowID: dividerWindowID, controls: controls)
        }
        let result = await task.value

        #expect(server.readCount == cancellingRead)
        #expect(attributionCalls == (cancellingRead == 1 ? 0 : 1))
        #expect(server.moveRequests.isEmpty)
        #expect(result.planned == (cancellingRead == 1 ? 0 : 2))
        #expect(result.cancelled)
        #expect(!result.allSucceeded)
        #expect(!result.observationFailed)
        #expect(result.failed.isEmpty)
    }

}

private final class ScriptedWindowServer: WindowServer, @unchecked Sendable {
    var base: FakeWindowServer
    var beforeRead: ((Int) throws -> Void)?
    var onMove: ((MenuBarItemSnapshot, CGFloat, CGWindowID) async throws -> Void)?
    private(set) var readCount = 0
    private(set) var moveRequests: [(item: MenuBarItemSnapshot, targetX: CGFloat, targetWindowID: CGWindowID)] = []

    init(items: [MenuBarItemSnapshot]) {
        base = FakeWindowServer(items: items)
    }

    var canSynthesizeClicks: Bool { base.canSynthesizeClicks }
    func menuBarItems() throws -> [MenuBarItemSnapshot] {
        readCount += 1
        try beforeRead?(readCount)
        return try base.menuBarItems()
    }
    func menuBarFrame(forDisplayContaining point: CGPoint) throws -> CGRect {
        try base.menuBarFrame(forDisplayContaining: point)
    }
    func click(item: MenuBarItemSnapshot) throws { try base.click(item: item) }
    func move(item: MenuBarItemSnapshot, toX targetX: CGFloat, relativeTo targetWindowID: CGWindowID) async throws {
        moveRequests.append((item, targetX, targetWindowID))
        if let onMove {
            try await onMove(item, targetX, targetWindowID)
        } else {
            try await base.move(item: item, toX: targetX, relativeTo: targetWindowID)
        }
    }
}

import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

/// Exercises the pure planner/fake contract with stationary control fixtures.
/// App adapter tests cover live re-observation, attribution, cancellation, and verification failures.
@Suite struct HiddenItemControllerLogicTests {

    private let anchorMinX: CGFloat = 1000
    private let anchorMaxX: CGFloat = 1024
    private let dividerMinX: CGFloat = 976
    private let anchorWindowID: CGWindowID = 99
    private let dividerWindowID: CGWindowID = 98
    private var controlItems: [MenuBarItemSnapshot] {
        [
            MenuBarItemSnapshot(
                windowID: anchorWindowID, ownerPID: 1, title: "BKFAnchor",
                frame: CGRect(x: anchorMinX, y: 0, width: anchorMaxX - anchorMinX, height: 22)
            ),
            MenuBarItemSnapshot(
                windowID: dividerWindowID, ownerPID: 1, title: "BKFHidden",
                frame: CGRect(x: dividerMinX, y: 0, width: 8, height: 22)
            ),
        ]
    }

    private func item(_ bundle: String?, x: CGFloat, id: CGWindowID) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: id, ownerPID: 1, ownerBundleID: bundle, title: nil,
                            frame: CGRect(x: x, y: 0, width: 22, height: 22))
    }

    /// Only a verified placement counts as success, even when the move itself returns normally.
    private func reconcile(_ server: FakeWindowServer, _ controls: ItemControlStore, exclude: Set<CGWindowID> = []) async -> (planned: Int, ok: Int, failed: Int) {
        let snapshots = (try? server.menuBarItems()) ?? []
        let plan = HiddenLayoutPlanner.moves(
            for: snapshots, anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls, excludingWindowIDs: exclude.union([anchorWindowID, dividerWindowID])
        )
        var ok = 0, failed = 0
        for move in plan {
            do {
                let hidden = controls.isHidden(move.item)
                try await server.move(
                    item: move.item, toX: move.targetX,
                    relativeTo: hidden ? dividerWindowID : anchorWindowID
                )
                if let live = try server.menuBarItems().first(where: { $0.windowID == move.item.windowID }),
                   HiddenLayoutPlanner.isPlacementSatisfied(
                       item: live, hidden: hidden, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX
                   ) {
                    ok += 1
                } else {
                    failed += 1
                }
            } catch { failed += 1 }
        }
        return (plan.count, ok, failed)
    }

    @Test func reconcileMovesAShownItemMarkedHiddenToTheLeft() async throws {
        let server = FakeWindowServer(items: [item("com.a.app", x: 1100, id: 1)] + controlItems)
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "com.a.app")

        let result = await reconcile(server, controls)
        #expect(result.planned == 1)
        #expect(result.ok == 1)
        let moved = try #require(try server.menuBarItems().first(where: { $0.windowID == 1 }))
        #expect(moved.frame.maxX <= dividerMinX)
        #expect(server.moveRequests.first?.targetWindowID == dividerWindowID)
    }

    @Test func shownOnlyIntentRestoresAnItemRightOfTheAnchor() async throws {
        let server = FakeWindowServer(items: [item("com.a.app", x: 300, id: 1)] + controlItems)
        let controls = ItemControlStore(shownInMenuBar: ["com.a.app"])

        let result = await reconcile(server, controls)
        #expect(result.planned == 1)
        #expect(result.ok == 1)
        #expect(result.failed == 0)
        let moved = try #require(try server.menuBarItems().first(where: { $0.windowID == 1 }))
        #expect(moved.frame.minX >= anchorMaxX)
        #expect(server.moveRequests.first?.targetWindowID == anchorWindowID)
    }

    @Test func reconcileIsNoOpWhenEverythingIsAlreadyCorrect() async {
        let server = FakeWindowServer(items: [
            item("com.a.app", x: 300, id: 1),   // hidden + wants hidden
            item("com.b.app", x: 1100, id: 2),  // shown + wants shown
        ] + controlItems)
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "com.a.app")
        controls.setHidden(false, forKey: "com.b.app")

        let result = await reconcile(server, controls)
        #expect(result.planned == 0)
        #expect(server.moveRequests.isEmpty)
    }

    @Test func reconcileContinuesAfterAMoveFailure() async {
        // Inject a move failure: the whole pass should report it without trapping, and (with the
        // fake's single error flag) still attempt each planned item.
        let server = FakeWindowServer(items: [item("com.a.app", x: 1100, id: 1)] + controlItems)
        server.moveError = .moveFailed(windowID: 1)
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "com.a.app")

        let result = await reconcile(server, controls)
        #expect(result.planned == 1)
        #expect(result.ok == 0)
        #expect(result.failed == 1)
    }

    @Test func reconcileNeverMovesExcludedControlItems() async {
        let server = FakeWindowServer(items: [item("com.agraabhi.BarKeepersFriend", x: 1100, id: 97)] + controlItems)
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "com.agraabhi.BarKeepersFriend")

        let result = await reconcile(server, controls, exclude: [97])
        #expect(result.planned == 0)
    }

    // MARK: - Always Hidden tier

    private let alwaysHiddenWindowID: CGWindowID = 97
    private let alwaysHiddenFrame = CGRect(x: 600, y: 0, width: 8, height: 22)

    /// Three-tier variant: each move is dropped relative to the control that bounds its tier.
    private func reconcileTiers(_ server: FakeWindowServer, _ controls: ItemControlStore) async -> (planned: Int, ok: Int, failed: Int) {
        let snapshots = (try? server.menuBarItems()) ?? []
        let plan = HiddenLayoutPlanner.moves(
            for: snapshots, anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls, excludingWindowIDs: [anchorWindowID, dividerWindowID, alwaysHiddenWindowID],
            alwaysHiddenDividerFrame: alwaysHiddenFrame
        )
        var ok = 0, failed = 0
        for move in plan {
            let reference: CGWindowID
            switch move.placement {
            case .shown: reference = anchorWindowID
            case .hidden: reference = dividerWindowID
            case .alwaysHidden: reference = alwaysHiddenWindowID
            }
            do {
                try await server.move(item: move.item, toX: move.targetX, relativeTo: reference)
                if let live = try server.menuBarItems().first(where: { $0.windowID == move.item.windowID }),
                   HiddenLayoutPlanner.isPlacementSatisfied(
                       item: live, placement: move.placement, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
                       alwaysHiddenDividerFrame: alwaysHiddenFrame
                   ) {
                    ok += 1
                } else {
                    failed += 1
                }
            } catch { failed += 1 }
        }
        return (plan.count, ok, failed)
    }

    @Test func everyTierLandsBesideItsOwnControlAndVerifiesFullEdge() async throws {
        let alwaysHiddenDivider = MenuBarItemSnapshot(
            windowID: alwaysHiddenWindowID, ownerPID: 1, title: "BKFAlwaysHidden", frame: alwaysHiddenFrame
        )
        let server = FakeWindowServer(items: [
            item("com.a.app", x: 1100, id: 1),   // shown → always hidden
            item("com.b.app", x: 700, id: 2),    // hidden → always hidden
            item("com.c.app", x: 300, id: 3),    // always hidden → hidden
            item("com.d.app", x: 250, id: 4),    // always hidden → shown
            item("com.e.app", x: 800, id: 5),    // hidden, stays hidden
        ] + controlItems + [alwaysHiddenDivider])
        let controls = ItemControlStore(
            hiddenInMenuBar: ["com.c.app", "com.e.app"], shownInMenuBar: ["com.d.app"],
            alwaysHiddenInMenuBar: ["com.a.app", "com.b.app"]
        )

        let result = await reconcileTiers(server, controls)
        #expect(result.planned == 4)
        #expect(result.ok == 4)
        #expect(result.failed == 0)
        #expect(server.moveRequests.map(\.windowID) == [1, 2, 3, 4])
        #expect(server.moveRequests.map(\.targetWindowID) == [alwaysHiddenWindowID, alwaysHiddenWindowID, dividerWindowID, anchorWindowID])
        #expect(server.moveRequests.map(\.targetX) == [592, 592, 968, 1032])
        let live = try server.menuBarItems()
        #expect(live.first { $0.windowID == 1 }?.frame.maxX == 592)
        #expect(live.first { $0.windowID == 3 }?.frame.maxX == 968)
        #expect(live.first { $0.windowID == 3 }?.frame.minX ?? 0 >= alwaysHiddenFrame.maxX)
        #expect(live.first { $0.windowID == 4 }?.frame.minX == 1032)
        #expect(live.first { $0.windowID == 5 }?.frame.minX == 800)

        let repeated = await reconcileTiers(server, controls)
        #expect(repeated.planned == 0)
        #expect(server.moveRequests.count == 4)
    }
}

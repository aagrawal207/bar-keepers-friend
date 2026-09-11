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
}

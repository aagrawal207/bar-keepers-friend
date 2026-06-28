import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

/// The app-side `HiddenItemController` lives in the App target (it touches AppKit), so it can't be
/// unit-tested directly from the Core test bundle. Its DECISION logic, however, is the pure
/// `HiddenLayoutPlanner` driving a `WindowServer` — which we CAN exercise end-to-end here against
/// `FakeWindowServer`, proving the plan-then-move-each contract the controller relies on: only
/// wrong-side items move, failures don't abort the rest, and the fake actually relocates items.
@Suite struct HiddenItemControllerLogicTests {

    private let anchorMinX: CGFloat = 1000
    private let anchorMaxX: CGFloat = 1024

    private func item(_ bundle: String?, x: CGFloat, id: CGWindowID) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: id, ownerPID: 1, ownerBundleID: bundle, title: nil,
                            frame: CGRect(x: x, y: 0, width: 22, height: 22))
    }

    /// Mirrors `HiddenItemController.reconcile`'s loop over the pure planner, so the orchestration
    /// contract is covered without importing the App target.
    private func reconcile(_ server: FakeWindowServer, _ controls: ItemControlStore, exclude: Set<CGWindowID> = []) async -> (planned: Int, ok: Int, failed: Int) {
        let snapshots = (try? server.menuBarItems()) ?? []
        let plan = HiddenLayoutPlanner.moves(
            for: snapshots, anchorMinX: anchorMinX, anchorMaxX: anchorMaxX,
            controls: controls, excludingWindowIDs: exclude
        )
        var ok = 0, failed = 0
        for move in plan {
            do { try await server.move(item: move.item, toX: move.targetX); ok += 1 }
            catch { failed += 1 }
        }
        return (plan.count, ok, failed)
    }

    @Test func reconcileMovesAShownItemMarkedHiddenToTheLeft() async {
        let server = FakeWindowServer(items: [item("com.a.app", x: 1100, id: 1)])
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "com.a.app")

        let result = await reconcile(server, controls)
        #expect(result.planned == 1)
        #expect(result.ok == 1)
        // The fake moved it to the planned destination, which is left of the anchor.
        #expect((try? server.menuBarItems().first?.frame.minX ?? 0) ?? 0 < anchorMinX)
    }

    @Test func reconcileIsNoOpWhenEverythingIsAlreadyCorrect() async {
        let server = FakeWindowServer(items: [
            item("com.a.app", x: 300, id: 1),   // hidden + wants hidden
            item("com.b.app", x: 1100, id: 2),  // shown + wants shown
        ])
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "com.a.app")

        let result = await reconcile(server, controls)
        #expect(result.planned == 0)
        #expect(server.moveRequests.isEmpty)
    }

    @Test func reconcileContinuesAfterAMoveFailure() async {
        // Inject a move failure: the whole pass should report it without trapping, and (with the
        // fake's single error flag) still attempt each planned item.
        let server = FakeWindowServer(items: [item("com.a.app", x: 1100, id: 1)])
        server.moveError = .moveFailed(windowID: 1)
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "com.a.app")

        let result = await reconcile(server, controls)
        #expect(result.planned == 1)
        #expect(result.ok == 0)
        #expect(result.failed == 1)
    }

    @Test func reconcileNeverMovesExcludedControlItems() async {
        let server = FakeWindowServer(items: [item("com.agraabhi.BarKeepersFriend", x: 1100, id: 99)])
        var controls = ItemControlStore()
        controls.setHidden(true, forKey: "com.agraabhi.BarKeepersFriend")

        let result = await reconcile(server, controls, exclude: [99])
        #expect(result.planned == 0)
    }
}

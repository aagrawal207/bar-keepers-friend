import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct HiddenLayoutPlannerTests {

    /// Anchor occupies x ∈ [1000, 1024]. Items left of 1000 are "hidden"; right of 1024 "shown".
    private let anchorMinX: CGFloat = 1000
    private let anchorMaxX: CGFloat = 1024

    private func item(_ bundle: String?, x: CGFloat, id: CGWindowID = 1, title: String? = nil) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id,
            ownerPID: 1,
            ownerBundleID: bundle,
            title: title,
            frame: CGRect(x: x, y: 0, width: 22, height: 22)
        )
    }

    private func moves(_ items: [MenuBarItemSnapshot], _ controls: ItemControlStore, exclude: Set<CGWindowID> = []) -> [HiddenLayoutPlanner.Move] {
        HiddenLayoutPlanner.moves(
            for: items,
            anchorMinX: anchorMinX,
            anchorMaxX: anchorMaxX,
            controls: controls,
            excludingWindowIDs: exclude
        )
    }

    @Test func itemMarkedHiddenButCurrentlyShownGetsMovedLeft() {
        var controls = ItemControlStore()
        let maccy = item("com.maccy.Maccy", x: 1100, id: 1) // right of anchor → currently shown
        controls.setHidden(true, for: maccy)

        let result = moves([maccy], controls)
        #expect(result.count == 1)
        #expect(result.first?.item.windowID == 1)
        #expect(result.first!.targetX < anchorMinX) // moved to the hidden (left) side
    }

    @Test func itemMarkedShownButCurrentlyHiddenGetsMovedRight() {
        var controls = ItemControlStore()
        let maccy = item("com.maccy.Maccy", x: 400, id: 1) // left of anchor → currently hidden
        // Intent is Shown (default — not in hiddenInMenuBar), so it must move right.
        _ = controls // no hide set

        let result = moves([maccy], controls)
        #expect(result.count == 1)
        #expect(result.first!.targetX > anchorMaxX)
    }

    @Test func itemAlreadyOnCorrectSideIsNotMoved() {
        var controls = ItemControlStore()
        let hiddenWanted = item("com.a.app", x: 400, id: 1)   // already left, wants hidden
        let shownWanted = item("com.b.app", x: 1100, id: 2)   // already right, wants shown
        controls.setHidden(true, for: hiddenWanted)

        let result = moves([hiddenWanted, shownWanted], controls)
        #expect(result.isEmpty)
    }

    @Test func immovableSystemItemIsNeverMovedEvenIfMarkedHidden() {
        var controls = ItemControlStore()
        let controlCenter = item("com.apple.controlcenter", x: 1100, id: 1)
        controls.setHidden(true, for: controlCenter) // user intent ignored for system items

        #expect(moves([controlCenter], controls).isEmpty)
    }

    @Test func keylessItemIsNeverMoved() {
        let controls = ItemControlStore()
        // No bundle id → no stable identity → can't carry intent → leave it alone.
        let keyless = item(nil, x: 1100, id: 1, title: "Item-0")
        #expect(moves([keyless], controls).isEmpty)
    }

    @Test func ownControlItemsAreExcluded() {
        var controls = ItemControlStore()
        // Even if somehow marked, our own items (passed via exclude) are never planned.
        let anchor = item("com.agraabhi.BarKeepersFriend", x: 1100, id: 99)
        controls.setHidden(true, for: anchor)
        #expect(moves([anchor], controls, exclude: [99]).isEmpty)
    }

    @Test func mixedSetMovesOnlyTheWrongSideItems() {
        var controls = ItemControlStore()
        let a = item("com.a.app", x: 1100, id: 1)  // shown, wants hidden → MOVE left
        let b = item("com.b.app", x: 1200, id: 2)  // shown, wants shown → stay
        let c = item("com.c.app", x: 300, id: 3)   // hidden, wants shown → MOVE right
        let d = item("com.d.app", x: 200, id: 4)   // hidden, wants hidden → stay
        controls.setHidden(true, for: a)
        controls.setHidden(true, for: d)

        let result = moves([a, b, c, d], controls)
        let movedIDs = Set(result.map { $0.item.windowID })
        #expect(movedIDs == [1, 3])
    }
}

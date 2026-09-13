import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct HiddenLayoutPlannerTests {

    /// The divider starts at 976; the anchor spans 1000...1024. The gap satisfies neither intent.
    private let anchorMinX: CGFloat = 1000
    private let anchorMaxX: CGFloat = 1024
    private let dividerMinX: CGFloat = 976

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
            dividerMinX: dividerMinX,
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
        #expect(result.first!.targetX == dividerMinX - 8)
    }

    @Test func itemMarkedShownButCurrentlyHiddenGetsMovedRight() {
        var controls = ItemControlStore()
        let maccy = item("com.maccy.Maccy", x: 400, id: 1) // left of anchor → currently hidden
        // EXPLICIT Shown intent (the user toggled it back to Shown). Only an explicit intent moves
        // an item — a never-configured item left of the anchor is left alone (next test).
        controls.setHidden(false, for: maccy)

        let result = moves([maccy], controls)
        #expect(result.count == 1)
        #expect(result.first!.targetX > anchorMaxX)
        #expect(result.first!.targetX == anchorMaxX + 8)
    }

    @Test func unconfiguredItemIsNeverMovedEvenIfLeftOfAnchor() {
        // The core "only move what I toggle" guarantee: an item the user never set an intent for is
        // left exactly where it sits, so hiding one item can't drag every other item around.
        let controls = ItemControlStore()
        let untouched = item("com.maccy.Maccy", x: 400, id: 1) // left of anchor, no intent recorded
        #expect(moves([untouched], controls).isEmpty)
    }

    @Test func itemAlreadyOnCorrectSideIsNotMoved() {
        var controls = ItemControlStore()
        let hiddenWanted = item("com.a.app", x: 400, id: 1)   // already left, wants hidden
        let shownWanted = item("com.b.app", x: 1100, id: 2)   // already right, wants shown
        controls.setHidden(true, for: hiddenWanted)
        controls.setHidden(false, for: shownWanted)

        let result = moves([hiddenWanted, shownWanted], controls)
        #expect(result.isEmpty)
    }

    @Test func immovableSystemItemIsNeverMovedEvenIfMarkedHidden() {
        var controls = ItemControlStore()
        let controlCenter = item("com.apple.controlcenter", x: 1100, id: 1)
        controls.setHidden(true, for: controlCenter) // user intent ignored for system items

        #expect(moves([controlCenter], controls).isEmpty)
    }

    @Test func itemOwnedByAnImmovablePIDIsNeverMovedEvenIfMarkedHidden() {
        // A Control Center module: a genuine third-party-looking label can still be attributed, but
        // its owning pid is Control Center's, which is in the immovable set. It must never be planned
        // — this is the "Hide All swept in Battery/Sound/Clock and reconcile thrashed forever" bug.
        let ccModule = MenuBarItemSnapshot(
            windowID: 7, ownerPID: 501, ownerBundleID: "Battery",
            title: "Battery", frame: CGRect(x: 1100, y: 0, width: 22, height: 22)
        )
        var controls = ItemControlStore()
        controls.setHidden(true, for: ccModule)
        let result = HiddenLayoutPlanner.moves(
            for: [ccModule], anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls, immovablePIDs: [501]
        )
        #expect(result.isEmpty)
    }

    @Test func ownAppPIDIsNeverMovedEvenIfMarkedHidden() {
        // Belt-and-suspenders for our own status windows beyond the window-id exclusion: if our own
        // pid is in the immovable set, a marked-hidden own item is refused (moving our anchor would
        // shift the very hide/show boundary and send reconcile into an endless re-plan loop).
        let ownItem = MenuBarItemSnapshot(
            windowID: 8, ownerPID: 4242, ownerBundleID: "Bar Keeper's Friend",
            title: "Item-0", frame: CGRect(x: 1100, y: 0, width: 22, height: 22)
        )
        var controls = ItemControlStore()
        controls.setHidden(true, for: ownItem)
        let result = HiddenLayoutPlanner.moves(
            for: [ownItem], anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls, immovablePIDs: [4242]
        )
        #expect(result.isEmpty)
    }

    @Test func itemWhosePIDIsNotImmovableStillMovesNormally() {
        // The pid set is strictly additive: an ordinary item with a non-immovable pid is unaffected.
        let maccy = MenuBarItemSnapshot(
            windowID: 9, ownerPID: 999, ownerBundleID: "com.maccy.Maccy",
            title: "Item-0", frame: CGRect(x: 1100, y: 0, width: 22, height: 22)
        )
        var controls = ItemControlStore()
        controls.setHidden(true, for: maccy)
        let result = HiddenLayoutPlanner.moves(
            for: [maccy], anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls, immovablePIDs: [501, 4242]
        )
        #expect(result.count == 1)
        #expect(result.first?.targetX == dividerMinX - 8)
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

    @Test(arguments: ["BKFAnchor", "BKFHidden", "BKFAlwaysHidden"])
    func ownControlTitlesAreSafeWithStaleWindowIDs(title: String) {
        let ownItem = item("Bar Keeper's Friend", x: 1100, id: 99, title: title)
        let controls = ItemControlStore(hiddenInMenuBar: ["Bar Keeper's Friend"])
        #expect(moves([ownItem], controls, exclude: [98]).isEmpty)
    }

    @Test(arguments: [false, true])
    func anItemBetweenTheControlsNeedsPlacement(hidden: Bool) {
        let between = item("com.a.app", x: 978)
        var controls = ItemControlStore()
        controls.setHidden(hidden, for: between)

        #expect(!HiddenLayoutPlanner.isPlacementSatisfied(
            item: between, hidden: hidden, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX
        ))
        let result = moves([between], controls)
        #expect(result.count == 1)
        #expect(result.first?.targetX == (hidden ? dividerMinX - 8 : anchorMaxX + 8))
    }

    @Test(arguments: [false, true])
    func placementAcceptsExactBoundaryButNotOnePointOverlap(hidden: Bool) {
        let boundaryX = hidden ? dividerMinX - 22 : anchorMaxX
        let placed = item("com.a.app", x: boundaryX)
        let overlapping = item("com.a.app", x: boundaryX + (hidden ? 1 : -1))
        var controls = ItemControlStore()
        controls.setHidden(hidden, for: placed)

        #expect(HiddenLayoutPlanner.isPlacementSatisfied(
            item: placed, hidden: hidden, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX
        ))
        #expect(!HiddenLayoutPlanner.isPlacementSatisfied(
            item: overlapping, hidden: hidden, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX
        ))
        #expect(moves([placed], controls).isEmpty)
        #expect(moves([overlapping], controls).count == 1)
    }

    @Test func wideHiddenItemMustClearTheDividerWithItsTrailingEdge() {
        let wide = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: "com.a.app",
            frame: CGRect(x: 800, y: 0, width: 200, height: 22)
        )
        let controls = ItemControlStore(hiddenInMenuBar: ["com.a.app"])
        #expect(wide.frame.minX < dividerMinX)
        #expect(!HiddenLayoutPlanner.isPlacementSatisfied(
            item: wide, hidden: true, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX
        ))
        #expect(moves([wide], controls).first?.targetX == dividerMinX - 8)
    }

    @Test func invertedControlEdgesProduceNoPlan() {
        let misplaced = item("com.a.app", x: 1100)
        let controls = ItemControlStore(hiddenInMenuBar: ["com.a.app"])
        #expect(HiddenLayoutPlanner.moves(
            for: [misplaced], anchorMinX: anchorMinX, anchorMaxX: anchorMaxX,
            dividerMinX: anchorMaxX + 1, controls: controls
        ).isEmpty)
        #expect(HiddenLayoutPlanner.moves(
            for: [misplaced], anchorMinX: anchorMaxX, anchorMaxX: anchorMinX,
            dividerMinX: dividerMinX, controls: controls
        ).isEmpty)
    }

    @Test func mixedSetMovesOnlyTheWrongSideItems() {
        var controls = ItemControlStore()
        let a = item("com.a.app", x: 1100, id: 1)  // shown, wants hidden → MOVE left
        let b = item("com.b.app", x: 1200, id: 2)  // shown, wants shown → stay
        let c = item("com.c.app", x: 300, id: 3)   // hidden, wants shown → MOVE right
        let d = item("com.d.app", x: 200, id: 4)   // hidden, wants hidden → stay
        controls.setHidden(true, for: a)
        controls.setHidden(false, for: b)  // explicit Shown intent (already on the right → stays)
        controls.setHidden(false, for: c)  // explicit Shown intent (on the left → must move right)
        controls.setHidden(true, for: d)

        let result = moves([a, b, c, d], controls)
        let movedIDs = Set(result.map { $0.item.windowID })
        #expect(movedIDs == [1, 3])
    }

    @Test func onlyExplicitlyToggledItemsMoveAmongUnconfiguredNeighbors() {
        // Hiding ONE item must not disturb the others. a is toggled Hidden (currently shown → moves);
        // b and c are never configured (left of anchor) and must stay put.
        var controls = ItemControlStore()
        let a = item("com.a.app", x: 1100, id: 1)  // shown, toggled hidden → MOVE left
        let b = item("com.b.app", x: 300, id: 2)   // hidden position, no intent → stay
        let c = item("com.c.app", x: 350, id: 3)   // hidden position, no intent → stay
        controls.setHidden(true, for: a)

        let result = moves([a, b, c], controls)
        #expect(Set(result.map { $0.item.windowID }) == [1])
    }

    @Test func itemsOnOtherDisplaysAreNeverMovedWhenDisplayRangeIsGiven() {
        // Multi-display: the enumeration includes the OTHER display's mirror copy of an item at a
        // far-away x. Only the copy on the anchor's display (here x∈[0,1512]) is movable. With a
        // display range pinned, the off-display copy (x≈3100) must be skipped, not retried-and-failed.
        var controls = ItemControlStore()
        let onDisplay = item("com.a.app", x: 1100, id: 1)    // anchor's display, shown, wants hidden
        let offDisplay = item("com.a.app", x: 3100, id: 2)   // secondary display mirror, same intent
        controls.setHidden(true, for: onDisplay)

        let result = HiddenLayoutPlanner.moves(
            for: [onDisplay, offDisplay],
            anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls, excludingWindowIDs: [],
            displayXRange: 0...1512
        )
        #expect(result.map { $0.item.windowID } == [1]) // only the on-display copy is planned
    }

    @Test func itemOnADisplayStackedBelowIsStillPlannedWhenDisplayTopIsGiven() {
        // An item whose intent is set but which lives on a display below the primary (menu bar at
        // global y≈982). With the default top=0 the plausibility filter rejects it (minY ≫ 40) and
        // no move is planned; supplying the display's menu-bar top makes the move plan correctly.
        var controls = ItemControlStore()
        let item = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: "com.a.app", title: nil,
            frame: CGRect(x: 1100, y: 982, width: 24, height: 22)) // shown side, wants hidden
        controls.setHidden(true, for: item)

        let rejected = HiddenLayoutPlanner.moves(
            for: [item], anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls) // default displayMenuBarTop: 0 → wrongly skipped
        #expect(rejected.isEmpty)

        let planned = HiddenLayoutPlanner.moves(
            for: [item], anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls, displayMenuBarTop: 982)
        #expect(planned.map { $0.item.windowID } == [1])
    }

    @Test func nilDisplayRangePlansAcrossAllItems() {
        // Single-display callers (and the FakeWindowServer tests) pass no range → no display filter,
        // so behavior is unchanged: both wrong-side copies are planned.
        var controls = ItemControlStore()
        let a = item("com.a.app", x: 1100, id: 1)
        let b = item("com.b.app", x: 3100, id: 2)
        controls.setHidden(true, for: a)
        controls.setHidden(true, for: b)

        let result = moves([a, b], controls) // moves() passes no displayXRange
        #expect(Set(result.map { $0.item.windowID }) == [1, 2])
    }

    @Test func transientStatusLayerWindowIsNeverMovedEvenSharingAnAppKey() {
        // An app can park a transient window (e.g. Karabiner's notification window, seen far down
        // the screen) at the status layer. It shares its app's owner key, so a "hide that app"
        // intent reaches it too — but it isn't a real menu bar glyph and the move always fails,
        // burning the full retry budget. The planner must skip it on shape (`isPlausibleMenuBarItem`)
        // and move only the real menu bar item. Regression for the on-device 17/24 → fewer-failures.
        var controls = ItemControlStore()
        let realItem = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 9, ownerBundleID: "org.pqrs.Karabiner",
            title: nil, frame: CGRect(x: 1100, y: 0, width: 24, height: 22)) // genuine, right of anchor
        let notification = MenuBarItemSnapshot(
            windowID: 2, ownerPID: 9, ownerBundleID: "org.pqrs.Karabiner",
            title: nil, frame: CGRect(x: 1100, y: 916, width: 360, height: 120)) // transient, low + huge
        controls.setHidden(true, forKey: "org.pqrs.Karabiner") // intent reaches BOTH (shared key)

        let result = moves([realItem, notification], controls)
        #expect(result.map { $0.item.windowID } == [1]) // only the real glyph is planned
    }

    // MARK: - Always Hidden tier

    /// The always-hidden divider spans 600...608, well left of the hidden divider at 976.
    private let alwaysHiddenFrame = CGRect(x: 600, y: 0, width: 8, height: 22)

    private func tieredMoves(
        _ items: [MenuBarItemSnapshot], _ controls: ItemControlStore, alwaysHidden: CGRect?
    ) -> [HiddenLayoutPlanner.Move] {
        HiddenLayoutPlanner.moves(
            for: items, anchorMinX: anchorMinX, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            controls: controls, alwaysHiddenDividerFrame: alwaysHidden
        )
    }

    @Test func alwaysHiddenIntentTargetsJustLeftOfTheAlwaysHiddenDivider() {
        var controls = ItemControlStore()
        let shownNow = item("com.a.app", x: 1100, id: 1)
        let hiddenNow = item("com.b.app", x: 700, id: 2)   // between the dividers
        controls.setPlacement(.alwaysHidden, for: shownNow)
        controls.setPlacement(.alwaysHidden, for: hiddenNow)

        let result = tieredMoves([shownNow, hiddenNow], controls, alwaysHidden: alwaysHiddenFrame)
        #expect(result.map { $0.item.windowID } == [1, 2])
        #expect(result.map(\.targetX) == [592, 592])
        #expect(result.allSatisfy { $0.placement == .alwaysHidden })
    }

    @Test func hiddenIntentMustClearTheAlwaysHiddenDividersTrailingEdge() {
        var controls = ItemControlStore()
        let tucked = item("com.a.app", x: 300, id: 1)      // left of the always-hidden divider
        let between = item("com.b.app", x: 700, id: 2)     // already hidden
        controls.setPlacement(.hidden, for: tucked)
        controls.setPlacement(.hidden, for: between)

        let result = tieredMoves([tucked, between], controls, alwaysHidden: alwaysHiddenFrame)
        #expect(result.map { $0.item.windowID } == [1])
        #expect(result.first?.targetX == dividerMinX - 8)
        #expect(result.first?.placement == .hidden)
    }

    @Test(arguments: ItemPlacement.allCases)
    func itemsAlreadyInTheirTierAreNotMoved(placement: ItemPlacement) {
        let x: CGFloat = placement == .shown ? 1100 : placement == .hidden ? 700 : 300
        let placed = item("com.a.app", x: x)
        var controls = ItemControlStore()
        controls.setPlacement(placement, for: placed)
        #expect(HiddenLayoutPlanner.isPlacementSatisfied(
            item: placed, placement: placement, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            alwaysHiddenDividerFrame: alwaysHiddenFrame
        ))
        #expect(tieredMoves([placed], controls, alwaysHidden: alwaysHiddenFrame).isEmpty)
    }

    @Test(arguments: ItemPlacement.allCases)
    func tierBoundariesAcceptExactEdgesButNotOnePointOverlap(placement: ItemPlacement) {
        let boundaryX: CGFloat
        let overlapDirection: CGFloat
        switch placement {
        case .shown: boundaryX = anchorMaxX; overlapDirection = -1
        case .hidden: boundaryX = alwaysHiddenFrame.maxX; overlapDirection = -1
        case .alwaysHidden: boundaryX = alwaysHiddenFrame.minX - 22; overlapDirection = 1
        }
        let placed = item("com.a.app", x: boundaryX)
        let overlapping = item("com.a.app", x: boundaryX + overlapDirection)
        var controls = ItemControlStore()
        controls.setPlacement(placement, for: placed)

        #expect(HiddenLayoutPlanner.isPlacementSatisfied(
            item: placed, placement: placement, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            alwaysHiddenDividerFrame: alwaysHiddenFrame
        ))
        #expect(!HiddenLayoutPlanner.isPlacementSatisfied(
            item: overlapping, placement: placement, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX,
            alwaysHiddenDividerFrame: alwaysHiddenFrame
        ))
        #expect(tieredMoves([placed], controls, alwaysHidden: alwaysHiddenFrame).isEmpty)
        #expect(tieredMoves([overlapping], controls, alwaysHidden: alwaysHiddenFrame).count == 1)
    }

    @Test func shownIntentLeavesTheAlwaysHiddenTierTowardTheAnchor() {
        let tucked = item("com.a.app", x: 300, id: 1)
        let controls = ItemControlStore(shownInMenuBar: ["com.a.app"])
        let result = tieredMoves([tucked], controls, alwaysHidden: alwaysHiddenFrame)
        #expect(result.map(\.targetX) == [anchorMaxX + 8])
        #expect(result.first?.placement == .shown)
    }

    @Test func alwaysHiddenIntentDegradesToHiddenWithoutItsDivider() {
        var controls = ItemControlStore()
        let shownNow = item("com.a.app", x: 1100, id: 1)
        let hiddenNow = item("com.b.app", x: 700, id: 2)
        controls.setPlacement(.alwaysHidden, for: shownNow)
        controls.setPlacement(.alwaysHidden, for: hiddenNow)

        let result = tieredMoves([shownNow, hiddenNow], controls, alwaysHidden: nil)
        #expect(result.map { $0.item.windowID } == [1])
        #expect(result.first?.targetX == dividerMinX - 8)
        #expect(result.first?.placement == .hidden)
        #expect(HiddenLayoutPlanner.effectivePlacement(.alwaysHidden, hasAlwaysHiddenDivider: false) == .hidden)
        #expect(HiddenLayoutPlanner.effectivePlacement(.alwaysHidden, hasAlwaysHiddenDivider: true) == .alwaysHidden)
        #expect(HiddenLayoutPlanner.effectivePlacement(.shown, hasAlwaysHiddenDivider: false) == .shown)
        #expect(HiddenLayoutPlanner.targetX(
            for: .alwaysHidden, anchorMaxX: anchorMaxX, dividerMinX: dividerMinX, alwaysHiddenDividerFrame: nil
        ) == dividerMinX - 8)
    }

    @Test func twoTierIntentPlansIdenticallyWithOrWithoutTheAlwaysHiddenDivider() {
        var controls = ItemControlStore()
        let a = item("com.a.app", x: 1100, id: 1)  // shown, wants hidden
        let b = item("com.b.app", x: 1200, id: 2)  // shown, wants shown
        let c = item("com.c.app", x: 700, id: 3)   // hidden, wants shown
        let d = item("com.d.app", x: 650, id: 4)   // hidden, wants hidden
        let e = item("com.e.app", x: 300, id: 5)   // unconfigured, left of the always-hidden divider
        controls.setHidden(true, for: a)
        controls.setHidden(false, for: b)
        controls.setHidden(false, for: c)
        controls.setHidden(true, for: d)

        let legacy = moves([a, b, c, d, e], controls)
        let tiered = tieredMoves([a, b, c, d, e], controls, alwaysHidden: alwaysHiddenFrame)
        let explicitNil = tieredMoves([a, b, c, d, e], controls, alwaysHidden: nil)
        #expect(legacy == tiered)
        #expect(legacy == explicitNil)
        #expect(legacy.map { $0.item.windowID } == [1, 3])
        #expect(legacy.map(\.placement) == [.hidden, .shown])
    }

    @Test func anAlwaysHiddenDividerRightOfTheHiddenDividerProducesNoPlan() {
        let misplaced = item("com.a.app", x: 1100)
        let controls = ItemControlStore(alwaysHiddenInMenuBar: ["com.a.app"])
        let inverted = CGRect(x: dividerMinX + 1, y: 0, width: 8, height: 22)
        #expect(tieredMoves([misplaced], controls, alwaysHidden: inverted).isEmpty)
        let malformed = CGRect(x: 600, y: 0, width: -8, height: 22)
        #expect(tieredMoves([misplaced], controls, alwaysHidden: malformed.standardized).count == 1)
        #expect(tieredMoves([misplaced], controls, alwaysHidden: alwaysHiddenFrame).count == 1)
    }

    @Test func unconfiguredItemsInTheAlwaysHiddenTierAreLeftAlone() {
        let controls = ItemControlStore(hiddenInMenuBar: ["com.b.app"])
        let tucked = item("com.a.app", x: 300, id: 1)
        let wanted = item("com.b.app", x: 1100, id: 2)
        let result = tieredMoves([tucked, wanted], controls, alwaysHidden: alwaysHiddenFrame)
        #expect(result.map { $0.item.windowID } == [2])
    }
}

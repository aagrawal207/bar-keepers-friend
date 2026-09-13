import CoreGraphics
import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct NotchOverflowPlannerTests {

    /// A 14" MacBook-style display: the notch spans x 700...812, so the usable status area starts at 812.
    private let notched = NotchGeometry(
        displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        leftArea: CGRect(x: 0, y: 957, width: 700, height: 25),
        rightArea: CGRect(x: 812, y: 957, width: 700, height: 25)
    )
    private let notchless = NotchGeometry(
        displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), leftArea: nil, rightArea: nil
    )
    private let anchor = CGRect(x: 1000, y: 0, width: 24, height: 24)
    private let divider = CGRect(x: 992, y: 0, width: 8, height: 24)
    private let itemWidth: CGFloat = 30

    private func item(
        _ id: CGWindowID, x: CGFloat, width: CGFloat = 30, y: CGFloat = 0, height: CGFloat = 24,
        owner: String? = nil, pid: pid_t = 1, title: String? = nil
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id, ownerPID: pid, ownerBundleID: owner ?? "test.app.\(id)", title: title,
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    /// `count` hidden items packed leftwards from the divider; window ids 100... from the divider outwards.
    private func hiddenItems(_ count: Int) -> [MenuBarItemSnapshot] {
        (0..<count).map { index in
            item(CGWindowID(100 + index), x: divider.minX - itemWidth * CGFloat(index + 1))
        }
    }

    /// `count` shown items packed rightwards from the anchor; window ids 1... nearest the anchor first.
    private func shownItems(_ count: Int) -> [MenuBarItemSnapshot] {
        (0..<count).map { index in
            item(CGWindowID(1 + index), x: anchor.maxX + itemWidth * CGFloat(index))
        }
    }

    private func layout(hidden: [MenuBarItemSnapshot], shown: [MenuBarItemSnapshot]) -> NotchOverflowPlanner.RevealedLayout {
        NotchOverflowPlanner.RevealedLayout(hidden: hidden, shown: shown, anchor: anchor, divider: divider, alwaysHiddenDivider: nil)
    }

    private func plan(
        hidden: [MenuBarItemSnapshot], shown: [MenuBarItemSnapshot], notch: NotchGeometry? = nil,
        immovable: (MenuBarItemSnapshot) -> Bool = { _ in false }
    ) -> NotchOverflowPlanner.Plan {
        NotchOverflowPlanner.plan(layout: layout(hidden: hidden, shown: shown), notch: notch ?? notched, immovable: immovable)
    }

    // MARK: - Mode

    @Test func modeRawValuesAndDefaultOrderArePinned() throws {
        #expect(NotchOverflowMode.never.rawValue == "never")
        #expect(NotchOverflowMode.whenNeeded.rawValue == "whenNeeded")
        #expect(NotchOverflowMode.allCases == [.never, .whenNeeded])
        let encoded = try JSONEncoder().encode([NotchOverflowMode.never, .whenNeeded])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"never\",\"whenNeeded\"]")
        #expect(try JSONDecoder().decode([NotchOverflowMode].self, from: encoded) == [.never, .whenNeeded])
    }

    // MARK: - Deficit

    @Test func sixPackedItemsEndExactlyAtTheNotchEdgeAndNeedNoRoom() {
        let hidden = hiddenItems(6)
        #expect(hidden.last?.frame.minX == 812)
        #expect(NotchOverflowPlanner.deficit(hidden: hidden, notch: notched) == 0)
        #expect(!NotchOverflowPlanner.needsRoom(hidden: hidden, notch: notched))
    }

    @Test func oneItemPastTheEdgeNeedsExactlyItsOverhang() {
        let hidden = hiddenItems(7)
        #expect(hidden.last?.frame.minX == 782)
        #expect(NotchOverflowPlanner.deficit(hidden: hidden, notch: notched) == 30)
        #expect(NotchOverflowPlanner.needsRoom(hidden: hidden, notch: notched))
    }

    @Test func anItemStraddlingTheEdgeCountsEvenThoughItsMidpointIsClear() {
        let straddling = [item(100, x: 800)]
        #expect(!notched.isUnderNotch(midX: straddling[0].frame.midX))
        #expect(NotchOverflowPlanner.deficit(hidden: straddling, notch: notched) == 12)
    }

    @Test func itemsPushedBeyondTheNotchIntoTheLeftAreaStillCount() {
        let farLeft = [item(100, x: 100), item(101, x: 900)]
        #expect(NotchOverflowPlanner.deficit(hidden: farLeft, notch: notched) == 712)
    }

    @Test func notchlessDisplayAndEmptySectionNeverNeedRoom() {
        #expect(NotchOverflowPlanner.deficit(hidden: hiddenItems(20), notch: notchless) == 0)
        #expect(!NotchOverflowPlanner.needsRoom(hidden: hiddenItems(20), notch: notchless))
        #expect(NotchOverflowPlanner.deficit(hidden: [], notch: notched) == 0)
        let nonFinite = [item(100, x: .nan)]
        #expect(NotchOverflowPlanner.deficit(hidden: nonFinite, notch: notched) == 0)
    }

    // MARK: - Plan

    @Test func noNotchYieldsAnEmptyPlanEvenWithClippedGeometry() {
        let result = plan(hidden: hiddenItems(9), shown: shownItems(3), notch: notchless)
        #expect(result == .empty)
        #expect(result.isEmpty)
        #expect(result.isSatisfied)
    }

    @Test func enoughRoomYieldsAnEmptyPlan() {
        let result = plan(hidden: hiddenItems(6), shown: shownItems(3))
        #expect(result == .empty)
        #expect(result.victimWindowIDs.isEmpty)
    }

    @Test func aDeficitExactlyMatchedByOneVictimTakesOnlyThatVictim() {
        let result = plan(hidden: hiddenItems(7), shown: shownItems(3))
        #expect(result.victimWindowIDs == [1])
        #expect(result.freedWidth == 30)
        #expect(result.requiredWidth == 30)
        #expect(result.deficit == 0)
        #expect(result.isSatisfied)
        #expect(!result.isEmpty)
    }

    @Test func multipleVictimsAreTakenNearestTheAnchorFirstAndStopOnceEnoughIsFreed() {
        // 9 hidden: leftmost at 722, deficit 90 = exactly three 30pt victims out of five.
        let result = plan(hidden: hiddenItems(9), shown: shownItems(5))
        #expect(result.victimWindowIDs == [1, 2, 3])
        #expect(result.freedWidth == 90)
        #expect(result.requiredWidth == 90)
        #expect(result.deficit == 0)
    }

    @Test func aPartialOverhangRoundsUpToWholeVictims() {
        // Leftmost at 782 minus a 10pt straggler: deficit 40 needs two 30pt victims, freeing 60.
        let hidden = hiddenItems(7) + [item(200, x: 772, width: 10)]
        let result = plan(hidden: hidden, shown: shownItems(5))
        #expect(result.requiredWidth == 40)
        #expect(result.victimWindowIDs == [1, 2])
        #expect(result.freedWidth == 60)
        #expect(result.deficit == 0)
    }

    @Test func immovableAndOwnItemsAreSkippedInFavorOfTheNextMovableNeighbor() {
        let controlCenter = item(1, x: anchor.maxX, owner: "Control Center", pid: 500)
        let group = item(2, x: anchor.maxX + 30, title: "BKFGroup-ABCD")
        let movable = item(3, x: anchor.maxX + 60)
        let farther = item(4, x: anchor.maxX + 90)
        let result = plan(hidden: hiddenItems(7), shown: [controlCenter, group, movable, farther]) {
            ImmovableItems.isImmovable($0, immovablePIDs: [500]) || HiddenItemsResolver.isOwnControlItem($0)
        }
        #expect(result.victimWindowIDs == [3])
        #expect(result.freedWidth == 30)
        #expect(result.deficit == 0)
    }

    @Test func nothingMovableLeavesTheWholeDeficitOutstanding() {
        let result = plan(hidden: hiddenItems(8), shown: shownItems(4)) { _ in true }
        #expect(result.victims.isEmpty)
        #expect(result.freedWidth == 0)
        #expect(result.requiredWidth == 60)
        #expect(result.deficit == 60)
        #expect(!result.isSatisfied)
        #expect(result != .empty)
    }

    @Test func tooLittleMovableWidthTakesEveryMovableVictimAndReportsTheRemainder() {
        let result = plan(hidden: hiddenItems(10), shown: shownItems(2))
        #expect(result.victimWindowIDs == [1, 2])
        #expect(result.freedWidth == 60)
        #expect(result.requiredWidth == 120)
        #expect(result.deficit == 60)
        #expect(!result.isSatisfied)
    }

    @Test func tuckAndRestoreSequencesPreserveTheOriginalArrangement() {
        let result = plan(hidden: hiddenItems(9), shown: shownItems(5))
        #expect(result.tuckSequence.map(\.windowID) == [3, 2, 1])
        #expect(result.restoreSequence.map(\.windowID) == [1, 2, 3])
        #expect(NotchOverflowPlanner.Plan.empty.tuckSequence.isEmpty)
        #expect(NotchOverflowPlanner.Plan.empty.restoreSequence.isEmpty)
    }

    // MARK: - Classification

    @Test func classificationSplitsTheDisplayIntoHiddenGapAndShown() {
        let hidden = hiddenItems(3)
        let inGap = item(50, x: 996, width: 4)
        let shown = shownItems(2)
        let result = NotchOverflowPlanner.classify(
            items: shown.reversed() + [inGap] + hidden.reversed(),
            anchor: anchor, divider: divider, alwaysHiddenDivider: nil, notch: notched
        )
        #expect(result.hidden.map(\.windowID) == [102, 101, 100])
        #expect(result.shown.map(\.windowID) == [1, 2])
        #expect(result.anchor == anchor)
        #expect(result.divider == divider)
        #expect(result.alwaysHiddenDivider == nil)
    }

    @Test func classificationDropsControlsMirrorsImplausibleAndExcludedWindows() {
        let ownDivider = item(90, x: 992, width: 8, title: "BKFHidden")
        let ownAnchor = item(91, x: 1000, width: 24, title: "BKFAnchor")
        let widget = item(92, x: anchor.maxX + 60, title: "BKFWidget-1234")
        let excluded = item(93, x: anchor.maxX + 90)
        let mirror = item(94, x: 1512 + 1100)
        let popover = item(95, x: 700, width: 450, height: 800)
        let belowBar = item(96, x: 800, y: 916)
        let result = NotchOverflowPlanner.classify(
            items: hiddenItems(2) + shownItems(2) + [ownDivider, ownAnchor, widget, excluded, mirror, popover, belowBar],
            anchor: anchor, divider: divider, alwaysHiddenDivider: nil, notch: notched,
            excludingWindowIDs: [93]
        )
        #expect(result.hidden.map(\.windowID) == [101, 100])
        #expect(result.shown.map(\.windowID) == [1, 2])
    }

    @Test func classificationHonorsAStackedDisplayMenuBarTop() {
        let stackedTop: CGFloat = -1080
        let items = [item(100, x: 900, y: stackedTop), item(1, x: anchor.maxX, y: stackedTop)]
        let onStacked = NotchOverflowPlanner.classify(
            items: items, anchor: anchor, divider: divider, alwaysHiddenDivider: nil, notch: notched,
            displayMenuBarTop: stackedTop
        )
        #expect(onStacked.hidden.map(\.windowID) == [100])
        #expect(onStacked.shown.map(\.windowID) == [1])
        let onPrimary = NotchOverflowPlanner.classify(
            items: items, anchor: anchor, divider: divider, alwaysHiddenDivider: nil, notch: notched
        )
        #expect(onPrimary.hidden.isEmpty)
        #expect(onPrimary.shown.isEmpty)
    }

    @Test func alwaysHiddenItemsLeftOfTheirDividerAreNotPartOfTheHiddenSection() {
        // Both tiers revealed: the natural-width tier divider abuts the leftmost hidden item.
        let hidden = hiddenItems(3)
        let tierDivider = CGRect(x: hidden.last!.frame.minX, y: 0, width: 0, height: 24)
        let alwaysHidden = item(300, x: tierDivider.minX - 30)
        let result = NotchOverflowPlanner.classify(
            items: hidden + [alwaysHidden], anchor: anchor, divider: divider,
            alwaysHiddenDivider: tierDivider, notch: notched
        )
        #expect(result.hidden.map(\.windowID) == [102, 101, 100])
        #expect(result.alwaysHiddenDivider == tierDivider)
        // Without a tier boundary the whole revealed run left of the divider is the section.
        let withoutTier = NotchOverflowPlanner.classify(
            items: hidden + [alwaysHidden], anchor: anchor, divider: divider,
            alwaysHiddenDivider: nil, notch: notched
        )
        #expect(withoutTier.hidden.map(\.windowID) == [300, 102, 101, 100])
        // An expanded tier divider pushes its items off the display, where they never count.
        let expanded = CGRect(x: tierDivider.minX - 1712, y: 0, width: 1712, height: 24)
        let offDisplay = NotchOverflowPlanner.classify(
            items: hidden + [item(301, x: expanded.minX - 30)], anchor: anchor, divider: divider,
            alwaysHiddenDivider: expanded, notch: notched
        )
        #expect(offDisplay.hidden.map(\.windowID) == [102, 101, 100])
    }

    @Test func classificationCollapsesColocatedBackingWindows() {
        let glyph = item(1, x: anchor.maxX)
        let backing = item(2, x: anchor.maxX + 1, width: 28)
        let hiddenGlyph = item(100, x: 900)
        let hiddenBacking = item(101, x: 901, width: 28)
        let result = NotchOverflowPlanner.classify(
            items: [glyph, backing, hiddenGlyph, hiddenBacking], anchor: anchor, divider: divider,
            alwaysHiddenDivider: nil, notch: notched
        )
        #expect(result.shown.map(\.windowID) == [1])
        #expect(result.hidden.map(\.windowID) == [100])
    }

    @Test func degenerateDisplayFrameClassifiesNothing() {
        let broken = NotchGeometry(displayFrame: CGRect(x: 0, y: 0, width: 0, height: 0), leftArea: nil, rightArea: nil)
        let result = NotchOverflowPlanner.classify(
            items: hiddenItems(2) + shownItems(2), anchor: anchor, divider: divider, alwaysHiddenDivider: nil, notch: broken
        )
        #expect(result.hidden.isEmpty)
        #expect(result.shown.isEmpty)
    }

    // MARK: - Reveal detection and postconditions

    @Test func dividerRevealDistinguishesNaturalWidthFromExpansion() {
        let display = notched.displayFrame
        #expect(NotchOverflowPlanner.isDividerRevealed(divider, displayFrame: display))
        #expect(NotchOverflowPlanner.isDividerRevealed(CGRect(x: 1000, y: 0, width: 0, height: 24), displayFrame: display))
        let expanded = CGRect(x: 1000 - 1712, y: 0, width: 1712, height: 24)
        #expect(!NotchOverflowPlanner.isDividerRevealed(expanded, displayFrame: display))
        #expect(!NotchOverflowPlanner.isDividerRevealed(CGRect(x: 1600, y: 0, width: 8, height: 24), displayFrame: display))
        #expect(!NotchOverflowPlanner.isDividerRevealed(CGRect(x: CGFloat.nan, y: 0, width: 8, height: 24), displayFrame: display))
        #expect(!NotchOverflowPlanner.isDividerRevealed(divider, displayFrame: .zero))
    }

    @Test func dropPositionsMirrorTheHiddenLayoutPlannerMargins() {
        let reference = CGRect(x: 812, y: 0, width: 30, height: 24)
        #expect(NotchOverflowPlanner.tuckTargetX(leftOf: reference) == 812 - HiddenLayoutPlanner.hiddenMargin)
        #expect(NotchOverflowPlanner.restoreTargetX(rightOf: anchor) == anchor.maxX + HiddenLayoutPlanner.shownMargin)
    }

    @Test func tuckPostconditionRequiresTheItemLeftOfItsReferenceInsideTheSection() {
        let reference = CGRect(x: 812, y: 0, width: 30, height: 24)
        let tucked = item(1, x: 782)
        #expect(NotchOverflowPlanner.isTucked(tucked, leftOf: reference, dividerMinX: divider.minX, alwaysHiddenDividerMaxX: nil))
        #expect(NotchOverflowPlanner.isTucked(tucked, leftOf: reference, dividerMinX: divider.minX, alwaysHiddenDividerMaxX: 782))
        // Overshot into the always-hidden tier.
        #expect(!NotchOverflowPlanner.isTucked(tucked, leftOf: reference, dividerMinX: divider.minX, alwaysHiddenDividerMaxX: 790))
        // Still overlapping the reference, or never left the shown side.
        #expect(!NotchOverflowPlanner.isTucked(item(1, x: 790), leftOf: reference, dividerMinX: divider.minX, alwaysHiddenDividerMaxX: nil))
        #expect(!NotchOverflowPlanner.isTucked(item(1, x: 1030), leftOf: reference, dividerMinX: divider.minX, alwaysHiddenDividerMaxX: nil))
    }

    @Test func restorePostconditionRequiresTheItemRightOfBothReferenceAndAnchor() {
        #expect(NotchOverflowPlanner.isRestored(item(1, x: 1024), rightOf: anchor.maxX, anchorMaxX: anchor.maxX))
        #expect(NotchOverflowPlanner.isRestored(item(1, x: 1054), rightOf: 1054, anchorMaxX: anchor.maxX))
        #expect(!NotchOverflowPlanner.isRestored(item(1, x: 1030), rightOf: 1054, anchorMaxX: anchor.maxX))
        #expect(!NotchOverflowPlanner.isRestored(item(1, x: 1016), rightOf: anchor.maxX, anchorMaxX: anchor.maxX))
        #expect(!NotchOverflowPlanner.isRestored(item(1, x: 782), rightOf: anchor.maxX, anchorMaxX: anchor.maxX))
    }

    // MARK: - Left neighbor

    @Test func leftNeighborIsTheAbuttingShownItemOrTheAnchor() {
        let anchorItem = item(90, x: anchor.minX, width: anchor.width, title: "BKFAnchor")
        let group = item(2, x: anchor.maxX + 30, title: "BKFGroup-1234")
        let shown = shownItems(3).map { $0.windowID == 2 ? group : $0 }
        let items = hiddenItems(2) + [anchorItem] + shown
        #expect(NotchOverflowPlanner.leftNeighbor(of: shown[0], in: items, anchorWindowID: 90)?.windowID == 90)
        #expect(NotchOverflowPlanner.leftNeighbor(of: shown[1], in: items, anchorWindowID: 90)?.windowID == 1)
        // Own group and widget icons are real neighbors in the shown section.
        #expect(NotchOverflowPlanner.leftNeighbor(of: shown[2], in: items, anchorWindowID: 90)?.windowID == 2)
    }

    @Test func leftNeighborIgnoresBackingWindowsGapsAndItemsOutsideTheShownSection() {
        let anchorItem = item(90, x: anchor.minX, width: anchor.width, title: "BKFAnchor")
        let first = item(1, x: anchor.maxX)
        let backing = item(11, x: anchor.maxX + 31, width: 28)
        let second = item(2, x: anchor.maxX + 30)
        let popover = item(12, x: anchor.maxX + 30, width: 450, height: 800)
        let items = hiddenItems(2) + [anchorItem, first, backing, second, popover, item(3, x: anchor.maxX + 60)]
        #expect(NotchOverflowPlanner.leftNeighbor(of: second, in: items, anchorWindowID: 90)?.windowID == 1)
        #expect(NotchOverflowPlanner.leftNeighbor(of: items.last!, in: items, anchorWindowID: 90)?.windowID == 2)
        // Gaps do not matter: the nearest shown-side window on the left is the neighbor.
        #expect(NotchOverflowPlanner.leftNeighbor(of: item(4, x: anchor.maxX + 200), in: items, anchorWindowID: 90)?.windowID == 3)
        // A hidden item, the anchor itself, and a bar without an anchor have no shown-side neighbor.
        #expect(NotchOverflowPlanner.leftNeighbor(of: hiddenItems(2)[0], in: items, anchorWindowID: 90) == nil)
        #expect(NotchOverflowPlanner.leftNeighbor(of: anchorItem, in: items, anchorWindowID: 90) == nil)
        #expect(NotchOverflowPlanner.leftNeighbor(of: second, in: items, anchorWindowID: 77) == nil)
    }
}

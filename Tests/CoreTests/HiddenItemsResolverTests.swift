import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct HiddenItemsResolverTests {

    private func item(id: CGWindowID, x: CGFloat, w: CGFloat = 24, h: CGFloat = 22, bundle: String? = nil, title: String? = nil) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id,
            ownerPID: 1,
            ownerBundleID: bundle,
            title: title,
            frame: CGRect(x: x, y: 0, width: w, height: h)
        )
    }

    @Test func returnsOnlyItemsLeftOfAnchor() {
        let items = [
            item(id: 1, x: 100),   // hidden (left of anchor at 1000)
            item(id: 2, x: 500),   // hidden
            item(id: 3, x: 1100),  // visible (right of anchor)
        ]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000)
        #expect(hidden.map(\.windowID) == [1, 2])
    }

    @Test func itemStraddlingTheAnchorIsNotHidden() {
        // maxX must be <= anchorMinX; an item crossing the anchor edge stays visible.
        let items = [item(id: 1, x: 990, w: 24)] // spans 990...1014, maxX > 1000
        #expect(HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000).isEmpty)
    }

    @Test func excludesOwnControlItems() {
        let items = [item(id: 1, x: 100), item(id: 99, x: 200)]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000, excludingControlItems: [99])
        #expect(hidden.map(\.windowID) == [1])
    }

    @Test func excludesRawSafeImmovableSystemItems() {
        // The resolver runs on RAW snapshots, so it uses the raw-safe immovability predicate:
        // a reverse-DNS id (com.apple.controlcenter) is still a trustworthy signal and is dropped.
        let items = [
            item(id: 1, x: 100, bundle: "com.dropbox.Dropbox"),
            item(id: 2, x: 200, bundle: "com.apple.controlcenter"),
        ]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000)
        #expect(hidden.map(\.windowID) == [1])
    }

    @Test func keepsThirdPartyItemsRawLabeledControlCenter() {
        // Regression (the 7-missing-items bug, commit 02a7cc8): on Tahoe (FB18327911) MANY genuine
        // third-party items report the bogus blanket owner "Control Center" in the RAW enumeration
        // the resolver sees, until attribution corrects them. The resolver must NOT drop them via
        // the display-name denylist — doing so left 7 real items pushed off-screen yet absent from
        // the bar ("No hidden items"). The real Control Center is excluded by POSITION (right of the
        // anchor), and the display-name denylist still applies on ATTRIBUTED snapshots in the move
        // and picker paths.
        let items = [
            item(id: 1, x: 100, bundle: "Control Center"),   // really a third-party item (raw label)
            item(id: 2, x: 200, bundle: "Control Center"),
            item(id: 3, x: 1100, bundle: "Control Center"),  // real CC, right of anchor at 1000
        ]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000)
        #expect(hidden.map(\.windowID) == [1, 2])
    }

    @Test func ordersLeftToRight() {
        let items = [item(id: 1, x: 400), item(id: 2, x: 100), item(id: 3, x: 250)]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000)
        #expect(hidden.map(\.windowID) == [2, 3, 1])
    }

    @Test func excludesOwnControlItemsByName() {
        // On Tahoe our items report owner=Control Center, so window-id exclusion can be
        // stale; the name prefix is the robust signal.
        let items = [
            item(id: 1, x: 100, title: "Dropbox"),
            item(id: 2, x: 200, title: "BKFHidden"),    // our divider
            item(id: 3, x: 300, title: "BKFAnchor"),     // our anchor
        ]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000)
        #expect(hidden.map(\.windowID) == [1])
    }

    @Test func isOwnControlItemMatchesPrefix() {
        #expect(HiddenItemsResolver.isOwnControlItem(item(id: 1, x: 0, title: "BKFHidden")))
        #expect(!HiddenItemsResolver.isOwnControlItem(item(id: 2, x: 0, title: "Slack")))
        #expect(!HiddenItemsResolver.isOwnControlItem(item(id: 3, x: 0, title: nil)))
    }

    @Test func handlesOffScreenNegativeXItems() {
        // When the divider has pushed items off-screen to negative x, they're still left
        // of the anchor and must be picked up.
        let items = [item(id: 1, x: -200), item(id: 2, x: -50)]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000)
        #expect(hidden.map(\.windowID) == [1, 2])
    }

    @Test func deduplicatesCoLocatedWindowsKeepingFirst() {
        // Two windows backing the same visible icon share a midpoint; only the first survives.
        let items = [
            item(id: 1, x: 100, w: 24),  // midX 112
            item(id: 2, x: 101, w: 22),  // midX 112 — duplicate of #1, dropped
            item(id: 3, x: 200, w: 24),  // distinct
        ]
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(items)
        #expect(deduped.map(\.windowID) == [1, 3])
    }

    @Test func keepsDistinctAdjacentNeighborsThatOverlapSlightly() {
        // 24 pt apart, 26 pt wide → frames overlap 2 pt, but midpoints differ by 24 > 7,
        // so genuine neighbours must NOT be merged.
        let items = [item(id: 1, x: 100, w: 26), item(id: 2, x: 124, w: 26)]
        let deduped = HiddenItemsResolver.deduplicateByMidXProximity(items)
        #expect(deduped.map(\.windowID) == [1, 2])
    }

    @Test func deduplicationPreservesOrderAndIsIdempotent() {
        let items = [item(id: 1, x: 50), item(id: 2, x: 200), item(id: 3, x: 350)]
        let once = HiddenItemsResolver.deduplicateByMidXProximity(items)
        let twice = HiddenItemsResolver.deduplicateByMidXProximity(once)
        #expect(once.map(\.windowID) == [1, 2, 3])
        #expect(twice == once)
    }

    @Test func rejectsTallPopupPanelWindow() {
        // A 450x800 popup panel parked at the status layer is not a menu bar glyph.
        let items = [item(id: 61264, x: 426, w: 450, h: 800)]
        #expect(HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 2000).isEmpty)
    }

    @Test func rejectsOneByOneJunkWindow() {
        let items = [item(id: 163562, x: 755, w: 1, h: 1)]
        #expect(HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 2000).isEmpty)
    }

    @Test func keepsNormalAndNotchHeightIcons() {
        // 33pt normal item and 24pt notch item are both real glyphs.
        let items = [item(id: 13745, x: 930, w: 30, h: 33), item(id: 13833, x: 1094, w: 24, h: 24)]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 2000)
        #expect(hidden.map(\.windowID) == [13745, 13833])
    }

    @Test func keepsWideButMenuBarTallItem() {
        // Now Playing / date widgets are wide but menu-bar tall — must NOT be filtered.
        let items = [item(id: 999, x: 1100, w: 200, h: 33)]
        #expect(HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 2000).map(\.windowID) == [999])
    }

    @Test func isPlausibleMenuBarItemBoundaries() {
        #expect(HiddenItemsResolver.isPlausibleMenuBarItem(item(id: 1, x: 0, w: 24, h: 24)))
        #expect(!HiddenItemsResolver.isPlausibleMenuBarItem(item(id: 2, x: 0, w: 1, h: 1)))
        #expect(!HiddenItemsResolver.isPlausibleMenuBarItem(item(id: 3, x: 0, w: 450, h: 800)))
    }

    @Test func rejectsWindowBelowTheMenuBar() {
        // A menu-bar-sized window far down the screen (e.g. an app's notification window at
        // y≈916 sharing the status layer) is not a menu bar item.
        let lowItem = MenuBarItemSnapshot(
            windowID: 13833, ownerPID: 1, ownerBundleID: nil, title: nil,
            frame: CGRect(x: 1094, y: 916, width: 24, height: 24)
        )
        #expect(!HiddenItemsResolver.isPlausibleMenuBarItem(lowItem))
        #expect(HiddenItemsResolver.hiddenItems(from: [lowItem], leftOfAnchorX: 2000).isEmpty)
    }

    @Test func keepsItemAtTopOfScreen() {
        let topItem = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: nil, title: nil,
            frame: CGRect(x: 100, y: 0, width: 30, height: 33)
        )
        #expect(HiddenItemsResolver.isPlausibleMenuBarItem(topItem))
    }

    @Test func keepsItemAtTopOfADisplayStackedBelowThePrimary() {
        // A display positioned BELOW the primary has its menu bar at a large global y (e.g. the
        // primary is 982 tall, so the lower display's bar sits at y≈982). Without a per-display
        // top, an absolute `minY ≤ 40` test rejects every legitimate item there. With the display's
        // menu-bar top supplied, the item reads as plausible (and a far-down window still doesn't).
        let item = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: nil, title: nil,
            frame: CGRect(x: 100, y: 982, width: 30, height: 33)
        )
        #expect(!HiddenItemsResolver.isPlausibleMenuBarItem(item)) // absolute default → wrongly rejected
        #expect(HiddenItemsResolver.isPlausibleMenuBarItem(item, displayMenuBarTop: 982)) // correct
    }

    @Test func keepsItemAtTopOfADisplayStackedAboveThePrimary() {
        // A display ABOVE the primary has a NEGATIVE global menu-bar y. The item sits flush at that
        // negative top; the relative test keeps it.
        let item = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: nil, title: nil,
            frame: CGRect(x: 100, y: -1080, width: 30, height: 33)
        )
        #expect(HiddenItemsResolver.isPlausibleMenuBarItem(item, displayMenuBarTop: -1080))
    }

    @Test func stillRejectsTransientWindowFarBelowItsDisplaysMenuBar() {
        // The transient-window guard must survive the relative test: a notification window 900pt
        // below ITS display's menu-bar top is still rejected, even on a stacked display.
        let lowItem = MenuBarItemSnapshot(
            windowID: 1, ownerPID: 1, ownerBundleID: nil, title: nil,
            frame: CGRect(x: 100, y: 982 + 900, width: 30, height: 33)
        )
        #expect(!HiddenItemsResolver.isPlausibleMenuBarItem(lowItem, displayMenuBarTop: 982))
    }

    // MARK: - Always Hidden tier

    /// Always-hidden divider 600...608, hidden divider leading edge 1000.
    private var tieredItems: [MenuBarItemSnapshot] {
        [
            item(id: 1, x: 100),                        // always hidden
            item(id: 2, x: 576),                        // always hidden, flush against the divider
            item(id: 3, x: 590),                        // straddles the always-hidden divider
            item(id: 4, x: 608),                        // hidden, flush against the divider's trailing edge
            item(id: 5, x: 800),                        // hidden
            item(id: 6, x: 1100),                       // shown
            item(id: 7, x: 400, title: "BKFAlwaysHidden"),
        ]
    }

    @Test func hiddenSectionExcludesItemsLeftOfTheAlwaysHiddenDivider() {
        let hidden = HiddenItemsResolver.hiddenItems(from: tieredItems, leftOfAnchorX: 1000, rightOfAlwaysHiddenX: 608)
        #expect(hidden.map(\.windowID) == [4, 5])
        let alwaysHidden = HiddenItemsResolver.hiddenItems(from: tieredItems, leftOfAnchorX: 600)
        #expect(alwaysHidden.map(\.windowID) == [1, 2])
        let merged = HiddenItemsResolver.hiddenItems(from: tieredItems, leftOfAnchorX: 1000)
        #expect(merged.map(\.windowID) == [1, 2, 3, 4, 5])
        #expect(HiddenItemsResolver.hiddenItems(from: tieredItems, leftOfAnchorX: 1000, rightOfAlwaysHiddenX: nil) == merged)
    }

    @Test func observedPlacementFollowsTheTrailingEdgeRule() {
        let placements = tieredItems.filter { $0.windowID != 7 }.map {
            HiddenItemsResolver.observedPlacement(of: $0, hiddenBoundaryX: 1000, alwaysHiddenBoundaryX: 600)
        }
        #expect(placements == [.alwaysHidden, .alwaysHidden, .hidden, .hidden, .hidden, .shown])
        let twoTier = tieredItems.filter { $0.windowID != 7 }.map {
            HiddenItemsResolver.observedPlacement(of: $0, hiddenBoundaryX: 1000, alwaysHiddenBoundaryX: nil)
        }
        #expect(twoTier == [.hidden, .hidden, .hidden, .hidden, .hidden, .shown])
    }
}

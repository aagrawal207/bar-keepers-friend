import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct HiddenItemsResolverTests {

    private func item(id: CGWindowID, x: CGFloat, w: CGFloat = 24, bundle: String? = nil, title: String? = nil) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id,
            ownerPID: 1,
            ownerBundleID: bundle,
            title: title,
            frame: CGRect(x: x, y: 0, width: w, height: 22)
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

    @Test func excludesImmovableSystemItems() {
        let items = [
            item(id: 1, x: 100, bundle: "com.dropbox.Dropbox"),
            item(id: 2, x: 200, bundle: "com.apple.controlcenter"),
        ]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, leftOfAnchorX: 1000)
        #expect(hidden.map(\.windowID) == [1])
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
}

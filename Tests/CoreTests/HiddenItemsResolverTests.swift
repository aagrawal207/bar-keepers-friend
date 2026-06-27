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

    @Test func returnsOnlyItemsFullyOffScreenLeft() {
        let items = [
            item(id: 1, x: -100),   // hidden (off-screen left)
            item(id: 2, x: -30),    // hidden
            item(id: 3, x: 50),     // visible
        ]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, visibleMinX: 0)
        #expect(hidden.map(\.windowID) == [1, 2])
    }

    @Test func itemStraddlingTheEdgeIsNotHidden() {
        // maxX must be <= visibleMinX; an item crossing x=0 is still partly visible.
        let items = [item(id: 1, x: -10, w: 24)] // spans -10...14, maxX=14 > 0
        #expect(HiddenItemsResolver.hiddenItems(from: items, visibleMinX: 0).isEmpty)
    }

    @Test func excludesOwnControlItems() {
        let items = [item(id: 1, x: -100), item(id: 99, x: -50)]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, visibleMinX: 0, excludingControlItems: [99])
        #expect(hidden.map(\.windowID) == [1])
    }

    @Test func excludesImmovableSystemItems() {
        let items = [
            item(id: 1, x: -100, bundle: "com.dropbox.Dropbox"),
            item(id: 2, x: -60, bundle: "com.apple.controlcenter"),
        ]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, visibleMinX: 0)
        #expect(hidden.map(\.windowID) == [1])
    }

    @Test func ordersLeftToRight() {
        let items = [item(id: 1, x: -40), item(id: 2, x: -120), item(id: 3, x: -80)]
        let hidden = HiddenItemsResolver.hiddenItems(from: items, visibleMinX: 0)
        #expect(hidden.map(\.windowID) == [2, 3, 1])
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct ItemControlStoreTests {

    /// Builds a snapshot with a given bundle id (the control key) and a midX, so ordering tests
    /// can express positional left-to-right order via the x coordinate.
    private func item(_ bundleID: String?, x: CGFloat = 0, id: CGWindowID = 1) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id,
            ownerPID: 1,
            ownerBundleID: bundleID,
            title: nil,
            frame: CGRect(x: x, y: 0, width: 22, height: 22)
        )
    }

    // MARK: - Key derivation

    @Test func keyIsBundleIDWhenPresent() {
        #expect(ItemControlStore.key(for: item("com.maccy.Maccy")) == "com.maccy.Maccy")
    }

    @Test func keyIsNilWithoutBundleID() {
        #expect(ItemControlStore.key(for: item(nil)) == nil)
        #expect(ItemControlStore.key(for: item("")) == nil)
    }

    // MARK: - Suppression

    @Test func suppressionRoundTrips() {
        var store = ItemControlStore()
        let maccy = item("com.maccy.Maccy")
        #expect(store.isSuppressed(maccy) == false)
        store.setSuppressed(true, for: maccy)
        #expect(store.isSuppressed(maccy) == true)
        store.setSuppressed(false, for: maccy)
        #expect(store.isSuppressed(maccy) == false)
    }

    @Test func suppressionNoOpForKeylessItem() {
        var store = ItemControlStore()
        store.setSuppressed(true, for: item(nil))
        #expect(store.suppressedFromBar.isEmpty)
        #expect(store.isSuppressed(item(nil)) == false)
    }

    // MARK: - Order

    @Test func orderIndexRoundTripsAndClears() {
        var store = ItemControlStore()
        let item = item("a")
        #expect(store.orderIndex(for: item) == nil)
        store.setOrderIndex(3, for: item)
        #expect(store.orderIndex(for: item) == 3)
        store.setOrderIndex(nil, for: item)
        #expect(store.orderIndex(for: item) == nil)
    }

    // MARK: - Codable

    @Test func codableRoundTrip() throws {
        var store = ItemControlStore()
        store.setSuppressed(true, for: item("a"))
        store.setOrderIndex(2, for: item("b"))
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ItemControlStore.self, from: data)
        #expect(decoded == store)
    }

    // MARK: - visibleBarItems (the load-bearing filter)

    @Test func visibleBarItemsDropsSuppressed() {
        var store = ItemControlStore()
        store.setSuppressed(true, for: item("b"))
        let positional = [item("a", x: 0), item("b", x: 30), item("c", x: 60)]
        let visible = ItemControlStore.visibleBarItems(from: positional, controls: store)
        #expect(visible.map(\.ownerBundleID) == ["a", "c"])
    }

    @Test func visibleBarItemsKeepsPositionalOrderWhenNoExplicitOrder() {
        let store = ItemControlStore()
        let positional = [item("a", x: 0), item("b", x: 30), item("c", x: 60)]
        let visible = ItemControlStore.visibleBarItems(from: positional, controls: store)
        #expect(visible.map(\.ownerBundleID) == ["a", "b", "c"])
    }

    @Test func explicitlyOrderedItemsSortFirstByIndex() {
        var store = ItemControlStore()
        // Pin c to 0 and a to 1; b is unpinned and should fall after both, in positional order.
        store.setOrderIndex(0, for: item("c"))
        store.setOrderIndex(1, for: item("a"))
        let positional = [item("a", x: 0), item("b", x: 30), item("c", x: 60)]
        let visible = ItemControlStore.visibleBarItems(from: positional, controls: store)
        #expect(visible.map(\.ownerBundleID) == ["c", "a", "b"])
    }

    @Test func equalOrderIndicesPreserveInputOrder() {
        var store = ItemControlStore()
        store.setOrderIndex(0, for: item("a"))
        store.setOrderIndex(0, for: item("b"))
        // a precedes b in the input, so a stable sort must keep a before b.
        let positional = [item("a", x: 0), item("b", x: 30)]
        let visible = ItemControlStore.visibleBarItems(from: positional, controls: store)
        #expect(visible.map(\.ownerBundleID) == ["a", "b"])
    }

    @Test func suppressionAppliesToAllItemsSharingABundleID() {
        // Two items from one app share a key, so suppressing the key suppresses both — the
        // documented per-app granularity trade-off, asserted so it can't regress silently.
        var store = ItemControlStore()
        store.setSuppressed(true, for: item("dup"))
        let positional = [item("dup", x: 0, id: 1), item("dup", x: 30, id: 2), item("solo", x: 60, id: 3)]
        let visible = ItemControlStore.visibleBarItems(from: positional, controls: store)
        #expect(visible.map(\.ownerBundleID) == ["solo"])
    }

    // MARK: - Search-completeness guard

    @Test func suppressedItemIsDroppedFromBarButStillSearchable() {
        // The load-bearing honesty invariant: an item marked "search only" must NOT appear in the
        // bar, yet MUST remain findable by search. The bar uses visibleBarItems (drops it); search
        // ranks the FULL set (keeps it). Proven here on pure logic so a future change to either
        // side can't silently break "search only".
        var store = ItemControlStore()
        let secret = item("com.secret.App", x: 0, id: 1)
        let shown = item("com.shown.App", x: 30, id: 2)
        store.setSuppressed(true, for: secret)
        let positional = [secret, shown]

        let bar = ItemControlStore.visibleBarItems(from: positional, controls: store)
        #expect(bar.map(\.ownerBundleID) == ["com.shown.App"]) // suppressed item not in the bar

        // Search ranks the full positional set (what currentItems() exposes), so it's still found.
        let found = SearchRanker.rank(items: positional, query: "secret")
        #expect(found.contains { $0.item.windowID == secret.windowID })
    }
}

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

    // MARK: - Menu-bar hide intent

    @Test func hideIntentRoundTrips() {
        var store = ItemControlStore()
        let maccy = item("com.maccy.Maccy")
        #expect(store.isHidden(maccy) == false)
        store.setHidden(true, for: maccy)
        #expect(store.isHidden(maccy) == true)
        store.setHidden(false, for: maccy)
        #expect(store.isHidden(maccy) == false)
    }

    @Test func hideIntentNoOpForKeylessItem() {
        var store = ItemControlStore()
        store.setHidden(true, for: item(nil))
        #expect(store.hiddenInMenuBar.isEmpty)
        #expect(store.isHidden(item(nil)) == false)
    }

    @Test func decodingOlderStoreWithoutHideIntentSucceeds() throws {
        // A store written before `hiddenInMenuBar` existed (only suppression + order).
        let json = #"{"suppressedFromBar":["com.a"],"barOrder":{"com.b":2}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ItemControlStore.self, from: json)
        #expect(decoded.hiddenInMenuBar.isEmpty)
        #expect(decoded.suppressedFromBar == ["com.a"])
        #expect(decoded.barOrder == ["com.b": 2])
    }

    @Test func hideIntentSurvivesCodableRoundTrip() throws {
        var store = ItemControlStore()
        store.setHidden(true, for: item("com.a"))
        store.setSuppressed(true, for: item("com.b"))
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ItemControlStore.self, from: data)
        #expect(decoded == store)
        #expect(decoded.hiddenInMenuBar == ["com.a"])
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

    // MARK: - partitionByHidden (Items list grouping)

    @Test func partitionSplitsByHideIntentPreservingOrder() {
        var store = ItemControlStore()
        store.setHidden(true, forKey: "b")
        store.setHidden(true, forKey: "d")
        let items = [item("a", x: 0, id: 1), item("b", x: 30, id: 2),
                     item("c", x: 60, id: 3), item("d", x: 90, id: 4)]
        let parts = ItemControlStore.partitionByHidden(items, controls: store)
        #expect(parts.hidden.map(\.ownerBundleID) == ["b", "d"])   // in input order
        #expect(parts.shown.map(\.ownerBundleID) == ["a", "c"])    // in input order
    }

    @Test func partitionWithNothingHiddenPutsAllInShown() {
        let store = ItemControlStore()
        let items = [item("a", x: 0, id: 1), item("b", x: 30, id: 2)]
        let parts = ItemControlStore.partitionByHidden(items, controls: store)
        #expect(parts.hidden.isEmpty)
        #expect(parts.shown.count == 2)
    }

    @Test func partitionOfEmptyInputIsTwoEmptyGroups() {
        let parts = ItemControlStore.partitionByHidden([], controls: ItemControlStore())
        #expect(parts.hidden.isEmpty)
        #expect(parts.shown.isEmpty)
    }

    // MARK: - Hidden-only invariant

    @Test func suppressedItemIsDroppedFromBarButStillInTheFullSet() {
        // An item marked "hide from bar" must NOT appear in what the bar renders, yet must remain
        // in the full set the Items settings list manages (so the user can un-hide it again). The
        // bar uses visibleBarItems (drops it); the full positional set keeps it. Proven here on
        // pure logic so a future change to the filter can't silently strand a hidden item where
        // the user can no longer find it to restore it.
        var store = ItemControlStore()
        let secret = item("com.secret.App", x: 0, id: 1)
        let shown = item("com.shown.App", x: 30, id: 2)
        store.setSuppressed(true, for: secret)
        let positional = [secret, shown]

        let bar = ItemControlStore.visibleBarItems(from: positional, controls: store)
        #expect(bar.map(\.ownerBundleID) == ["com.shown.App"]) // suppressed item not in the bar

        // The full set (what the Items list manages) still contains it, so it stays restorable.
        #expect(positional.contains { $0.windowID == secret.windowID })
    }
}

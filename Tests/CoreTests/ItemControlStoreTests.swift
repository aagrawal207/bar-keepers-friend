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

    @Test func encodingSetsIsByteStableRegardlessOfInsertionOrder() throws {
        // Two stores with the SAME logical contents but built in different insertion orders must
        // encode to identical bytes. `Set` iteration order is seeded per-process, so the default
        // synthesized encoder emits the array in an unstable order — which made LayoutConfig
        // exports diff spuriously across runs. Sorting the sets on encode fixes that.
        var a = ItemControlStore()
        for k in ["com.c", "com.a", "com.b"] { a.setHidden(true, forKey: k) }
        for k in ["zeta", "alpha", "mu"] { a.setSuppressed(true, forKey: k) }

        var b = ItemControlStore()
        for k in ["com.b", "com.c", "com.a"] { b.setHidden(true, forKey: k) }
        for k in ["mu", "zeta", "alpha"] { b.setSuppressed(true, forKey: k) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // matches LayoutConfig's exporter
        #expect(try encoder.encode(a) == encoder.encode(b))
    }

    @Test func encodedSetArraysAreSorted() throws {
        // The on-disk arrays themselves are sorted ascending, so a human reading or diffing the
        // exported JSON sees a stable, predictable order.
        var store = ItemControlStore()
        for k in ["com.c", "com.a", "com.b"] { store.setHidden(true, forKey: k) }
        let data = try JSONEncoder().encode(store)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["hiddenInMenuBar"] as? [String] == ["com.a", "com.b", "com.c"])
    }

    @Test func sortedEncodingStillDecodesBackToTheSameStore() throws {
        // Sorting on encode must not change what decodes back — sets are unordered, so a round trip
        // still yields an equal store, and old files (arrays in any order) still load.
        var store = ItemControlStore()
        store.setHidden(true, forKey: "com.b")
        store.setHidden(true, forKey: "com.a")
        store.setSuppressed(true, forKey: "s2")
        store.setSuppressed(true, forKey: "s1")
        store.setOrderIndex(5, forKey: "ord")
        let decoded = try JSONDecoder().decode(ItemControlStore.self, from: JSONEncoder().encode(store))
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

    @Test func bulkHideThenPartitionPutsEverythingHidden() {
        // Backs the "Hide All" bulk action: marking every item hidden, then partitioning, leaves
        // nothing in Shown. (The model batches these into one mutation; here we assert the store
        // semantics it relies on.)
        var store = ItemControlStore()
        let items = [item("a", x: 0, id: 1), item("b", x: 30, id: 2), item("c", x: 60, id: 3)]
        for it in items { store.setHidden(true, for: it) }
        let parts = ItemControlStore.partitionByHidden(items, controls: store)
        #expect(parts.shown.isEmpty)
        #expect(parts.hidden.count == 3)
    }

    @Test func bulkShowAllClearsHiddenIntent() {
        // Backs "Show All": clearing hidden on every item empties the hidden set.
        var store = ItemControlStore()
        store.setHidden(true, forKey: "a")
        store.setHidden(true, forKey: "b")
        let items = [item("a", x: 0, id: 1), item("b", x: 30, id: 2)]
        for it in items { store.setHidden(false, for: it) }
        #expect(store.hiddenInMenuBar.isEmpty)
        #expect(ItemControlStore.partitionByHidden(items, controls: store).hidden.isEmpty)
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

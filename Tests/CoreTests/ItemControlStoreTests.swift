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

    // MARK: - Always Hidden tier

    @Test(arguments: ItemPlacement.allCases)
    func placementSetsAreMutuallyExclusive(placement: ItemPlacement) {
        var store = ItemControlStore()
        let maccy = item("com.maccy.Maccy")
        for previous in ItemPlacement.allCases {
            store.setPlacement(previous, for: maccy)
            store.setPlacement(placement, for: maccy)
            #expect(store.placement(for: maccy) == placement)
            #expect(store.placement(forKey: "com.maccy.Maccy") == placement)
            let memberships = [
                store.shownInMenuBar.contains("com.maccy.Maccy"),
                store.hiddenInMenuBar.contains("com.maccy.Maccy"),
                store.alwaysHiddenInMenuBar.contains("com.maccy.Maccy")
            ]
            #expect(memberships.filter { $0 }.count == 1)
            #expect(store.hasPlacementIntent(maccy))
            #expect(store.isHidden(maccy) == placement.isHidden)
            #expect(store.isAlwaysHidden(maccy) == (placement == .alwaysHidden))
        }
    }

    @Test func boolHideIntentMapsOntoTheOrdinaryHiddenTier() {
        var store = ItemControlStore()
        store.setPlacement(.alwaysHidden, forKey: "a")
        #expect(store.isHidden(forKey: "a"))
        store.setHidden(true, forKey: "a")
        #expect(store.placement(forKey: "a") == .hidden)
        #expect(store.alwaysHiddenInMenuBar.isEmpty)
        store.setHidden(false, forKey: "a")
        #expect(store.placement(forKey: "a") == .shown)
        #expect(ItemPlacement(hidden: true) == .hidden)
        #expect(ItemPlacement(hidden: false) == .shown)
        #expect(ItemPlacement.allCases.map(\.section) == [.visible, .hidden, .alwaysHidden])
        #expect(MenuBarSection.allCases.map(\.placement) == ItemPlacement.allCases)
    }

    @Test func placementIsNilWithoutIntentAndForKeylessItems() {
        var store = ItemControlStore()
        #expect(store.placement(forKey: "a") == nil)
        #expect(store.placement(for: item(nil)) == nil)
        store.setPlacement(.alwaysHidden, for: item(nil))
        store.setPlacement(.alwaysHidden, for: item(""))
        #expect(store == ItemControlStore())
        #expect(!store.hasAnyPlacementIntent)
        store.setPlacement(.alwaysHidden, forKey: "a")
        #expect(store.hasAnyPlacementIntent)
        #expect(store.hasPlacementIntent(forKey: "a"))
    }

    @Test func samePlacementIntentIgnoresPresentationControls() {
        let base = ItemControlStore(hiddenInMenuBar: ["h"], shownInMenuBar: ["s"], alwaysHiddenInMenuBar: ["a"])
        var presentation = base
        presentation.setSuppressed(true, forKey: "h")
        presentation.setOrderIndex(3, forKey: "a")
        #expect(base.hasSamePlacementIntent(as: presentation))
        #expect(base != presentation)
        var moved = base
        moved.setPlacement(.hidden, forKey: "a")
        #expect(!base.hasSamePlacementIntent(as: moved))
        var shownInstead = base
        shownInstead.setPlacement(.shown, forKey: "h")
        #expect(!base.hasSamePlacementIntent(as: shownInstead))
    }

    @Test func alwaysHiddenKeyIsPresentSortedAndRoundTrips() throws {
        var store = ItemControlStore()
        for k in ["com.c", "com.a", "com.b"] { store.setPlacement(.alwaysHidden, forKey: k) }
        store.setHidden(true, forKey: "com.h")
        let data = try JSONEncoder().encode(store)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["alwaysHiddenInMenuBar"] as? [String] == ["com.a", "com.b", "com.c"])
        #expect(object["hiddenInMenuBar"] as? [String] == ["com.h"])
        let decoded = try JSONDecoder().decode(ItemControlStore.self, from: data)
        #expect(decoded == store)
        #expect(decoded.alwaysHiddenInMenuBar == ["com.a", "com.b", "com.c"])
        #expect(decoded.placement(forKey: "com.a") == .alwaysHidden)
    }

    @Test func unusedAlwaysHiddenTierKeepsTheLegacyEncodedShape() throws {
        var store = ItemControlStore()
        store.setHidden(true, forKey: "com.a")
        store.setSuppressed(true, forKey: "com.b")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(store)) as? [String: Any])
        #expect(Set(object.keys) == ["hiddenInMenuBar", "shownInMenuBar", "suppressedFromBar", "barOrder"])
    }

    @Test func decodingAStoreWithoutTheAlwaysHiddenKeyOrWithItSucceeds() throws {
        let legacy = #"{"hiddenInMenuBar":["com.a"],"shownInMenuBar":[],"suppressedFromBar":[],"barOrder":{}}"#
        let decodedLegacy = try JSONDecoder().decode(ItemControlStore.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.alwaysHiddenInMenuBar.isEmpty)
        #expect(decodedLegacy.placement(forKey: "com.a") == .hidden)

        let modern = #"{"alwaysHiddenInMenuBar":["com.z"],"hiddenInMenuBar":["com.a"]}"#
        let decodedModern = try JSONDecoder().decode(ItemControlStore.self, from: Data(modern.utf8))
        #expect(decodedModern.placement(forKey: "com.z") == .alwaysHidden)
        #expect(decodedModern.isHidden(forKey: "com.z"))
        #expect(decodedModern.placement(forKey: "com.a") == .hidden)
    }

    @Test func alwaysHiddenEncodingIsByteStableRegardlessOfInsertionOrder() throws {
        var a = ItemControlStore()
        for k in ["com.c", "com.a", "com.b"] { a.setPlacement(.alwaysHidden, forKey: k) }
        var b = ItemControlStore()
        for k in ["com.b", "com.c", "com.a"] { b.setPlacement(.alwaysHidden, forKey: k) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(a) == encoder.encode(b))
    }

    @Test func partitionByPlacementKeepsTiersApartWhileHiddenPartitionMergesThem() {
        var store = ItemControlStore()
        store.setPlacement(.hidden, forKey: "b")
        store.setPlacement(.alwaysHidden, forKey: "c")
        store.setPlacement(.shown, forKey: "d")
        let items = [item("a", x: 0, id: 1), item("b", x: 30, id: 2),
                     item("c", x: 60, id: 3), item("d", x: 90, id: 4), item(nil, x: 120, id: 5)]
        let tiers = ItemControlStore.partitionByPlacement(items, controls: store)
        #expect(tiers.shown.map(\.windowID) == [1, 4, 5])
        #expect(tiers.hidden.map(\.windowID) == [2])
        #expect(tiers.alwaysHidden.map(\.windowID) == [3])
        let parts = ItemControlStore.partitionByHidden(items, controls: store)
        #expect(parts.hidden.map(\.windowID) == [2, 3])
        #expect(parts.shown.map(\.windowID) == [1, 4, 5])
    }

    // MARK: - Bar order steps

    @Test func orderedBarItemsKeepSuppressedRowsWhereVisibleBarItemsDropThem() {
        var store = ItemControlStore()
        store.setSuppressed(true, for: item("b"))
        store.setOrderIndex(0, for: item("c"))
        let positional = [item("a", x: 0, id: 1), item("b", x: 30, id: 2), item("c", x: 60, id: 3)]
        #expect(ItemControlStore.orderedBarItems(from: positional, controls: store).map(\.ownerBundleID) == ["c", "a", "b"])
        #expect(ItemControlStore.visibleBarItems(from: positional, controls: store).map(\.ownerBundleID) == ["c", "a"])
    }

    @Test func movingAnOwnerOneStepPinsTheWholeSectionDensely() {
        var store = ItemControlStore()
        let section = [item("a", x: 0, id: 1), item("b", x: 30, id: 2), item("c", x: 60, id: 3)]
        #expect(!store.canMoveInBar(section[0], .earlier, among: section))
        #expect(store.canMoveInBar(section[0], .later, among: section))
        #expect(!store.canMoveInBar(section[2], .later, among: section))
        #expect(!store.canMoveInBar(item("absent"), .later, among: section))
        let blocked = store.moveInBar(section[0], .earlier, among: section)
        #expect(!blocked)
        #expect(store == ItemControlStore())

        let firstMoved = store.moveInBar(section[0], .later, among: section)
        #expect(firstMoved)
        #expect(store.barOrder == ["b": 0, "a": 1, "c": 2])
        #expect(ItemControlStore.visibleBarItems(from: section, controls: store).map(\.ownerBundleID) == ["b", "a", "c"])
        let secondMoved = store.moveInBar(section[2], .earlier, among: section)
        #expect(secondMoved)
        #expect(ItemControlStore.visibleBarItems(from: section, controls: store).map(\.ownerBundleID) == ["b", "c", "a"])
        #expect(!store.canMoveInBar(section[0], .later, among: section))
        #expect(store.hiddenInMenuBar.isEmpty && store.shownInMenuBar.isEmpty && store.alwaysHiddenInMenuBar.isEmpty)
    }

    @Test func movingASiblingMovesItsOwnerSlotAndLeavesSuppressionAlone() {
        var store = ItemControlStore()
        store.setSuppressed(true, forKey: "dup")
        let section = [item("solo", x: 0, id: 1), item("dup", x: 30, id: 2), item("dup", x: 60, id: 3), item("z", x: 90, id: 4)]
        let siblingMoved = store.moveInBar(section[2], .earlier, among: section)
        #expect(siblingMoved)
        #expect(ItemControlStore.orderedBarItems(from: section, controls: store).map(\.windowID) == [2, 3, 1, 4])
        #expect(ItemControlStore.visibleBarItems(from: section, controls: store).map(\.windowID) == [1, 4])
        #expect(store.isSuppressed(forKey: "dup"))
        let siblingMovedBack = store.moveInBar(section[1], .later, among: section)
        #expect(siblingMovedBack)
        #expect(ItemControlStore.orderedBarItems(from: section, controls: store).map(\.windowID) == [1, 2, 3, 4])
    }
}

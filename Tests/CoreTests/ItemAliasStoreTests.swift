import CoreGraphics
import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct ItemAliasStoreTests {

    private func item(
        id: CGWindowID,
        title: String? = nil,
        bundle: String? = nil
    ) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id,
            ownerPID: 1,
            ownerBundleID: bundle,
            title: title,
            frame: CGRect(x: 0, y: 0, width: 20, height: 22)
        )
    }

    // MARK: - Key derivation

    @Test func keyIsBundleIDWhenPresent() {
        let snapshot = item(id: 1, bundle: "com.apple.dock")
        #expect(ItemAliasStore.key(for: snapshot) == "com.apple.dock")
    }

    @Test func keyIsNilWhenBundleMissingOrEmpty() {
        #expect(ItemAliasStore.key(for: item(id: 1, bundle: nil)) == nil)
        #expect(ItemAliasStore.key(for: item(id: 2, bundle: "")) == nil)
    }

    // MARK: - Set / get round-trip

    @Test func setAndGetRoundTrips() {
        var store = ItemAliasStore()
        let snapshot = item(id: 1, bundle: "com.acme.widget")
        store.setAlias("My Widget", for: snapshot)
        #expect(store.alias(for: snapshot) == "My Widget")
        #expect(store.alias(forKey: "com.acme.widget") == "My Widget")
    }

    @Test func aliasIsTrimmed() {
        var store = ItemAliasStore()
        store.setAlias("  Spaced  ", forKey: "com.acme.widget")
        #expect(store.alias(forKey: "com.acme.widget") == "Spaced")
    }

    @Test func getReturnsNilWhenUnset() {
        let store = ItemAliasStore()
        #expect(store.alias(for: item(id: 1, bundle: "com.acme.widget")) == nil)
        #expect(store.alias(forKey: "com.acme.widget") == nil)
    }

    // MARK: - Empty / whitespace removes

    @Test func settingEmptyRemovesEntry() {
        var store = ItemAliasStore(aliases: ["com.acme.widget": "Old"])
        store.setAlias("", forKey: "com.acme.widget")
        #expect(store.alias(forKey: "com.acme.widget") == nil)
    }

    @Test func settingWhitespaceRemovesEntry() {
        var store = ItemAliasStore(aliases: ["com.acme.widget": "Old"])
        store.setAlias("   ", forKey: "com.acme.widget")
        #expect(store.alias(forKey: "com.acme.widget") == nil)
    }

    @Test func settingNilRemovesEntry() {
        var store = ItemAliasStore(aliases: ["com.acme.widget": "Old"])
        store.setAlias(nil, forKey: "com.acme.widget")
        #expect(store.alias(forKey: "com.acme.widget") == nil)
    }

    // MARK: - Keyless snapshot is a no-op

    @Test func setAliasOnKeylessSnapshotIsNoOp() {
        var store = ItemAliasStore()
        let keyless = item(id: 1, title: "Item-0", bundle: nil)
        store.setAlias("Should not stick", for: keyless)
        #expect(store.aliases.isEmpty)
        #expect(store.alias(for: keyless) == nil)
    }

    // MARK: - Codable

    @Test func codableRoundTripsToEqualValue() throws {
        let store = ItemAliasStore(aliases: [
            "com.apple.dock": "Dock",
            "com.acme.widget": "My Widget",
        ])
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ItemAliasStore.self, from: data)
        #expect(decoded == store)
    }

    // MARK: - Ranking with aliases

    @Test func aliasMakesOtherwiseUnmatchableItemSearchable() {
        // Tahoe reality: no readable title (placeholder), bundle id doesn't contain the
        // query — but the user aliased it "Coffee". Without the store, "coffee" finds
        // nothing; with the store, the item is returned.
        let snapshot = item(id: 7, title: "Item-0", bundle: "com.acme.tool")
        let aliases = ItemAliasStore(aliases: ["com.acme.tool": "Coffee"])

        let withoutAliases = SearchRanker.rank(items: [snapshot], query: "coffee")
        #expect(withoutAliases.isEmpty)

        let withAliases = SearchRanker.rank(items: [snapshot], query: "coffee", aliases: aliases)
        #expect(withAliases.map(\.item.windowID) == [7])
    }

    @Test func aliasMatchRanksAtLeastAsHighAsTitleMatch() {
        // Two items: one matches on title, one matches (exactly) on alias. The alias match
        // should not score lower than the equivalent title match.
        let titleHit = item(id: 1, title: "Coffee", bundle: "com.a.one")
        let aliasHit = item(id: 2, title: "Item-0", bundle: "com.b.two")
        let aliases = ItemAliasStore(aliases: ["com.b.two": "Coffee"])

        let result = SearchRanker.rank(
            items: [titleHit, aliasHit],
            query: "coffee",
            aliases: aliases
        )
        let scores = Dictionary(uniqueKeysWithValues: result.map { ($0.item.windowID, $0.score) })
        #expect(scores[1] != nil)
        #expect(scores[2] != nil)
        #expect(scores[2]! >= scores[1]!)
    }
}

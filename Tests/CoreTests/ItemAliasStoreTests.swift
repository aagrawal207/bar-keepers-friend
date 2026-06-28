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
}

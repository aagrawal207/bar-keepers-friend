import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct PreferencesTests {

    @Test func roundTripsThroughCodable() throws {
        var prefs = Preferences.default
        prefs.autoRehide = false
        prefs.autoRehideDelay = 30
        prefs.showSectionDividers = true
        prefs.launchAtLogin = true
        prefs.useFloatingBar = false
        prefs.floatingBarStyle = .vertical
        prefs.controlItemPositions = ["BKFAnchor": 0, "BKFHidden": 1.5]

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded == prefs)
    }

    @Test func floatingBarDefaultsAreSensible() {
        // The whole reason for this feature: default to the floating bar so a too-narrow
        // (notched) menu bar isn't relied upon to display revealed items.
        #expect(Preferences.default.useFloatingBar)
        #expect(Preferences.default.floatingBarStyle == .horizontal)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        // An older / partial file that only has one field.
        let json = #"{"autoRehide": false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Preferences.self, from: json)
        #expect(decoded.autoRehide == false)
        #expect(decoded.autoRehideDelay == Preferences.default.autoRehideDelay)
        #expect(decoded.launchAtLogin == Preferences.default.launchAtLogin)
    }

    @Test func storeLoadsDefaultWhenEmpty() {
        let store = PreferencesStore(backing: InMemoryPreferences())
        #expect(store.load() == .default)
    }

    @Test func storeSavesAndLoadsBack() {
        let backing = InMemoryPreferences()
        let store = PreferencesStore(backing: backing)
        var prefs = Preferences.default
        prefs.autoRehideDelay = 42
        #expect(store.save(prefs))
        #expect(store.load().autoRehideDelay == 42)
    }

    @Test func storeRecoversFromCorruptData() {
        let backing = InMemoryPreferences()
        backing.set(Data("not json".utf8), forKey: "com.agraabhi.BarKeepersFriend.preferences")
        let store = PreferencesStore(backing: backing)
        // Must not throw; must fall back to defaults so the app can always launch.
        #expect(store.load() == .default)
    }

    @Test func exportImportIsLossless() throws {
        let store = PreferencesStore(backing: InMemoryPreferences())
        var prefs = Preferences.default
        prefs.showSectionDividers = true
        let exported = try store.exportJSON(prefs)
        let imported = try store.importJSON(exported)
        #expect(imported == prefs)
    }
}

/// In-memory `PreferencesPersisting` for tests — no `UserDefaults` side effects.
private final class InMemoryPreferences: PreferencesPersisting, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func set(_ data: Data?, forKey key: String) { storage[key] = data }
}

import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct PreferencesTests {

    @Test func roundTripsThroughCodable() throws {
        var prefs = Preferences.default
        prefs.autoRehide = false
        prefs.autoRehideDelay = 30
        prefs.launchAtLogin = true
        prefs.useFloatingBar = false
        prefs.floatingBarStyle = .vertical
        prefs.controlItemPositions = ["BKFAnchor": 0, "BKFHidden": 1.5]

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded == prefs)
    }

    @Test(arguments: [
        (-Double.greatestFiniteMagnitude, 2.0),
        (-1e20, 2.0),
        (-1.0, 2.0),
        (0.0, 2.0),
        (Double(2).nextDown, 2.0),
        (2.0, 2.0),
        (2.5, 2.5),
        (15.75, 15.75),
        (119.5, 119.5),
        (120.0, 120.0),
        (Double(120).nextUp, 120.0),
        (1e20, 120.0),
        (Double.greatestFiniteMagnitude, 120.0)
    ])
    func finiteAutoRehideDelayIsNormalized(input: TimeInterval, expected: TimeInterval) throws {
        let initialized = Preferences(autoRehide: false, autoRehideDelay: input)
        #expect(initialized.autoRehideDelay == expected)

        var assigned = Preferences.default
        assigned.autoRehideDelay = input
        #expect(assigned.autoRehideDelay == expected)

        let json = Data(#"{"autoRehideDelay":\#(input)}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: json)
        #expect(decoded.autoRehideDelay == expected)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func nonfiniteAutoRehideDelayFallsBackToDefault(input: TimeInterval) throws {
        let initialized = Preferences(autoRehideDelay: input)
        var assigned = Preferences(autoRehideDelay: 30)
        assigned.autoRehideDelay = input

        for prefs in [initialized, assigned] {
            #expect(prefs.autoRehideDelay == 15)
            let store = PreferencesStore(backing: InMemoryPreferences())
            try #require(store.save(prefs))
            #expect(store.load() == prefs)
        }
    }

    @Test(arguments: ["NaN", "Infinity", "-Infinity"])
    func decodedNonfiniteAutoRehideDelayFallsBackToDefault(input: String) throws {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let json = Data(#"{"autoRehideDelay":"\#(input)"}"#.utf8)
        let decoded = try decoder.decode(Preferences.self, from: json)
        #expect(decoded.autoRehideDelay == 15)
    }

    @Test func autoRehideDelayKeepsNumericCodableKeyAndShape() throws {
        let data = try JSONEncoder().encode(Preferences(autoRehideDelay: 15.75))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["autoRehideDelay"] as? Double == 15.75)
        #expect(Set(object.keys) == [
            "autoRehide", "autoRehideDelay", "launchAtLogin", "useFloatingBar",
            "floatingBarStyle", "useAXActivation", "controlItemPositions", "enableGlobalHotkey",
            "toggleHotkey", "itemAliases", "itemControls", "dismissBarOnMouseExit"
        ])
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
        #expect(decoded.autoRehideDelay == 15)
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

    @Test func storeNormalizesPreviouslyPersistedDelay() throws {
        let backing = InMemoryPreferences()
        let json = Data(#"{"autoRehide":false,"autoRehideDelay":1e20,"launchAtLogin":true}"#.utf8)
        backing.set(json, forKey: "com.agraabhi.BarKeepersFriend.preferences")
        let store = PreferencesStore(backing: backing)
        let loaded = store.load()
        #expect(loaded.autoRehideDelay == 120)
        #expect(!loaded.autoRehide)
        #expect(loaded.launchAtLogin)
        try #require(store.save(loaded))
        #expect(PreferencesStore(backing: backing).load() == loaded)
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
        prefs.autoRehideDelay = 99
        prefs.dismissBarOnMouseExit = false
        let exported = try store.exportJSON(prefs)
        let imported = try store.importJSON(exported)
        #expect(imported == prefs)
    }
}

/// In-memory `PreferencesPersisting` for tests — no `UserDefaults` side effects.
final class InMemoryPreferences: PreferencesPersisting, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func set(_ data: Data?, forKey key: String) { storage[key] = data }
}

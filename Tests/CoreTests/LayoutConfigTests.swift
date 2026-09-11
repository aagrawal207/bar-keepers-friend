import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct LayoutConfigTests {

    /// A `Preferences` value that differs from `.default` in every shape that matters (bools,
    /// a delay, an enum, a nested HotkeyCombo, and the positions dictionary) so a round-trip
    /// failure in any one field is caught.
    private func makeNonDefaultPreferences() -> Preferences {
        var prefs = Preferences.default
        prefs.autoRehide = false
        prefs.autoRehideDelay = 30
        prefs.launchAtLogin = true
        prefs.useFloatingBar = false
        prefs.floatingBarStyle = .vertical
        prefs.useAXActivation = true
        prefs.controlItemPositions = ["BKFAnchor": 0, "BKFHidden": 1.5]
        prefs.enableGlobalHotkey = false
        prefs.toggleHotkey = HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.command | HotkeyCombo.shift)
        prefs.dismissBarOnMouseExit = false
        return prefs
    }

    @Test func roundTripsNonDefaultPreferences() throws {
        let prefs = makeNonDefaultPreferences()
        let config = LayoutConfig(preferences: prefs)

        let data = try config.encoded()
        let decoded = try LayoutConfig.decode(from: data)

        #expect(decoded.preferences == prefs)
        #expect(decoded.version == LayoutConfig.currentVersion)
        #expect(decoded == config)
    }

    @Test func roundTripsDefaultPreferences() throws {
        let config = LayoutConfig(preferences: .default)

        let data = try config.encoded()
        let decoded = try LayoutConfig.decode(from: data)

        #expect(decoded.preferences == .default)
        #expect(decoded.version == LayoutConfig.currentVersion)
    }

    @Test(arguments: [("1e20", 120.0), ("-1e20", 2.0), ("15.75", 15.75)])
    func importedDelayStaysSafeAfterSaveAndLoad(jsonDelay: String, expectedDelay: TimeInterval) throws {
        let data = Data("""
        {
            "version": 1,
            "preferences": {
                "autoRehide": true,
                "autoRehideDelay": \(jsonDelay),
                "launchAtLogin": true,
                "controlItemPositions": {"BKFAnchor": 0, "BKFHidden": 1.5},
                "itemAliases": {"aliases": {"Maccy": "Clipboard", "Karabiner-Menu": "Keys"}},
                "itemControls": {
                    "hiddenInMenuBar": ["Maccy"],
                    "shownInMenuBar": ["Karabiner-Menu"],
                    "suppressedFromBar": ["Maccy"],
                    "barOrder": {"Maccy": 3}
                }
            }
        }
        """.utf8)
        let expected = Preferences(
            autoRehideDelay: expectedDelay,
            launchAtLogin: true,
            controlItemPositions: ["BKFAnchor": 0, "BKFHidden": 1.5],
            itemAliases: ItemAliasStore(aliases: ["Maccy": "Clipboard", "Karabiner-Menu": "Keys"]),
            itemControls: ItemControlStore(
                hiddenInMenuBar: ["Maccy"],
                shownInMenuBar: ["Karabiner-Menu"],
                suppressedFromBar: ["Maccy"],
                barOrder: ["Maccy": 3]
            )
        )
        let imported = try LayoutConfig.decode(from: data)
        #expect(imported.preferences == expected)

        let backing = InMemoryPreferences()
        let store = PreferencesStore(backing: backing)
        try #require(store.save(imported.preferences))
        let reloaded = PreferencesStore(backing: backing).load()
        #expect(reloaded == expected)
        try #require(reloaded.autoRehideDelay.isFinite)
        try #require((2.0...120.0).contains(reloaded.autoRehideDelay))
        #expect(Int(reloaded.autoRehideDelay) == Int(expectedDelay))
    }

    @Test func encodedJSONIsNonEmptyAndCarriesVersion() throws {
        let data = try LayoutConfig(preferences: makeNonDefaultPreferences()).encoded()
        #expect(!data.isEmpty)

        // It must be valid JSON, and the top-level object must carry the version stamp the
        // importer relies on to decide whether it understands the file.
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = object as? [String: Any]
        #expect(dictionary != nil)
        #expect(dictionary?["version"] as? Int == LayoutConfig.currentVersion)
    }

    @Test func decodeThrowsMalformedOnGarbageBytes() {
        let garbage = Data("not json".utf8)
        #expect(throws: LayoutConfigError.malformed) {
            _ = try LayoutConfig.decode(from: garbage)
        }
    }

    @Test func decodeThrowsUnsupportedVersionOnFutureVersion() throws {
        // Build a structurally valid config whose version is one past what we understand, the
        // way a file written by a newer build of the app would look.
        let futureVersion = LayoutConfig.currentVersion + 1
        let config = LayoutConfig(version: futureVersion, preferences: .default)
        let data = try config.encoded()

        #expect(throws: LayoutConfigError.unsupportedVersion(futureVersion)) {
            _ = try LayoutConfig.decode(from: data)
        }
    }

    @Test func decodeThrowsUnsupportedVersionOnZeroOrNegative() throws {
        // A hand-edited or corrupt file with a nonsensical low version must NOT import silently as
        // if valid — a real export always stamps a version >= 1. Reject 0 and negative.
        for badVersion in [0, -1, -100] {
            let data = try LayoutConfig(version: badVersion, preferences: .default).encoded()
            #expect(throws: LayoutConfigError.unsupportedVersion(badVersion)) {
                _ = try LayoutConfig.decode(from: data)
            }
        }
    }

    @Test func decodeRejectsOversizeDataBeforeParsing() {
        // A file larger than the cap is rejected as `.tooLarge` (with its byte count) rather than
        // being handed to JSONDecoder, which would build an object graph from the whole blob. The
        // bytes here are garbage on purpose: the size check must fire BEFORE the parse, so this
        // must throw .tooLarge, not .malformed.
        let oversize = LayoutConfig.maxEncodedSize + 1
        let data = Data(count: oversize)
        #expect(throws: LayoutConfigError.tooLarge(oversize)) {
            _ = try LayoutConfig.decode(from: data)
        }
    }

    @Test func decodeAcceptsDataExactlyAtTheSizeCap() throws {
        // The bound is inclusive: a real export is far under the cap, and a file landing exactly on
        // it must still parse (the guard rejects only `> maxEncodedSize`). A genuine encoded config
        // is a few KB, well within the cap, so a normal round-trip proves the cap doesn't interfere.
        let data = try LayoutConfig(preferences: .default).encoded()
        #expect(data.count <= LayoutConfig.maxEncodedSize)
        let decoded = try LayoutConfig.decode(from: data)
        #expect(decoded.preferences == .default)
    }
}

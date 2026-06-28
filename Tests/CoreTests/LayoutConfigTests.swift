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
        prefs.showSectionDividers = true
        prefs.launchAtLogin = true
        prefs.useFloatingBar = false
        prefs.floatingBarStyle = .vertical
        prefs.useAXActivation = true
        prefs.controlItemPositions = ["BKFAnchor": 0, "BKFHidden": 1.5]
        prefs.enableGlobalHotkey = false
        prefs.toggleHotkey = HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.command | HotkeyCombo.shift)
        prefs.enableSearch = false
        prefs.searchHotkey = HotkeyCombo(keyCode: 5, modifiers: HotkeyCombo.control)
        prefs.hoverToReveal = true
        prefs.hoverRevealDelay = 0.5
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
}

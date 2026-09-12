import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct LayoutPresetTests {

    private static func controls(hidden: Set<String> = [], shown: Set<String> = []) -> ItemControlStore {
        ItemControlStore(hiddenInMenuBar: hidden, shownInMenuBar: shown)
    }

    private static func preset(
        _ name: String, hidden: Set<String> = [], shown: Set<String> = [], id: UUID = UUID()
    ) -> LayoutPreset {
        LayoutPreset(id: id, name: name, itemControls: controls(hidden: hidden, shown: shown))
    }

    /// Every non-default field set, so a test can prove an operation touched only the arrangement.
    private static func richPreferences() -> Preferences {
        var prefs = Preferences(
            autoRehide: false, autoRehideDelay: 33, launchAtLogin: true, useFloatingBar: false,
            floatingBarStyle: .vertical, useAXActivation: true, controlItemPositions: ["BKFAnchor": 12],
            enableGlobalHotkey: false, toggleHotkey: HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.option),
            itemAliases: ItemAliasStore(aliases: ["Maccy": "Clipboard"]),
            itemControls: ItemControlStore(
                hiddenInMenuBar: ["ACME"], shownInMenuBar: ["Maccy"], suppressedFromBar: ["ACME"], barOrder: ["ACME": 2]
            ),
            dismissBarOnMouseExit: false, revealOnHover: true
        )
        prefs.presets = [preset("Existing", hidden: ["Wisp"])]
        return prefs
    }

    // MARK: - Names

    @Test func normalizedNameTrimsSurroundingWhitespaceOnly() {
        #expect(PresetLibrary.normalizedName("  Deep Work \n") == "Deep Work")
        #expect(PresetLibrary.normalizedName("Deep  Work") == "Deep  Work")
        #expect(PresetLibrary.normalizedName(" \t\n") == "")
        #expect(PresetLibrary.normalizedName("") == "")
    }

    @Test func nameValidationRejectsEmptyLongAndCaseInsensitiveDuplicates() {
        let focus = Self.preset("Focus")
        let existing = [focus, Self.preset("Meeting")]
        #expect(PresetLibrary.nameProblem("", existing: existing) == .emptyName)
        #expect(PresetLibrary.nameProblem("   \n", existing: existing) == .emptyName)
        #expect(PresetLibrary.nameProblem(String(repeating: "x", count: 61), existing: existing) == .nameTooLong)
        #expect(PresetLibrary.nameProblem(String(repeating: "x", count: 60), existing: existing) == nil)
        // Padding is trimmed before the length check.
        #expect(PresetLibrary.nameProblem("  " + String(repeating: "x", count: 60) + "  ", existing: existing) == nil)
        #expect(PresetLibrary.nameProblem(" fOCUS ", existing: existing) == .duplicateName)
        #expect(PresetLibrary.nameProblem("Home", existing: existing) == nil)
        // A rename may keep or re-case its own name, but not take another preset's.
        #expect(PresetLibrary.nameProblem("FOCUS", existing: existing, excludingID: focus.id) == nil)
        #expect(PresetLibrary.nameProblem("Meeting", existing: existing, excludingID: focus.id) == .duplicateName)

        #expect(!PresetLibrary.isValidName("", existing: existing))
        #expect(!PresetLibrary.isValidName("focus", existing: existing))
        #expect(PresetLibrary.isValidName("focus", existing: existing, excludingID: focus.id))
        #expect(PresetLibrary.isValidName("Home", existing: existing))
        #expect(PresetLibrary.isValidName("Anything", existing: []))
        #expect(!PresetLibrary.isValidName(String(repeating: "y", count: 61), existing: []))
    }

    @Test func addProblemReportsAFullListBeforeAnyNameProblem() {
        let full = (0..<PresetLibrary.maxPresets).map { Self.preset("Preset \($0)") }
        #expect(full.count == 50)
        #expect(PresetLibrary.addProblem(name: "", to: full) == .tooManyPresets)
        #expect(PresetLibrary.addProblem(name: "Unique", to: full) == .tooManyPresets)
        let room = Array(full.dropLast())
        #expect(PresetLibrary.addProblem(name: "Unique", to: room) == nil)
        #expect(PresetLibrary.addProblem(name: "preset 3", to: room) == .duplicateName)
        #expect(PresetLibrary.addProblem(name: "  ", to: []) == .emptyName)
        #expect(PresetLibrary.addProblem(name: String(repeating: "x", count: 61), to: []) == .nameTooLong)
    }

    @Test func validationMessagesAreUserFacing() {
        #expect(PresetLibrary.ValidationProblem.nameTooLong.message.contains("60"))
        #expect(PresetLibrary.ValidationProblem.tooManyPresets.message.contains("50"))
        for problem in [PresetLibrary.ValidationProblem.emptyName, .duplicateName] {
            #expect(!problem.message.isEmpty)
        }
    }

    // MARK: - Capture and apply

    @Test func capturingCurrentSnapshotsOnlyTheItemControlsUnderATrimmedName() {
        let prefs = Self.richPreferences()
        let captured = PresetLibrary.capturingCurrent(name: "  Work  ", preferences: prefs)
        #expect(captured.name == "Work")
        #expect(captured.itemControls == prefs.itemControls)
        let again = PresetLibrary.capturingCurrent(name: "Work", preferences: prefs)
        #expect(again.id != captured.id)
        #expect(again.itemControls == captured.itemControls)
        #expect(prefs.presets.map(\.name) == ["Existing"])
    }

    @Test func applyingReplacesOnlyTheItemControls() {
        let prefs = Self.richPreferences()
        let preset = Self.preset("Meeting", hidden: ["Maccy", "Wisp"], shown: ["ACME"])
        let applied = PresetLibrary.applying(preset, to: prefs)
        #expect(applied.itemControls == preset.itemControls)
        var expected = prefs
        expected.itemControls = preset.itemControls
        #expect(applied == expected)
        #expect(applied.itemAliases == prefs.itemAliases)
        #expect(applied.presets == prefs.presets)
        #expect(applied.autoRehideDelay == 33)
        #expect(applied.controlItemPositions == ["BKFAnchor": 12])
        #expect(applied.toggleHotkey == prefs.toggleHotkey)
        // Re-applying the captured arrangement restores the original preferences exactly.
        let captured = PresetLibrary.capturingCurrent(name: "Before", preferences: prefs)
        #expect(PresetLibrary.applying(captured, to: applied) == prefs)
    }

    @Test func activePresetIsTheFirstWhoseControlsMatchTheSavedArrangement() {
        var prefs = Preferences.default
        prefs.itemControls = Self.controls(hidden: ["ACME"], shown: ["Maccy"])
        #expect(PresetLibrary.activePreset(in: prefs) == nil)
        let other = Self.preset("Other", hidden: ["Maccy"])
        let first = Self.preset("First", hidden: ["ACME"], shown: ["Maccy"])
        let twin = Self.preset("Twin", hidden: ["ACME"], shown: ["Maccy"])
        prefs.presets = [other, first, twin]
        #expect(PresetLibrary.activePreset(in: prefs)?.id == first.id)

        let applied = PresetLibrary.applying(other, to: prefs)
        #expect(PresetLibrary.activePreset(in: applied)?.id == other.id)
        // Suppression and bar order are part of the arrangement, so they break the match too.
        var reordered = prefs
        reordered.itemControls.setOrderIndex(1, forKey: "ACME")
        #expect(PresetLibrary.activePreset(in: reordered) == nil)
        var flipped = prefs
        flipped.itemControls.setHidden(false, forKey: "ACME")
        #expect(PresetLibrary.activePreset(in: flipped) == nil)

        var empty = Preferences.default
        empty.presets = [Self.preset("Nothing hidden")]
        #expect(PresetLibrary.activePreset(in: empty)?.name == "Nothing hidden")
        #expect(PresetLibrary.activePreset(in: Preferences.default) == nil)
    }

    // MARK: - Editing

    @Test func addingAppendsATrimmedPresetAndIgnoresInvalidOnes() {
        let focus = Self.preset("Focus", hidden: ["ACME"])
        let added = PresetLibrary.adding(Self.preset("  Meeting ", hidden: ["Maccy"]), to: [focus])
        #expect(added.map(\.name) == ["Focus", "Meeting"])
        #expect(added[0] == focus)
        #expect(added[1].itemControls == Self.controls(hidden: ["Maccy"]))

        #expect(PresetLibrary.adding(Self.preset("focus"), to: added) == added)
        #expect(PresetLibrary.adding(Self.preset("   "), to: added) == added)
        #expect(PresetLibrary.adding(Self.preset(String(repeating: "x", count: 61)), to: added) == added)
        #expect(PresetLibrary.adding(Self.preset("Same id", id: focus.id), to: added) == added)
        #expect(PresetLibrary.adding(Self.preset("First"), to: []).map(\.name) == ["First"])
    }

    @Test func addingBeyondTheMaximumIsANoOp() {
        var presets: [LayoutPreset] = []
        for index in 0..<PresetLibrary.maxPresets {
            presets = PresetLibrary.adding(Self.preset("Preset \(index)"), to: presets)
        }
        #expect(presets.count == 50)
        #expect(PresetLibrary.adding(Self.preset("One more"), to: presets) == presets)
        let removed = PresetLibrary.removing(id: presets[0].id, from: presets)
        #expect(PresetLibrary.adding(Self.preset("One more"), to: removed).count == 50)
    }

    @Test func removingDropsOnlyTheMatchingPreset() {
        let focus = Self.preset("Focus")
        let meeting = Self.preset("Meeting")
        #expect(PresetLibrary.removing(id: focus.id, from: [focus, meeting]) == [meeting])
        #expect(PresetLibrary.removing(id: meeting.id, from: [focus, meeting]) == [focus])
        #expect(PresetLibrary.removing(id: UUID(), from: [focus, meeting]) == [focus, meeting])
        #expect(PresetLibrary.removing(id: focus.id, from: []).isEmpty)
    }

    @Test func renamingTrimsValidatesAndLeavesControlsAlone() {
        let focus = Self.preset("Focus", hidden: ["ACME"])
        let meeting = Self.preset("Meeting")
        let presets = [focus, meeting]
        let renamed = PresetLibrary.renaming(id: focus.id, to: "  Deep Work ", in: presets)
        #expect(renamed.map(\.name) == ["Deep Work", "Meeting"])
        #expect(renamed[0].id == focus.id)
        #expect(renamed[0].itemControls == focus.itemControls)
        #expect(renamed[1] == meeting)
        #expect(PresetLibrary.renaming(id: focus.id, to: "FOCUS", in: presets)[0].name == "FOCUS")

        #expect(PresetLibrary.renaming(id: focus.id, to: "meeting", in: presets) == presets)
        #expect(PresetLibrary.renaming(id: focus.id, to: "  ", in: presets) == presets)
        #expect(PresetLibrary.renaming(id: focus.id, to: String(repeating: "x", count: 61), in: presets) == presets)
        #expect(PresetLibrary.renaming(id: UUID(), to: "Anything", in: presets) == presets)
        #expect(PresetLibrary.renaming(id: focus.id, to: " Focus ", in: presets) == presets)
    }

    @Test func updatingReplacesTheControlsFromCurrentPreferencesOnly() {
        var prefs = Self.richPreferences()
        let stale = Self.preset("Stale", hidden: ["Wisp"])
        let other = Self.preset("Other", shown: ["Wisp"])
        let updated = PresetLibrary.updating(id: stale.id, from: prefs, in: [stale, other])
        #expect(updated[0].id == stale.id)
        #expect(updated[0].name == "Stale")
        #expect(updated[0].itemControls == prefs.itemControls)
        #expect(updated[1] == other)
        #expect(PresetLibrary.updating(id: UUID(), from: prefs, in: [stale, other]) == [stale, other])
        #expect(PresetLibrary.updating(id: stale.id, from: prefs, in: []).isEmpty)
        prefs.presets = updated
        #expect(PresetLibrary.activePreset(in: prefs)?.id == stale.id)
    }

    @Test func normalizedDropsDuplicateIDsAndExcessPresets() {
        let shared = UUID()
        let first = Self.preset("First", hidden: ["a"], id: shared)
        let duplicate = Self.preset("Duplicate", hidden: ["b"], id: shared)
        let second = Self.preset("Second")
        #expect(PresetLibrary.normalized([first, duplicate, second]) == [first, second])
        let many = (0..<55).map { Self.preset("P\($0)") }
        #expect(PresetLibrary.normalized(many) == Array(many.prefix(50)))
        #expect(PresetLibrary.normalized([]).isEmpty)
        #expect(PresetLibrary.normalized([first, second]) == [first, second])
    }

    // MARK: - Equality and Codable

    @Test func equalityCoversTheArrangementWhileHashingStaysConsistent() {
        let id = UUID()
        let a = Self.preset("Focus", hidden: ["ACME"], id: id)
        let b = Self.preset("Focus", hidden: ["ACME"], id: id)
        let c = Self.preset("Focus", hidden: ["Maccy"], id: id)
        let d = Self.preset("Other", hidden: ["ACME"], id: id)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
        #expect(a != d)
        #expect(Set([a, b, c, d]).count == 3)
    }

    @Test func codableRoundTripKeepsIdentityNameAndControlsWithStableKeys() throws {
        let preset = LayoutPreset(
            name: "Focus",
            itemControls: ItemControlStore(
                hiddenInMenuBar: ["ACME", "Maccy"], shownInMenuBar: ["Wisp"],
                suppressedFromBar: ["ACME"], barOrder: ["Maccy": 1]
            )
        )
        let data = try JSONEncoder().encode([preset])
        let decoded = try JSONDecoder().decode([LayoutPreset].self, from: data)
        #expect(decoded == [preset])
        #expect(decoded[0].id == preset.id)

        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let object = try #require(objects.first)
        #expect(Set(object.keys) == ["id", "name", "itemControls"])
        #expect(object["id"] as? String == preset.id.uuidString)
        #expect(object["name"] as? String == "Focus")
        let controls = try #require(object["itemControls"] as? [String: Any])
        #expect(Set(controls.keys) == ["hiddenInMenuBar", "shownInMenuBar", "suppressedFromBar", "barOrder"])
        #expect(controls["hiddenInMenuBar"] as? [String] == ["ACME", "Maccy"])
        #expect(controls["shownInMenuBar"] as? [String] == ["Wisp"])
    }

    @Test func decodingIsLenientAboutMissingFields() throws {
        let missingID = try JSONDecoder().decode(
            LayoutPreset.self, from: Data(#"{"name":" Focus ","itemControls":{"hiddenInMenuBar":["ACME"]}}"#.utf8)
        )
        #expect(missingID.name == "Focus")
        #expect(missingID.itemControls == Self.controls(hidden: ["ACME"]))

        let id = UUID()
        let missingName = try JSONDecoder().decode(
            LayoutPreset.self, from: Data(#"{"id":"\#(id.uuidString)","itemControls":{}}"#.utf8)
        )
        #expect(missingName.id == id)
        #expect(missingName.name == PresetLibrary.fallbackName)
        #expect(missingName.itemControls == ItemControlStore())

        let blankName = try JSONDecoder().decode(LayoutPreset.self, from: Data(#"{"name":"   "}"#.utf8))
        #expect(blankName.name == PresetLibrary.fallbackName)

        let nullControls = try JSONDecoder().decode(
            LayoutPreset.self, from: Data(#"{"name":"Focus","itemControls":null}"#.utf8)
        )
        #expect(nullControls.name == "Focus")
        #expect(nullControls.itemControls == ItemControlStore())

        let empty = try JSONDecoder().decode(LayoutPreset.self, from: Data("{}".utf8))
        #expect(empty.name == PresetLibrary.fallbackName)
        #expect(empty.itemControls == ItemControlStore())
        let another = try JSONDecoder().decode(LayoutPreset.self, from: Data("{}".utf8))
        #expect(another.id != empty.id)
    }

    @Test func decodingRejectsWrongTypesSoACallerCanDropThatElement() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LayoutPreset.self, from: Data(#"{"id":"not-a-uuid","name":"Focus"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LayoutPreset.self, from: Data(#"{"name":"Focus","itemControls":"ACME"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LayoutPreset.self, from: Data(#"{"name":7}"#.utf8))
        }
    }

    @Test func presetsPersistInsidePreferencesAndAMalformedElementIsDropped() throws {
        var prefs = Preferences.default
        prefs.presets = [Self.preset("Focus", hidden: ["ACME"]), Self.preset("Meeting", shown: ["ACME"])]
        let data = try JSONEncoder().encode(prefs)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["presets"] as? [[String: Any]])?.count == 2)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.presets == prefs.presets)
        #expect(decoded == prefs)

        let store = PreferencesStore(backing: InMemoryPreferences())
        try #require(store.save(prefs))
        #expect(store.load() == prefs)
        #expect(try store.importJSON(store.exportJSON(prefs)) == prefs)

        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).presets.isEmpty)
        #expect(Preferences.default.presets.isEmpty)

        // One corrupt element must cost that preset only, never the whole preferences file.
        let id = UUID()
        let mixed = Data("""
        {"autoRehide":false,"presets":[\
        {"id":"\(id.uuidString)","name":"Focus","itemControls":{"hiddenInMenuBar":["ACME"]}},\
        {"id":"not-a-uuid","name":"Broken"}]}
        """.utf8)
        let lenient = try JSONDecoder().decode(Preferences.self, from: mixed)
        #expect(!lenient.autoRehide)
        #expect(lenient.presets.map(\.id) == [id])
        #expect(lenient.presets.map(\.name) == ["Focus"])
        #expect(lenient.presets.first?.itemControls == Self.controls(hidden: ["ACME"]))
    }
}

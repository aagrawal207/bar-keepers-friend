import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

/// The recorder's key handling, driven through its model: no `NSEvent` is built or posted.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct HotkeyRecorderModelTests {
    private let cmd = HotkeyCombo.command
    private let opt = HotkeyCombo.option
    private let shift = HotkeyCombo.shift
    private let fn: UInt = 1 << 23

    private final class Commits {
        var all: [HotkeyCombo?] = []
    }

    private func makeModel(
        combo: HotkeyCombo? = .defaultToggle, allowsClear: Bool = true,
        conflict: @escaping (HotkeyCombo) -> HotkeyAssignments.Conflict? = { _ in nil },
        commits: Commits = Commits()
    ) -> HotkeyRecorderModel {
        HotkeyRecorderModel(combo: combo, allowsClear: allowsClear, conflict: conflict, onCommit: { commits.all.append($0) })
    }

    @Test func recordingShowsThePromptAndEchoesHeldModifiers() {
        let model = makeModel()
        #expect(model.displayText == "⌥⌘B")
        #expect(!model.isRecording)
        model.beginRecording()
        #expect(model.isRecording)
        #expect(model.displayText == "Press shortcut...")
        model.flagsChanged(modifiers: cmd | opt | fn)
        #expect(model.displayText == "Press shortcut... ⌥⌘")
        model.flagsChanged(modifiers: 0)
        #expect(model.displayText == "Press shortcut...")
        #expect(!model.canClear, "clear is hidden while recording")
    }

    @Test func escapeCancelsWithoutCommitting() {
        let commits = Commits()
        let model = makeModel(commits: commits)
        model.beginRecording()
        #expect(model.handle(keyCode: HotkeyRecorderModel.escapeKeyCode, modifiers: 0))
        #expect(!model.isRecording)
        #expect(model.combo == .defaultToggle)
        #expect(model.displayText == "⌥⌘B")
        #expect(commits.all.isEmpty)
        #expect(model.message == nil)
    }

    @Test(arguments: [HotkeyRecorderModel.deleteKeyCode, HotkeyRecorderModel.forwardDeleteKeyCode])
    func deleteClearsTheShortcutAndCommitsNil(keyCode: Int) {
        let commits = Commits()
        let model = makeModel(commits: commits)
        model.beginRecording()
        #expect(model.handle(keyCode: keyCode, modifiers: 0))
        #expect(!model.isRecording)
        #expect(model.combo == nil)
        #expect(model.displayText == "None")
        #expect(commits.all == [nil])
        #expect(!model.canClear)
    }

    @Test func deleteIsJustAnUnmodifiedKeyWhenClearingIsNotAllowed() {
        let commits = Commits()
        let model = makeModel(allowsClear: false, commits: commits)
        model.beginRecording()
        #expect(model.handle(keyCode: HotkeyRecorderModel.deleteKeyCode, modifiers: 0))
        #expect(model.isRecording)
        #expect(model.combo == .defaultToggle)
        #expect(model.message == "Hold Command, Option, or Control with the key.")
        #expect(commits.all.isEmpty)
        // Command-Delete is a legitimate shortcut even for this recorder.
        #expect(model.handle(keyCode: HotkeyRecorderModel.deleteKeyCode, modifiers: cmd))
        #expect(commits.all == [HotkeyCombo(keyCode: 51, modifiers: cmd)])
        #expect(model.displayText == "⌘⌫")
        model.clear()
        #expect(commits.all.count == 1, "clear is a no-op when not allowed")
    }

    @Test(arguments: [UInt(0), HotkeyCombo.shift, UInt(1 << 23)])
    func aKeyWithoutAPrimaryModifierIsRejectedAndRecordingContinues(modifiers: UInt) {
        let commits = Commits()
        let model = makeModel(commits: commits)
        model.beginRecording()
        #expect(model.handle(keyCode: 11, modifiers: modifiers))
        #expect(model.isRecording)
        #expect(model.message == "Hold Command, Option, or Control with the key.")
        #expect(model.combo == .defaultToggle)
        #expect(commits.all.isEmpty)
    }

    @Test func aValidComboCommitsWithNonShortcutFlagsStripped() {
        let commits = Commits()
        let model = makeModel(combo: nil, commits: commits)
        model.beginRecording()
        model.flagsChanged(modifiers: cmd | opt)
        #expect(model.handle(keyCode: 46, modifiers: cmd | opt | fn | (1 << 21)))
        let expected = HotkeyCombo(keyCode: 46, modifiers: cmd | opt)
        #expect(commits.all == [expected])
        #expect(model.combo == expected)
        #expect(!model.isRecording)
        #expect(model.message == nil)
        #expect(model.heldModifiers == 0)
        #expect(model.displayText == "⌥⌘M")
        #expect(model.canClear)
    }

    @Test func aConflictingComboShowsTheReasonAndAFreeOneThenCommits() {
        let commits = Commits()
        let taken = HotkeyCombo(keyCode: 46, modifiers: cmd | opt)
        let model = makeModel(combo: nil, conflict: { combo in
            if combo == taken { return .item(ownerKey: "Maccy") }
            if combo == .defaultToggle { return .toggleBar }
            return nil
        }, commits: commits)
        model.beginRecording()
        #expect(model.handle(keyCode: 46, modifiers: cmd | opt))
        #expect(model.message == "Already used by Maccy.")
        #expect(model.isRecording)
        #expect(model.handle(keyCode: 11, modifiers: cmd | opt))
        #expect(model.message == "Already used to toggle the bar.")
        #expect(model.isRecording)
        #expect(commits.all.isEmpty)
        #expect(model.handle(keyCode: 34, modifiers: cmd | opt))
        #expect(commits.all == [HotkeyCombo(keyCode: 34, modifiers: cmd | opt)])
        #expect(model.message == nil)
        #expect(!model.isRecording)
    }

    @Test func systemReservedCombosAreRefusedEvenWhenTheConflictCheckAllowsThem() {
        let commits = Commits()
        let model = makeModel(combo: nil, commits: commits)
        model.beginRecording()
        #expect(model.handle(keyCode: 12, modifiers: cmd)) // Cmd-Q
        #expect(model.message == "That shortcut is reserved by macOS.")
        #expect(model.isRecording)
        #expect(model.handle(keyCode: 53, modifiers: cmd | opt)) // Option-Cmd-Esc
        #expect(model.message == "That shortcut is reserved by macOS.")
        #expect(commits.all.isEmpty)
    }

    @Test func unnamedKeysAndModifierKeysDoNotCompleteAShortcut() {
        let commits = Commits()
        let model = makeModel(combo: nil, commits: commits)
        model.beginRecording()
        // Keypad 0 has no display name.
        #expect(model.handle(keyCode: 82, modifiers: cmd))
        #expect(model.message == "That key can't be used for a shortcut.")
        #expect(model.isRecording)
        // The Command key itself (55) arrives as a key event on some paths; it is never a shortcut.
        #expect(model.handle(keyCode: 55, modifiers: cmd))
        #expect(model.isRecording)
        #expect(commits.all.isEmpty)
    }

    @Test func keysAreNotConsumedWhileIdle() {
        let commits = Commits()
        let model = makeModel(commits: commits)
        #expect(!model.handle(keyCode: 11, modifiers: cmd | opt))
        model.flagsChanged(modifiers: cmd)
        #expect(model.heldModifiers == 0)
        #expect(commits.all.isEmpty)
        #expect(model.combo == .defaultToggle)
    }

    @Test func externalUpdatesAndRedundantClearsNeverCommit() {
        let commits = Commits()
        let model = makeModel(combo: nil, commits: commits)
        model.clear()
        #expect(commits.all.isEmpty)
        model.update(combo: .defaultToggle)
        #expect(model.combo == .defaultToggle)
        #expect(model.displayText == "⌥⌘B")
        #expect(commits.all.isEmpty)
        model.beginRecording()
        model.update(combo: nil)
        #expect(model.isRecording, "an external update does not interrupt recording")
        model.cancelRecording()
        #expect(model.displayText == "None")
    }

    @Test func beginRecordingClearsAStaleMessage() {
        let model = makeModel()
        model.beginRecording()
        model.handle(keyCode: 11, modifiers: 0)
        #expect(model.message != nil)
        model.cancelRecording()
        model.beginRecording()
        #expect(model.message == nil)
    }
}

/// Off-screen rendering of the General-tab shortcut sections through the shared Settings harness.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ShortcutsSettingsSectionTests {
    private final class Writes {
        var all: [Preferences] = []
        var count: Int { all.count }
    }

    private let maccy = HotkeyCombo(keyCode: 46, modifiers: HotkeyCombo.command | HotkeyCombo.option)

    private func makeModel(
        _ preferences: Preferences = .default, items: [FloatingBarItem] = [], writes: Writes = Writes()
    ) async -> SettingsModel {
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { items },
            onChange: { writes.all.append($0) }
        )
        await model.reloadItems()
        return model
    }

    private func host(_ model: SettingsModel, failures: [String] = []) -> SettingsTestHostingController {
        settingsTestHost(
            Form { ShortcutsSettingsSection(model: model, failures: failures) }
                .formStyle(.grouped)
                .frame(width: 640)
        )
    }

    private func identifiers(in view: NSView) -> [String] {
        settingsTestAccessibility(view).compactMap { $0.accessibilityIdentifier() }
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier })
    }

    private func text(_ identifier: String, in view: NSView) throws -> String {
        settingsTestAccessibilityText(try element(identifier, in: view))
    }

    /// Re-renders until the condition holds; bounded by iterations, never by wall-clock waits.
    private func settle(_ hosting: SettingsTestHostingController, until condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            hosting.render()
            if condition() { return true }
            await Task.yield()
        }
        hosting.render()
        return condition()
    }

    /// An item sharing owner "Item 1" with `settingsTestItem(1)` (a second window of the same app).
    private func siblingOfItemOne(windowID: CGWindowID) -> FloatingBarItem {
        FloatingBarItem(
            snapshot: MenuBarItemSnapshot(windowID: windowID, ownerPID: 1, ownerBundleID: "Item 1", frame: .zero),
            image: NSImage(size: CGSize(width: 18, height: 18))
        )
    }

    @Test func toggleShortcutShowsARecorderWithTheCurrentComboAndNoClearButton() async throws {
        let hosting = host(await makeModel())
        let ids = identifiers(in: hosting.view)
        #expect(ids.contains("settings-shortcut-toggle-enabled"))
        #expect(ids.contains("settings-shortcut-toggle-value"))
        #expect(ids.contains("settings-shortcut-toggle-record"))
        #expect(!ids.contains("settings-shortcut-toggle-clear"))
        #expect(!ids.contains("settings-shortcut-toggle-unavailable"))
        #expect(!ids.contains("settings-shortcut-toggle-message"))
        #expect(try text("settings-shortcut-toggle-value", in: hosting.view).contains("⌥⌘B"))
        #expect(try element("settings-shortcut-toggle-record", in: hosting.view).isAccessibilityEnabled())
        #expect(ids.contains("settings-shortcut-items-hint"))
        #expect(try text("settings-shortcut-items-hint", in: hosting.view).contains("Needs Accessibility"))
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func turningTheToggleShortcutOffHidesItsRecorderWithOneWrite() async throws {
        let writes = Writes()
        let model = await makeModel(writes: writes)
        let hosting = host(model)
        _ = try element("settings-shortcut-toggle-enabled", in: hosting.view).accessibilityPerformPress()
        #expect(await settle(hosting) {
            !model.preferences.enableGlobalHotkey && !identifiers(in: hosting.view).contains("settings-shortcut-toggle-value")
        })
        #expect(writes.count == 1)
        #expect(writes.all.last?.enableGlobalHotkey == false)
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-toggle-record"))
    }

    @Test func recordEntersRecordingModeAndCancelLeavesTheShortcutAlone() async throws {
        let writes = Writes()
        let model = await makeModel(writes: writes)
        let hosting = host(model)
        #expect(try element("settings-shortcut-toggle-record", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) {
            (try? text("settings-shortcut-toggle-value", in: hosting.view))?.contains("Press shortcut...") == true
        })
        #expect(try text("settings-shortcut-toggle-record", in: hosting.view).contains("Cancel"))

        #expect(try element("settings-shortcut-toggle-record", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) {
            (try? text("settings-shortcut-toggle-value", in: hosting.view))?.contains("⌥⌘B") == true
        })
        #expect(try text("settings-shortcut-toggle-record", in: hosting.view).contains("Record"))
        #expect(writes.count == 0)
        #expect(model.preferences.toggleHotkey == .defaultToggle)
    }

    @Test func itemRowsListEachOwnerOnceWithAliasAwareNamesAndUnsetRecorders() async throws {
        var preferences = Preferences.default
        preferences.itemAliases.setAlias("Clipboard", forKey: "Item 2")
        let items = [settingsTestItem(1), settingsTestItem(2), siblingOfItemOne(windowID: 3)]
        let model = await makeModel(preferences, items: items)
        let hosting = host(model)
        let ids = identifiers(in: hosting.view)
        #expect(ids.filter { $0.hasSuffix("-name") } == ["settings-shortcut-item-Item 1-name", "settings-shortcut-item-Item 2-name"])
        #expect(try text("settings-shortcut-item-Item 1-name", in: hosting.view).contains("Item 1"))
        #expect(try text("settings-shortcut-item-Item 2-name", in: hosting.view).contains("Clipboard"))
        #expect(try text("settings-shortcut-item-Item 1-value", in: hosting.view).contains("None"))
        #expect(try text("settings-shortcut-item-Item 2-value", in: hosting.view).contains("None"))
        #expect(ids.contains("settings-shortcut-item-Item 1-record"))
        #expect(ids.contains("settings-shortcut-item-Item 2-record"))
        #expect(!ids.contains("settings-shortcut-item-Item 1-clear"), "nothing to clear yet")
        #expect(!ids.contains { $0.hasSuffix("-absent") || $0.hasSuffix("-inactive") || $0.hasSuffix("-unavailable") })
        #expect(!ids.contains("settings-shortcut-items-empty"))
        #expect(ShortcutsSettingsSection.rows(for: model).map(\.key) == ["Item 1", "Item 2"])
    }

    @Test func clearingAnItemShortcutWritesOnceAndRemovesTheEntry() async throws {
        var preferences = Preferences.default
        preferences.itemHotkeys = ["Item 1": maccy, "Item 2": HotkeyCombo(keyCode: 34, modifiers: HotkeyCombo.command | HotkeyCombo.option)]
        let writes = Writes()
        let model = await makeModel(preferences, items: [settingsTestItem(1), settingsTestItem(2)], writes: writes)
        let hosting = host(model)
        #expect(try text("settings-shortcut-item-Item 1-value", in: hosting.view).contains("⌥⌘M"))
        #expect(try element("settings-shortcut-item-Item 1-clear", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) { model.preferences.itemHotkeys["Item 1"] == nil })
        #expect(writes.count == 1)
        #expect(writes.all.last?.itemHotkeys == ["Item 2": HotkeyCombo(keyCode: 34, modifiers: HotkeyCombo.command | HotkeyCombo.option)])
        #expect(await settle(hosting) {
            (try? text("settings-shortcut-item-Item 1-value", in: hosting.view))?.contains("None") == true
        })
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-item-Item 1-clear"))
        #expect(try text("settings-shortcut-item-Item 2-value", in: hosting.view).contains("⌥⌘I"))
        #expect(!model.hasPendingChanges)
    }

    @Test func aSavedShortcutForAnAbsentItemStaysListedUntilCleared() async throws {
        var preferences = Preferences.default
        preferences.itemHotkeys = ["Gone": maccy]
        preferences.itemAliases.setAlias("Old Clipboard", forKey: "Gone")
        let writes = Writes()
        let model = await makeModel(preferences, items: [settingsTestItem(1)], writes: writes)
        let hosting = host(model)
        #expect(ShortcutsSettingsSection.rows(for: model) == [
            .init(key: "Item 1", name: "Item 1", isPresent: true),
            .init(key: "Gone", name: "Old Clipboard", isPresent: false),
        ])
        #expect(identifiers(in: hosting.view).contains("settings-shortcut-item-Gone-absent"))
        #expect(try text("settings-shortcut-item-Gone-name", in: hosting.view).contains("Old Clipboard"))
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-item-Item 1-absent"))

        #expect(try element("settings-shortcut-item-Gone-clear", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) {
            model.preferences.itemHotkeys.isEmpty && !identifiers(in: hosting.view).contains("settings-shortcut-item-Gone-name")
        })
        #expect(writes.count == 1)
        #expect(identifiers(in: hosting.view).contains("settings-shortcut-item-Item 1-name"))
    }

    @Test func inactiveAndUnavailableNotesAppearOnlyWhereTheyApply() async throws {
        var preferences = Preferences.default
        preferences.itemHotkeys = ["Item 1": .defaultToggle, "Item 2": maccy, "Item 3": maccy]
        let items = [settingsTestItem(1), settingsTestItem(2), settingsTestItem(3)]
        let model = await makeModel(preferences, items: items)
        let hosting = host(model, failures: ["Item 2", HotkeyService.toggleFailureIdentifier])
        let ids = identifiers(in: hosting.view)
        #expect(ids.contains("settings-shortcut-toggle-unavailable"))
        #expect(try text("settings-shortcut-toggle-unavailable", in: hosting.view).contains("possibly claimed by another app"))
        #expect(ids.contains("settings-shortcut-item-Item 2-unavailable"))
        #expect(!ids.contains("settings-shortcut-item-Item 1-unavailable"))
        #expect(!ids.contains("settings-shortcut-item-Item 3-unavailable"))
        #expect(try text("settings-shortcut-item-Item 1-inactive", in: hosting.view).contains("same as the toggle-bar shortcut"))
        #expect(try text("settings-shortcut-item-Item 3-inactive", in: hosting.view).contains("Item 2 uses the same shortcut"))
        #expect(!ids.contains("settings-shortcut-item-Item 2-inactive"))
        #expect(model.itemHotkeyPlan.items.map(\.ownerKey) == ["Item 2"])

        // Turning the toggle shortcut off frees its combo for Item 1.
        model.preferences.enableGlobalHotkey = false
        #expect(await settle(hosting) { !identifiers(in: hosting.view).contains("settings-shortcut-item-Item 1-inactive") })
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-toggle-unavailable"))
        #expect(model.itemHotkeyPlan.items.map(\.ownerKey) == ["Item 1", "Item 2"])
    }

    @Test func reflowModeShowsOneSectionNoteInsteadOfPerRowReasons() async throws {
        var preferences = Preferences.default
        preferences.useFloatingBar = false
        preferences.itemHotkeys = ["Item 1": .defaultToggle, "Item 2": maccy]
        let writes = Writes()
        let model = await makeModel(preferences, items: [settingsTestItem(1), settingsTestItem(2)], writes: writes)
        let hosting = host(model)
        let ids = identifiers(in: hosting.view)
        #expect(ids.contains("settings-shortcut-items-requires-floating-bar"))
        #expect(try text("settings-shortcut-items-requires-floating-bar", in: hosting.view)
            .contains("Not active: item shortcuts need the floating bar"))
        #expect(ids.filter { $0 == "settings-shortcut-items-requires-floating-bar" }.count == 1)
        #expect(!ids.contains { $0.hasSuffix("-inactive") }, "the section note replaces every per-row reason")
        // Recorders stay editable so a shortcut can be prepared or cleared before switching modes.
        #expect(ids.contains("settings-shortcut-item-Item 1-record"))
        #expect(ids.contains("settings-shortcut-item-Item 2-clear"))
        #expect(try text("settings-shortcut-item-Item 2-value", in: hosting.view).contains("⌥⌘M"))
        #expect(model.itemHotkeyPlan.items.isEmpty)
        #expect(model.itemHotkeyPlan.skipped == ["Item 1": .requiresFloatingBar, "Item 2": .requiresFloatingBar])
        #expect(writes.count == 0)

        // Turning the floating bar back on restores the per-row reasons and drops the note.
        model.preferences.useFloatingBar = true
        #expect(await settle(hosting) {
            !identifiers(in: hosting.view).contains("settings-shortcut-items-requires-floating-bar")
                && identifiers(in: hosting.view).contains("settings-shortcut-item-Item 1-inactive")
        })
        #expect(try text("settings-shortcut-item-Item 1-inactive", in: hosting.view).contains("same as the toggle-bar shortcut"))
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-item-Item 2-inactive"))
        #expect(model.itemHotkeyPlan.items.map(\.ownerKey) == ["Item 2"])
        #expect(writes.count == 1)
    }

    @Test func emptyAndLoadingStatesAreExplained() async throws {
        let model = await makeModel()
        let hosting = host(model)
        #expect(identifiers(in: hosting.view).contains("settings-shortcut-items-empty"))
        #expect(try text("settings-shortcut-items-empty", in: hosting.view).contains("No manageable items found."))
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-items-loading"))
    }

    @Test func theSectionLoadsItemsItselfAndShowsALoadingStateMeanwhile() async throws {
        // The Items tab normally loads the list; General may be shown first, so the section must ask.
        let gate = AsyncGate()
        var reads = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; await gate.wait(); return [settingsTestItem(1)] },
            onChange: { _ in }
        )
        #expect(model.itemsLoading)
        let hosting = host(model)
        #expect(await settle(hosting) { reads == 1 && identifiers(in: hosting.view).contains("settings-shortcut-items-loading") })
        #expect(try text("settings-shortcut-items-loading", in: hosting.view).contains("Reading the menu bar"))
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-items-empty"))

        await gate.open()
        #expect(await settle(hosting) { identifiers(in: hosting.view).contains("settings-shortcut-item-Item 1-name") })
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-items-loading"))
        #expect(!identifiers(in: hosting.view).contains("settings-shortcut-items-empty"))
        #expect(reads == 1)
    }

    @Test func modelCommitHelpersWriteOnceAndSkipIdenticalValues() {
        let writes = Writes()
        var preferences = Preferences.default
        preferences.autoRehide = false
        preferences.itemAliases.setAlias("Clipboard", forKey: "Item 1")
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { writes.all.append($0) }
        )
        model.setToggleHotkey(.defaultToggle)
        #expect(writes.count == 0)
        model.setItemHotkey(maccy, forOwnerKey: "Item 1")
        model.setItemHotkey(maccy, forOwnerKey: "Item 1")
        #expect(writes.count == 1)
        #expect(writes.all.last?.itemHotkeys == ["Item 1": maccy])
        let toggle = HotkeyCombo(keyCode: 34, modifiers: HotkeyCombo.command | HotkeyCombo.control)
        model.setToggleHotkey(toggle)
        #expect(writes.count == 2)
        #expect(writes.all.last?.toggleHotkey == toggle)
        model.setItemHotkey(nil, forOwnerKey: "Item 1")
        model.setItemHotkey(nil, forOwnerKey: "Item 1")
        model.setItemHotkey(nil, forOwnerKey: "Never")
        #expect(writes.count == 3)
        #expect(writes.all.last?.itemHotkeys.isEmpty == true)
        var expected = preferences
        expected.toggleHotkey = toggle
        #expect(writes.all.last == expected)
        #expect(!model.hasPendingChanges)
    }

    @Test func inactiveTextCoversEverySkipReason() {
        #expect(ShortcutsSettingsSection.inactiveText(for: .notAssignable).contains("not usable"))
        #expect(ShortcutsSettingsSection.inactiveText(for: .conflict(.systemReserved)).contains("reserved by macOS"))
        #expect(ShortcutsSettingsSection.inactiveText(for: .conflict(.toggleBar)).contains("toggle-bar"))
        #expect(ShortcutsSettingsSection.inactiveText(for: .conflict(.item(ownerKey: "Maccy"))).contains("Maccy"))
        #expect(ShortcutsSettingsSection.inactiveText(for: .overCapacity).contains("32"))
        #expect(ShortcutsSettingsSection.inactiveText(for: .requiresFloatingBar) == ShortcutsSettingsSection.requiresFloatingBarText)
        #expect(ShortcutsSettingsSection.requiresFloatingBarText == "Not active: item shortcuts need the floating bar.")
    }
}

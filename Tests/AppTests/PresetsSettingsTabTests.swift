import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PresetsSettingsTabTests {

    @Test func emptyStateShowsGuidanceAndDisablesSaveUntilANameIsTyped() throws {
        var writes: [Preferences] = []
        let model = makeModel(.default) { writes.append($0) }
        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        let elements = settingsTestAccessibility(hosting.view)
        let identifiers = elements.compactMap { $0.accessibilityIdentifier() }
        for identifier in [
            "settings-preset-content", "settings-preset-header", "settings-preset-new-name",
            "settings-preset-save", "settings-preset-empty", "settings-preset-footer"
        ] {
            #expect(identifiers.contains(identifier), "\(identifier) must be present")
        }
        #expect(!identifiers.contains("settings-preset-list"))
        #expect(!identifiers.contains("settings-preset-save-error"))
        #expect(!identifiers.contains { $0.hasPrefix("settings-preset-row-") })
        let text = elements.map { settingsTestAccessibilityText($0) }.joined(separator: " ")
        #expect(text.contains("No presets yet."))
        #expect(text.contains("Accessibility"))
        #expect(text.contains("moves items"))

        let save = try element("settings-preset-save", in: hosting.view)
        #expect(!save.isAccessibilityEnabled())
        #expect(!save.accessibilityPerformPress())
        #expect(writes.isEmpty)
        #expect(model.preferences == .default)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func savingWritesExactlyOnePreferencesChangeContainingTheNewPreset() async throws {
        var preferences = Preferences.default
        preferences.itemControls.setHidden(true, forKey: "ACME")
        preferences.itemControls.setHidden(false, forKey: "Maccy")
        preferences.itemAliases.setAlias("Clipboard", forKey: "Maccy")
        var writes: [Preferences] = []
        let model = makeModel(preferences) { writes.append($0) }
        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        let window = hosting.testWindow!
        let field = try newNameField(in: hosting.view)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        // The off-screen field editor drives the real binding without posting keyboard events.
        editor.insertText("  Focus  ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) { isEnabled("settings-preset-save", in: hosting.view) })
        #expect(!has("settings-preset-save-error", in: hosting.view))
        #expect(window.makeFirstResponder(nil))
        #expect(writes.isEmpty)

        #expect(try element("settings-preset-save", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { writes.count == 1 && field.stringValue.isEmpty })
        let saved = try #require(writes.first)
        let preset = try #require(saved.presets.first)
        #expect(saved.presets.count == 1)
        #expect(preset.name == "Focus")
        #expect(preset.itemControls == preferences.itemControls)
        var expected = preferences
        expected.presets = [preset]
        #expect(saved == expected)
        #expect(model.preferences == expected)

        #expect(await waitForUpdate(hosting.view) { has("settings-preset-row-\(preset.id)", in: hosting.view) })
        let identifiers = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        for suffix in ["row", "name", "counts", "active", "apply", "update", "delete"] {
            #expect(identifiers.contains("settings-preset-\(suffix)-\(preset.id)"), "\(suffix) control must be present")
        }
        #expect(identifiers.contains("settings-preset-list"))
        #expect(!identifiers.contains("settings-preset-empty"))
        let counts = try element("settings-preset-counts-\(preset.id)", in: hosting.view)
        #expect(settingsTestAccessibilityText(counts).contains("1 hidden, 1 shown"))
        #expect(try element("settings-preset-name-\(preset.id)", in: hosting.view).accessibilityLabel() == "Name of preset Focus")
        // A freshly saved preset matches the saved arrangement, so applying or updating it is a no-op.
        #expect(!isEnabled("settings-preset-apply-\(preset.id)", in: hosting.view))
        #expect(!isEnabled("settings-preset-update-\(preset.id)", in: hosting.view))
        #expect(isEnabled("settings-preset-delete-\(preset.id)", in: hosting.view))
        #expect(!isEnabled("settings-preset-save", in: hosting.view))
        #expect(writes.count == 1)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test func duplicateBlankAndOverlongNamesDisableSaveWithAReason() async throws {
        var preferences = Preferences.default
        preferences.presets = [LayoutPreset(name: "Focus", itemControls: ItemControlStore(hiddenInMenuBar: ["ACME"]))]
        var writes = 0
        let model = makeModel(preferences) { _ in writes += 1 }
        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        let window = hosting.testWindow!
        let field = try newNameField(in: hosting.view)

        for (typed, reason) in [
            (" focus ", "already exists"),
            (String(repeating: "x", count: 61), "60"),
            ("   ", "Enter a preset name.")
        ] {
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText(typed, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            #expect(await waitForUpdate(hosting.view) {
                settingsTestAccessibility(hosting.view).contains {
                    $0.accessibilityIdentifier() == "settings-preset-save-error"
                        && settingsTestAccessibilityText($0).contains(reason)
                }
            }, "typing \(typed.debugDescription) must explain \(reason)")
            let save = try element("settings-preset-save", in: hosting.view)
            #expect(!save.isAccessibilityEnabled())
            #expect(!save.accessibilityPerformPress())
            // Return in the field routes through the same guarded save and must stay a no-op.
            editor.insertNewline(nil)
            hosting.render()
            #expect(writes == 0)
            #expect(model.preferences == preferences)
        }

        // Clearing the field returns to the untouched state: no reason is shown for an empty name.
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) { !has("settings-preset-save-error", in: hosting.view) })
        #expect(!isEnabled("settings-preset-save", in: hosting.view))

        editor.insertText("Meeting", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) { isEnabled("settings-preset-save", in: hosting.view) })
        #expect(!has("settings-preset-save-error", in: hosting.view))
        #expect(writes == 0)
        #expect(!window.isVisible)
    }

    @Test func applyWritesExactlyOneChangeWithReplacedControlsAndUnchangedAliases() async throws {
        let item = settingsTestItem(1, observedHidden: false)
        var preferences = Preferences.default
        preferences.itemControls.setHidden(true, forKey: "ACME")
        preferences.itemAliases.setAlias("Clipboard", forKey: "Maccy")
        preferences.autoRehide = false
        let current = LayoutPreset(name: "Current", itemControls: preferences.itemControls)
        let target = LayoutPreset(
            name: "Meeting", itemControls: ItemControlStore(hiddenInMenuBar: ["Maccy"], shownInMenuBar: ["ACME"])
        )
        preferences.presets = [current, target]
        var writes: [Preferences] = []
        let model = makeModel(preferences, items: [item]) { writes.append($0) }
        await model.reloadItems()
        model.setHidden(true, for: item)
        #expect(model.hasPendingChanges)

        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        #expect(has("settings-preset-active-\(current.id)", in: hosting.view))
        #expect(!has("settings-preset-active-\(target.id)", in: hosting.view))
        #expect(!isEnabled("settings-preset-apply-\(current.id)", in: hosting.view))
        let apply = try element("settings-preset-apply-\(target.id)", in: hosting.view)
        #expect(apply.isAccessibilityEnabled())
        #expect(writes.isEmpty)

        #expect(apply.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { writes.count == 1 })
        var expected = preferences
        expected.itemControls = target.itemControls
        #expect(writes == [expected])
        #expect(model.preferences == expected)
        #expect(model.preferences.itemAliases == preferences.itemAliases)
        #expect(model.preferences.presets == preferences.presets)
        #expect(!model.preferences.autoRehide)
        // A changed Hidden set discards the Items-tab draft, so stale edits cannot be applied later.
        #expect(!model.hasPendingChanges)

        #expect(await waitForUpdate(hosting.view) {
            has("settings-preset-active-\(target.id)", in: hosting.view)
                && !has("settings-preset-active-\(current.id)", in: hosting.view)
                && !isEnabled("settings-preset-apply-\(target.id)", in: hosting.view)
                && isEnabled("settings-preset-apply-\(current.id)", in: hosting.view)
        })
        // Pressing the now-disabled Apply of the active preset changes nothing.
        let disabledApply = try element("settings-preset-apply-\(target.id)", in: hosting.view)
        #expect(!disabledApply.accessibilityPerformPress())
        hosting.render()
        #expect(writes.count == 1)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func applyIsUnavailableWhilePlacementIsInProgressButOtherEditsRemain() async throws {
        var preferences = Preferences.default
        let preset = LayoutPreset(name: "Meeting", itemControls: ItemControlStore(hiddenInMenuBar: ["Maccy"]))
        preferences.presets = [preset]
        var writes: [Preferences] = []
        let model = makeModel(preferences) { writes.append($0) }
        model.placementInProgress = true
        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        let apply = try element("settings-preset-apply-\(preset.id)", in: hosting.view)
        #expect(!apply.isAccessibilityEnabled())
        #expect(!apply.accessibilityPerformPress())
        #expect(!has("settings-preset-active-\(preset.id)", in: hosting.view))
        // Editing the preset list never moves items, so it stays available during placement.
        #expect(isEnabled("settings-preset-update-\(preset.id)", in: hosting.view))
        #expect(isEnabled("settings-preset-delete-\(preset.id)", in: hosting.view))
        hosting.render()
        #expect(writes.isEmpty)
        #expect(model.preferences == preferences)

        model.placementInProgress = false
        #expect(await waitForUpdate(hosting.view) { isEnabled("settings-preset-apply-\(preset.id)", in: hosting.view) })
        #expect(try element("settings-preset-apply-\(preset.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { writes.count == 1 })
        var expected = preferences
        expected.itemControls = preset.itemControls
        #expect(writes == [expected])
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func deleteRequiresConfirmationAndCancelKeepsThePreset() async throws {
        var preferences = Preferences.default
        let keep = LayoutPreset(name: "Keep", itemControls: ItemControlStore(hiddenInMenuBar: ["ACME"]))
        let doomed = LayoutPreset(name: "Doomed", itemControls: ItemControlStore(hiddenInMenuBar: ["Maccy"]))
        preferences.presets = [keep, doomed]
        var writes: [Preferences] = []
        let model = makeModel(preferences) { writes.append($0) }
        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        #expect(!has("settings-preset-confirm-delete-\(doomed.id)", in: hosting.view))

        #expect(try element("settings-preset-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { has("settings-preset-confirm-delete-\(doomed.id)", in: hosting.view) })
        var identifiers = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        #expect(identifiers.contains("settings-preset-delete-prompt-\(doomed.id)"))
        #expect(identifiers.contains("settings-preset-cancel-delete-\(doomed.id)"))
        #expect(!identifiers.contains("settings-preset-apply-\(doomed.id)"))
        #expect(!identifiers.contains("settings-preset-delete-\(doomed.id)"))
        #expect(identifiers.contains("settings-preset-apply-\(keep.id)"))
        #expect(!identifiers.contains("settings-preset-confirm-delete-\(keep.id)"))
        let prompt = try element("settings-preset-delete-prompt-\(doomed.id)", in: hosting.view)
        #expect(settingsTestAccessibilityText(prompt).contains("Doomed"))
        #expect(writes.isEmpty)

        #expect(try element("settings-preset-cancel-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            has("settings-preset-apply-\(doomed.id)", in: hosting.view)
                && !has("settings-preset-confirm-delete-\(doomed.id)", in: hosting.view)
        })
        #expect(writes.isEmpty)
        #expect(model.preferences == preferences)

        #expect(try element("settings-preset-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { has("settings-preset-confirm-delete-\(doomed.id)", in: hosting.view) })
        #expect(try element("settings-preset-confirm-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            writes.count == 1 && !has("settings-preset-row-\(doomed.id)", in: hosting.view)
        })
        var expected = preferences
        expected.presets = [keep]
        #expect(writes == [expected])
        #expect(model.preferences == expected)
        identifiers = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        #expect(identifiers.contains("settings-preset-row-\(keep.id)"))
        #expect(identifiers.contains("settings-preset-list"))
        #expect(!identifiers.contains("settings-preset-empty"))

        // Deleting the last preset returns to the empty state.
        #expect(try element("settings-preset-delete-\(keep.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { has("settings-preset-confirm-delete-\(keep.id)", in: hosting.view) })
        #expect(try element("settings-preset-confirm-delete-\(keep.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            writes.count == 2 && has("settings-preset-empty", in: hosting.view) && !has("settings-preset-list", in: hosting.view)
        })
        expected.presets = []
        #expect(writes.last == expected)
        #expect(model.preferences == expected)
        #expect(model.preferences.itemControls == preferences.itemControls)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func renameCommitsOnReturnAndRejectsDuplicatesWithoutWriting() async throws {
        var preferences = Preferences.default
        let focus = LayoutPreset(name: "Focus", itemControls: ItemControlStore(hiddenInMenuBar: ["ACME"]))
        let meeting = LayoutPreset(name: "Meeting", itemControls: ItemControlStore(hiddenInMenuBar: ["Maccy"]))
        preferences.presets = [focus, meeting]
        var writes: [Preferences] = []
        let model = makeModel(preferences) { writes.append($0) }
        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        let window = hosting.testWindow!
        let field = try nameField("Focus", in: hosting.view)
        #expect(try element("settings-preset-name-\(focus.id)", in: hosting.view).accessibilityLabel() == "Name of preset Focus")

        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("  Deep Work ", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "  Deep Work " })
        // Typing alone never persists; the name commits on Return.
        #expect(writes.isEmpty)
        #expect(model.preferences == preferences)
        editor.insertNewline(nil)
        #expect(await waitForUpdate(hosting.view) { writes.count == 1 })
        var expected = preferences
        expected.presets[0].name = "Deep Work"
        #expect(writes == [expected])
        #expect(model.preferences == expected)
        #expect(model.preferences.presets.map(\.id) == [focus.id, meeting.id])
        #expect(model.preferences.presets[0].itemControls == focus.itemControls)
        #expect(await waitForUpdate(hosting.view) {
            field.stringValue == "Deep Work" && settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityIdentifier() == "settings-preset-name-\(focus.id)"
                    && $0.accessibilityLabel() == "Name of preset Deep Work"
            }
        })
        #expect(window.makeFirstResponder(nil))

        // A case-insensitive duplicate is rejected inline, keeps the typed text, and is never written.
        #expect(window.makeFirstResponder(field))
        let again = try #require(field.currentEditor() as? NSTextView)
        again.insertText("meeting", replacementRange: NSRange(location: 0, length: again.string.utf16.count))
        again.insertNewline(nil)
        #expect(await waitForUpdate(hosting.view) { has("settings-preset-name-error-\(focus.id)", in: hosting.view) })
        let error = try element("settings-preset-name-error-\(focus.id)", in: hosting.view)
        #expect(settingsTestAccessibilityText(error).contains("already exists"))
        #expect(field.stringValue == "meeting")
        #expect(writes.count == 1)
        #expect(window.makeFirstResponder(nil))
        hosting.render()
        #expect(writes.count == 1)
        #expect(model.preferences == expected)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test func updateFromCurrentReplacesThePresetControlsInOneWrite() async throws {
        var preferences = Preferences.default
        preferences.itemControls.setHidden(true, forKey: "ACME")
        let stale = LayoutPreset(name: "Stale", itemControls: ItemControlStore(hiddenInMenuBar: ["Maccy"]))
        let other = LayoutPreset(name: "Other", itemControls: ItemControlStore(shownInMenuBar: ["Maccy"]))
        preferences.presets = [stale, other]
        var writes: [Preferences] = []
        let model = makeModel(preferences) { writes.append($0) }
        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        #expect(!has("settings-preset-active-\(stale.id)", in: hosting.view))
        let staleCounts = try element("settings-preset-counts-\(stale.id)", in: hosting.view)
        let otherCounts = try element("settings-preset-counts-\(other.id)", in: hosting.view)
        #expect(settingsTestAccessibilityText(staleCounts).contains("1 hidden, 0 shown"))
        #expect(settingsTestAccessibilityText(otherCounts).contains("0 hidden, 1 shown"))

        #expect(try element("settings-preset-update-\(stale.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { writes.count == 1 })
        var expected = preferences
        expected.presets[0].itemControls = preferences.itemControls
        #expect(writes == [expected])
        #expect(model.preferences == expected)
        // The saved arrangement itself is untouched; only the preset changed.
        #expect(model.preferences.itemControls == preferences.itemControls)
        #expect(model.preferences.presets[0].id == stale.id)
        #expect(model.preferences.presets[0].name == "Stale")
        #expect(model.preferences.presets[1] == other)

        #expect(await waitForUpdate(hosting.view) {
            has("settings-preset-active-\(stale.id)", in: hosting.view)
                && !isEnabled("settings-preset-apply-\(stale.id)", in: hosting.view)
                && !isEnabled("settings-preset-update-\(stale.id)", in: hosting.view)
                && isEnabled("settings-preset-apply-\(other.id)", in: hosting.view)
                && isEnabled("settings-preset-update-\(other.id)", in: hosting.view)
        })
        let disabledUpdate = try element("settings-preset-update-\(stale.id)", in: hosting.view)
        #expect(!disabledUpdate.accessibilityPerformPress())
        hosting.render()
        #expect(writes.count == 1)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func saveIsUnavailableAtTheMaximumWithAnInlineReason() async throws {
        var preferences = Preferences.default
        preferences.presets = (0..<PresetLibrary.maxPresets).map {
            LayoutPreset(name: "Preset \($0)", itemControls: ItemControlStore(hiddenInMenuBar: ["owner.\($0)"]))
        }
        var writes = 0
        let model = makeModel(preferences) { _ in writes += 1 }
        let hosting = settingsTestHost(PresetsSettingsTab(model: model).frame(width: 640))
        let window = hosting.testWindow!
        #expect(!isEnabled("settings-preset-save", in: hosting.view))
        let reason = try element("settings-preset-save-error", in: hosting.view)
        #expect(settingsTestAccessibilityText(reason).contains("50"))

        // A valid, unique name does not help while the list is full.
        let field = try newNameField(in: hosting.view)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("One more", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "One more" })
        hosting.render()
        #expect(!isEnabled("settings-preset-save", in: hosting.view))
        let stillFull = try element("settings-preset-save-error", in: hosting.view)
        #expect(settingsTestAccessibilityText(stillFull).contains("50"))
        let save = try element("settings-preset-save", in: hosting.view)
        #expect(!save.accessibilityPerformPress())
        editor.insertNewline(nil)
        hosting.render()
        #expect(writes == 0)
        #expect(model.preferences == preferences)
        #expect(model.preferences.presets.count == 50)
        #expect(!window.isVisible)
    }

    // MARK: - Helpers

    private func makeModel(
        _ preferences: Preferences, items: [FloatingBarItem] = [], onChange: @escaping (Preferences) -> Void
    ) -> SettingsModel {
        SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { items }, onChange: onChange
        )
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier })
    }

    private func has(_ identifier: String, in view: NSView) -> Bool {
        settingsTestAccessibility(view).contains { $0.accessibilityIdentifier() == identifier }
    }

    private func isEnabled(_ identifier: String, in view: NSView) -> Bool {
        settingsTestAccessibility(view).contains {
            $0.accessibilityIdentifier() == identifier && $0.isAccessibilityEnabled()
        }
    }

    /// The save row's field is the only editable field without a stored name.
    private func newNameField(in view: NSView) throws -> NSTextField {
        try #require(settingsTestSubviews(view).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue.isEmpty })
    }

    private func nameField(_ name: String, in view: NSView) throws -> NSTextField {
        try #require(settingsTestSubviews(view).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue == name })
    }

    private func waitForUpdate(_ view: NSView, until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            (view as? NSHostingView<AnyView>)?._renderForTest(interval: 1.0 / 60)
            view.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while !Task.isCancelled && clock.now < deadline
        return false
    }
}

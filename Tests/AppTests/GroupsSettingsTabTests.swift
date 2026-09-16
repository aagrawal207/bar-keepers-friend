import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct GroupsSettingsTabTests {

    @Test func emptyStateExplainsGroupsAndOnlyOffersCreation() async throws {
        let writes = PreferenceWrites()
        let model = makeModel(items: [settingsTestItem(1)], writes: writes)
        await model.reloadItems()
        let hosting = groupsHost(model)
        let elements = settingsTestAccessibility(hosting.view)
        let identifiers = elements.compactMap { $0.accessibilityIdentifier() }
        for identifier in [
            "settings-group-content", "settings-group-new-name", "settings-group-create",
            "settings-group-empty", "settings-group-footer"
        ] {
            #expect(identifiers.contains(identifier), "\(identifier) must be present")
        }
        #expect(!identifiers.contains("settings-group-create-error"))
        #expect(!identifiers.contains("settings-group-list"))
        #expect(!identifiers.contains("settings-group-items-error"))
        let text = elements.map { settingsTestAccessibilityText($0) }.joined(separator: " ")
        #expect(text.contains("Grouped items open from one menu bar icon. Their saved Shown/Hidden choices are kept but do not apply while grouped."))
        #expect(text.contains("No groups yet."))
        #expect(text.contains("Group changes apply right away"))

        // An untouched empty name is not yet a mistake, but it cannot create a group either.
        let create = try element("settings-group-create", in: hosting.view)
        #expect(!create.isAccessibilityEnabled())
        #expect(!create.accessibilityPerformPress())
        hosting.render()
        #expect(model.preferences.itemGroups.isEmpty)
        #expect(writes.count == 0)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func creatingAGroupValidatesLiveAndWritesPreferencesOnce() async throws {
        let writes = PreferenceWrites()
        let model = makeModel(items: [settingsTestItem(1), settingsTestItem(2)], writes: writes)
        await model.reloadItems()
        let hosting = groupsHost(model)
        let window = hosting.testWindow!
        let field = try editableField(in: hosting.view, showing: "")
        let editor = try type("  Work ", into: field, in: window)
        #expect(await waitForUpdate(hosting.view) {
            field.stringValue == "  Work " && find("settings-group-create", in: hosting.view)?.isAccessibilityEnabled() == true
        })
        #expect(find("settings-group-create-error", in: hosting.view) == nil)
        #expect(model.preferences.itemGroups.isEmpty)
        #expect(writes.count == 0)

        // Return submits the trimmed name, clears the field, and replaces the empty state with the list.
        editor.insertNewline(nil)
        #expect(await waitForUpdate(hosting.view) {
            model.preferences.itemGroups.map(\.name) == ["Work"] && field.stringValue.isEmpty
        })
        #expect(writes.count == 1)
        #expect(writes.all.last?.itemGroups.map(\.name) == ["Work"])
        let group = try #require(model.preferences.itemGroups.first)
        #expect(group.ownerKeys.isEmpty)
        #expect(window.makeFirstResponder(nil))

        // A case-insensitive duplicate is refused live, and Return cannot force it through.
        let duplicateEditor = try type("work", into: field, in: window)
        #expect(await waitForUpdate(hosting.view) { find("settings-group-create-error", in: hosting.view) != nil })
        let error = try element("settings-group-create-error", in: hosting.view)
        #expect(settingsTestAccessibilityText(error).contains("already exists"))
        #expect(!(try element("settings-group-create", in: hosting.view)).isAccessibilityEnabled())
        duplicateEditor.insertNewline(nil)
        hosting.render()
        #expect(model.preferences.itemGroups.map(\.name) == ["Work"])
        #expect(writes.count == 1)
        #expect(model.preferences.itemControls == ItemControlStore())
        #expect(window.makeFirstResponder(nil))
        #expect(!window.isVisible)

        // The saved group renders as a section with a name field, count, delete, and one toggle per owner.
        let listed = groupsHost(model)
        let identifiers = settingsTestAccessibility(listed.view).compactMap { $0.accessibilityIdentifier() }
        #expect(identifiers.contains("settings-group-list"))
        #expect(!identifiers.contains("settings-group-empty"))
        for identifier in [
            "settings-group-name-\(group.id)", "settings-group-count-\(group.id)", "settings-group-delete-\(group.id)",
            "settings-group-member-\(group.id)-Item 1", "settings-group-member-\(group.id)-Item 2"
        ] {
            #expect(identifiers.contains(identifier), "\(identifier) must be present")
        }
        #expect(settingsTestAccessibilityText(try element("settings-group-count-\(group.id)", in: listed.view)).contains("0 items"))
        #expect(writes.count == 1)
        #expect(!listed.testWindow.isVisible)
    }

    @Test func renamingCommitsOnReturnAndKeepsAnInvalidNameLocal() async throws {
        let work = ItemGroup(name: "Work", ownerKeys: ["Item 1"])
        let home = ItemGroup(name: "Home")
        let writes = PreferenceWrites()
        let model = makeModel(groups: [work, home], items: [settingsTestItem(1)], writes: writes)
        let initial = model.preferences
        await model.reloadItems()
        let hosting = groupsHost(model)
        let window = hosting.testWindow!
        #expect(try element("settings-group-name-\(work.id)", in: hosting.view).accessibilityLabel() == "Name of group Work")
        let field = try editableField(in: hosting.view, showing: "Work")

        // Typing alone never persists; Return saves the trimmed name and keeps identity and members.
        var editor = try type("  Focus ", into: field, in: window)
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "  Focus " })
        #expect(model.preferences.itemGroups.map(\.name) == ["Work", "Home"])
        #expect(writes.count == 0)
        editor.insertNewline(nil)
        #expect(await waitForUpdate(hosting.view) {
            model.preferences.itemGroups.map(\.name) == ["Focus", "Home"] && field.stringValue == "Focus"
        })
        #expect(writes.count == 1)
        #expect(model.preferences.itemGroups[0].id == work.id)
        #expect(model.preferences.itemGroups[0].ownerKeys == ["Item 1"])
        #expect(model.preferences.itemGroups[1] == home)
        #expect(await waitForUpdate(hosting.view) {
            find("settings-group-name-\(work.id)", in: hosting.view)?.accessibilityLabel() == "Name of group Focus"
        })
        #expect(window.makeFirstResponder(nil))

        // A duplicate stays in the field with an inline error; neither Return nor blur writes it.
        editor = try type("home", into: field, in: window)
        editor.insertNewline(nil)
        #expect(await waitForUpdate(hosting.view) { find("settings-group-name-error-\(work.id)", in: hosting.view) != nil })
        #expect(settingsTestAccessibilityText(try element("settings-group-name-error-\(work.id)", in: hosting.view)).contains("already exists"))
        #expect(field.stringValue == "home")
        #expect(window.makeFirstResponder(nil))
        hosting.render()
        #expect(model.preferences.itemGroups.map(\.name) == ["Focus", "Home"])
        #expect(writes.count == 1)

        // Fixing the name commits exactly once more and clears the error.
        editor = try type("Focus time", into: field, in: window)
        editor.insertNewline(nil)
        #expect(await waitForUpdate(hosting.view) {
            model.preferences.itemGroups.map(\.name) == ["Focus time", "Home"]
                && find("settings-group-name-error-\(work.id)", in: hosting.view) == nil
        })
        #expect(writes.count == 2)
        #expect(window.makeFirstResponder(nil))

        // The same draft becomes valid when the conflicting group is deleted; retry must clear its error.
        editor = try type("home", into: field, in: window)
        editor.insertNewline(nil)
        try #require(await waitForUpdate(hosting.view) {
            find("settings-group-name-error-\(work.id)", in: hosting.view) != nil
        })
        #expect(field.stringValue == "home")
        #expect(writes.count == 2)
        #expect(try element("settings-group-delete-\(home.id)", in: hosting.view).accessibilityPerformPress())
        try #require(await waitForUpdate(hosting.view) {
            find("settings-group-confirm-delete-\(home.id)", in: hosting.view) != nil
        })
        #expect(try element("settings-group-confirm-delete-\(home.id)", in: hosting.view).accessibilityPerformPress())
        try #require(await waitForUpdate(hosting.view) { model.preferences.itemGroups.count == 1 })
        #expect(field.stringValue == "home")
        #expect(writes.count == 3)
        #expect(window.makeFirstResponder(field))
        let retryEditor = try #require(window.fieldEditor(true, for: field) as? NSTextView)
        retryEditor.insertNewline(nil)
        try #require(await waitForUpdate(hosting.view) {
            model.preferences.itemGroups[0].name == "home"
                && find("settings-group-name-error-\(work.id)", in: hosting.view) == nil
        })
        let expectedWrites = [("Focus", true), ("Focus time", true), ("Focus time", false), ("home", false)].map { name, includeHome in
            var preferences = initial
            var renamed = work
            renamed.name = name
            preferences.itemGroups = includeHome ? [renamed, home] : [renamed]
            return preferences
        }
        #expect(writes.all == expectedWrites)
        #expect(field.stringValue == "home")
        #expect(window.makeFirstResponder(nil))
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test func deletingAGroupNeedsConfirmationAndWritesOnce() async throws {
        let work = ItemGroup(name: "Work", ownerKeys: ["Item 1", "Ghost"])
        let home = ItemGroup(name: "Home", ownerKeys: ["Item 2"])
        var preferences = Preferences.default
        preferences.itemControls.setHidden(false, forKey: "Item 1")
        let writes = PreferenceWrites()
        let model = makeModel(
            preferences: preferences, groups: [work, home],
            items: [settingsTestItem(1), settingsTestItem(2)], writes: writes
        )
        await model.reloadItems()
        let hosting = groupsHost(model)
        #expect(find("settings-group-confirm-delete-\(work.id)", in: hosting.view) == nil)

        #expect(try element("settings-group-delete-\(work.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-group-confirm-delete-\(work.id)", in: hosting.view) != nil })
        let prompt = try element("settings-group-delete-prompt-\(work.id)", in: hosting.view)
        #expect(settingsTestAccessibilityText(prompt).contains("Delete \"Work\"?"))
        #expect(find("settings-group-confirm-delete-\(home.id)", in: hosting.view) == nil)
        #expect(writes.count == 0)

        // Cancel restores the plain Delete button without touching preferences.
        #expect(try element("settings-group-cancel-delete-\(work.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            find("settings-group-confirm-delete-\(work.id)", in: hosting.view) == nil
                && find("settings-group-delete-\(work.id)", in: hosting.view) != nil
        })
        #expect(model.preferences.itemGroups == [work, home])
        #expect(writes.count == 0)

        #expect(try element("settings-group-delete-\(work.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-group-confirm-delete-\(work.id)", in: hosting.view) != nil })
        #expect(try element("settings-group-confirm-delete-\(work.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            model.preferences.itemGroups == [home] && find("settings-group-name-\(work.id)", in: hosting.view) == nil
        })
        #expect(writes.count == 1)
        #expect(find("settings-group-name-\(home.id)", in: hosting.view) != nil)
        #expect(model.preferences.itemGroups[0].ownerKeys == ["Item 2"])
        // Ungrouping restores whatever intent the user saved; it never edits that intent.
        #expect(model.preferences.itemControls == preferences.itemControls)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func checkingAMemberMovesItBetweenGroupsWithOneWriteEach() async throws {
        let work = ItemGroup(name: "Work", ownerKeys: ["Item 1"])
        let home = ItemGroup(name: "Home")
        let writes = PreferenceWrites()
        let model = makeModel(groups: [work, home], items: [settingsTestItem(1), settingsTestItem(2)], writes: writes)
        await model.reloadItems()
        model.setHidden(true, for: model.loadedItems[1])
        #expect(model.hasPendingChanges)
        let hosting = groupsHost(model)
        let elsewhereInHome = try element("settings-group-member-elsewhere-\(home.id)-Item 1", in: hosting.view)
        #expect(settingsTestAccessibilityText(elsewhereInHome).contains("In Work"))
        #expect(find("settings-group-member-elsewhere-\(work.id)-Item 1", in: hosting.view) == nil)
        let homeToggle = try element("settings-group-member-\(home.id)-Item 1", in: hosting.view)
        #expect(homeToggle.isAccessibilityEnabled())
        #expect(homeToggle.accessibilityLabel() == "Item 1, in Work")

        // Checking in Home takes the key away from Work in the same single write.
        #expect(homeToggle.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { model.preferences.itemGroups.map(\.ownerKeys) == [[], ["Item 1"]] })
        #expect(writes.count == 1)
        #expect(await waitForUpdate(hosting.view) {
            find("settings-group-member-elsewhere-\(work.id)-Item 1", in: hosting.view) != nil
                && find("settings-group-member-elsewhere-\(home.id)-Item 1", in: hosting.view) == nil
        })
        #expect(settingsTestAccessibilityText(try element("settings-group-count-\(home.id)", in: hosting.view)).contains("1 item"))
        #expect(settingsTestAccessibilityText(try element("settings-group-count-\(work.id)", in: hosting.view)).contains("0 items"))

        // Unchecking removes the key from its group only.
        #expect(try element("settings-group-member-\(home.id)-Item 1", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { model.preferences.itemGroups.map(\.ownerKeys) == [[], []] })
        #expect(writes.count == 2)

        // Checking an ungrouped key adds only that key.
        #expect(try element("settings-group-member-\(work.id)-Item 2", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { model.preferences.itemGroups.map(\.ownerKeys) == [["Item 2"], []] })
        #expect(writes.count == 3)
        #expect(model.preferences.itemGroups.map(\.id) == [work.id, home.id])
        #expect(model.preferences.itemGroups.map(\.name) == ["Work", "Home"])

        // Grouping is not placement: the saved intent and the staged placement draft are untouched.
        #expect(model.preferences.itemControls == ItemControlStore())
        #expect(model.hasPendingChanges)
        #expect(model.isHidden(model.loadedItems[1]))
        #expect(writes.all.allSatisfy { $0.itemControls == ItemControlStore() })
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func absentMembersAreListedAsNotRunningAndCanBeRemoved() async throws {
        let work = ItemGroup(name: "Work", ownerKeys: ["Item 1", "Ghost"])
        var preferences = Preferences.default
        preferences.itemAliases.setAlias("Old Friend", forKey: "Ghost")
        let writes = PreferenceWrites()
        let model = makeModel(preferences: preferences, groups: [work], items: [settingsTestItem(1)], writes: writes)
        await model.reloadItems()
        let hosting = groupsHost(model)
        let ghost = try element("settings-group-member-\(work.id)-Ghost", in: hosting.view)
        #expect(ghost.accessibilityLabel() == "Old Friend (not running)")
        #expect(ghost.isAccessibilityEnabled())
        #expect(try element("settings-group-member-\(work.id)-Item 1", in: hosting.view).accessibilityLabel() == "Item 1")
        #expect(settingsTestAccessibilityText(try element("settings-group-count-\(work.id)", in: hosting.view)).contains("2 items"))

        #expect(ghost.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            model.preferences.itemGroups.map(\.ownerKeys) == [["Item 1"]]
                && find("settings-group-member-\(work.id)-Ghost", in: hosting.view) == nil
        })
        #expect(writes.count == 1)
        #expect(model.preferences.itemAliases.alias(forKey: "Ghost") == "Old Friend")
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func placementInProgressDisablesMembershipAndDeleteOnly() async throws {
        let work = ItemGroup(name: "Work", ownerKeys: ["Item 1"])
        let home = ItemGroup(name: "Home")
        let writes = PreferenceWrites()
        let model = makeModel(groups: [work, home], items: [settingsTestItem(1)], writes: writes)
        await model.reloadItems()
        model.placementInProgress = true
        let hosting = groupsHost(model)
        for identifier in [
            "settings-group-member-\(work.id)-Item 1", "settings-group-member-\(home.id)-Item 1",
            "settings-group-delete-\(work.id)", "settings-group-delete-\(home.id)"
        ] {
            let control = try element(identifier, in: hosting.view)
            #expect(!control.isAccessibilityEnabled(), "\(identifier) must not accept group edits while applying")
            #expect(!control.accessibilityPerformPress())
        }
        // Names and creation do not move items, so they stay available.
        #expect(try element("settings-group-name-\(work.id)", in: hosting.view).isAccessibilityEnabled())
        #expect(try element("settings-group-new-name", in: hosting.view).isAccessibilityEnabled())
        hosting.render()
        #expect(model.preferences.itemGroups == [work, home])
        #expect(writes.count == 0)

        model.placementInProgress = false
        #expect(await waitForUpdate(hosting.view) {
            find("settings-group-member-\(home.id)-Item 1", in: hosting.view)?.isAccessibilityEnabled() == true
                && find("settings-group-delete-\(work.id)", in: hosting.view)?.isAccessibilityEnabled() == true
        })
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func fullGroupListBlocksCreationAndReadErrorsOfferRetry() async throws {
        let groups = (0..<ItemGroupLibrary.maxGroups).map { ItemGroup(name: "Group \($0)") }
        var reads = 0
        let writes = PreferenceWrites()
        let model = makeModel(
            groups: groups,
            itemsProvider: {
                reads += 1
                if reads == 1 { throw WindowServerError.invalidServerResponse("test read failure") }
                return [settingsTestItem(1)]
            },
            writes: writes
        )
        await model.reloadItems()
        #expect(model.itemsLoadError != nil)
        let hosting = groupsHost(model)
        let identifiers = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        #expect(identifiers.contains("settings-group-items-error"))
        #expect(identifiers.contains("settings-group-list"))
        #expect(identifiers.contains { $0.hasPrefix("settings-group-name-") })
        let error = try element("settings-group-create-error", in: hosting.view)
        #expect(settingsTestAccessibilityText(error).contains("at most \(ItemGroupLibrary.maxGroups) groups"))
        #expect(!(try element("settings-group-create", in: hosting.view)).isAccessibilityEnabled())

        let retry = try element("settings-group-retry-reading", in: hosting.view)
        #expect(retry.isAccessibilityEnabled())
        #expect(retry.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            model.itemsLoadError == nil && model.loadedItems.count == 1
                && find("settings-group-items-error", in: hosting.view) == nil
        })
        #expect(reads == 2)
        #expect(await waitForUpdate(hosting.view) {
            find("settings-group-member-\(groups[0].id)-Item 1", in: hosting.view) != nil
        })
        #expect(writes.count == 0)
        #expect(!hosting.testWindow.isVisible)
    }

    // MARK: - Helpers

    private func makeModel(
        preferences: Preferences = .default,
        groups: [ItemGroup] = [],
        items: [FloatingBarItem] = [],
        writes: PreferenceWrites
    ) -> SettingsModel {
        makeModel(preferences: preferences, groups: groups, itemsProvider: { items }, writes: writes)
    }

    private func makeModel(
        preferences: Preferences = .default,
        groups: [ItemGroup] = [],
        itemsProvider: @escaping () async throws -> [FloatingBarItem],
        writes: PreferenceWrites
    ) -> SettingsModel {
        var preferences = preferences
        preferences.itemGroups = groups
        return SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: itemsProvider, onChange: { writes.record($0) }
        )
    }

    /// Sized like the real Settings window: at fitting height the List collapses to its minimum and
    /// materializes only the first few rows, so later groups would be absent from the tree.
    private func groupsHost(_ model: SettingsModel) -> SettingsTestHostingController {
        settingsTestHost(GroupsSettingsTab(model: model).content.frame(width: 640, height: 600))
    }

    private func find(_ identifier: String, in view: NSView) -> SettingsTestAXElement? {
        settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier }
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(find(identifier, in: view), "missing accessibility identifier \(identifier)")
    }

    /// The name fields are distinguished by content: the creation field is empty, a group's shows its name.
    private func editableField(in view: NSView, showing text: String) throws -> NSTextField {
        try #require(settingsTestSubviews(view).compactMap { $0 as? NSTextField }.first {
            $0.isEditable && $0.stringValue == text
        })
    }

    /// The off-screen field editor drives the real SwiftUI bindings without posting keyboard events.
    private func type(_ text: String, into field: NSTextField, in window: NSWindow) throws -> NSTextView {
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.isFieldEditor)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        return editor
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

/// Records every `onChange` so a test can count writes and inspect what each one carried.
@MainActor
private final class PreferenceWrites {
    private(set) var all: [Preferences] = []
    var count: Int { all.count }

    func record(_ preferences: Preferences) {
        all.append(preferences)
    }
}

import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SpacingSettingsSectionTests {
    private final class Writes {
        var all: [Preferences] = []
        var count: Int { all.count }
    }

    private func makeModel(_ spacing: MenuBarSpacing, writes: Writes = Writes()) -> SettingsModel {
        var preferences = Preferences.default
        preferences.menuBarSpacing = spacing
        return SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { writes.all.append($0) }
        )
    }

    private func host(_ model: SettingsModel, needsLogout: Bool = false) -> SettingsTestHostingController {
        settingsTestHost(
            Form { SpacingSettingsSection(model: model, needsLogout: needsLogout) }
                .formStyle(.grouped)
                .frame(width: 640)
        )
    }

    private func identifiers(in view: NSView) -> [String] {
        settingsTestAccessibility(view).compactMap { $0.accessibilityIdentifier() }
    }

    /// Labels, values, and titles: a checkbox-style toggle carries its text as an AX title.
    private func text(in view: NSView) -> String {
        settingsTestAccessibility(view).flatMap { element in
            [settingsTestAccessibilityText(element), element.property("accessibilityTitle") as? String ?? ""]
        }.joined(separator: " ")
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier })
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

    @Test func disabledSpacingShowsOnlyTheToggleAndTheSharedNote() throws {
        let hosting = host(makeModel(.systemDefault))
        let ids = identifiers(in: hosting.view)
        #expect(ids.contains("settings-spacing-enabled"))
        #expect(ids.contains("settings-spacing-shared-note"))
        #expect(!ids.contains("settings-spacing-spacing"))
        #expect(!ids.contains("settings-spacing-padding"))
        #expect(!ids.contains("settings-spacing-reset"))
        #expect(!ids.contains("settings-spacing-logout-note"))
        #expect(try element("settings-spacing-enabled", in: hosting.view).isAccessibilityEnabled())

        let content = text(in: hosting.view)
        #expect(content.contains("Reduce menu bar item spacing"))
        #expect(content.contains("System-wide: all apps share these values."))
        #expect(!content.contains("log out"))
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func enabledSpacingShowsBothSteppersWithTheirValuesAndAReset() throws {
        let hosting = host(makeModel(MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4)))
        let ids = identifiers(in: hosting.view)
        for identifier in ["settings-spacing-enabled", "settings-spacing-spacing", "settings-spacing-padding", "settings-spacing-reset"] {
            #expect(ids.contains(identifier), "\(identifier) must be present while spacing is enabled")
        }
        #expect(try element("settings-spacing-reset", in: hosting.view).isAccessibilityEnabled())
        let content = text(in: hosting.view)
        #expect(content.contains("8 pt"))
        #expect(content.contains("4 pt"))
        #expect(content.contains("Spacing"))
        #expect(content.contains("Selection padding"))
        #expect(content.contains("Reset to system default"))
    }

    @Test(arguments: [false, true], [false, true])
    func logoutNoteAppearsOnlyWhenTheCoordinatorAsksForIt(enabled: Bool, needsLogout: Bool) {
        let hosting = host(makeModel(MenuBarSpacing(enabled: enabled, spacing: 6, selectionPadding: 6)), needsLogout: needsLogout)
        #expect(identifiers(in: hosting.view).contains("settings-spacing-logout-note") == needsLogout)
        let expected = "Relaunch menu bar apps or log out to see the change."
        #expect(text(in: hosting.view).contains(expected) == needsLogout)
    }

    @Test func togglingOnWritesOnceAndRevealsTheRememberedValues() async throws {
        let writes = Writes()
        let model = makeModel(MenuBarSpacing(enabled: false, spacing: 6, selectionPadding: 5), writes: writes)
        let hosting = host(model)
        // The switch toggles on AXPress but reports false for it, so the model is the oracle.
        _ = try element("settings-spacing-enabled", in: hosting.view).accessibilityPerformPress()
        #expect(await settle(hosting) {
            model.preferences.menuBarSpacing.enabled && identifiers(in: hosting.view).contains("settings-spacing-spacing")
        })
        #expect(model.preferences.menuBarSpacing == MenuBarSpacing(enabled: true, spacing: 6, selectionPadding: 5))
        #expect(writes.count == 1)
        #expect(writes.all.last?.menuBarSpacing.enabled == true)
        let content = text(in: hosting.view)
        #expect(content.contains("6 pt"))
        #expect(content.contains("5 pt"))
        #expect(identifiers(in: hosting.view).contains("settings-spacing-reset"))
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func togglingOffKeepsTheNumbersForNextTime() async throws {
        let writes = Writes()
        let model = makeModel(MenuBarSpacing(enabled: true, spacing: 3, selectionPadding: 9), writes: writes)
        let hosting = host(model)
        _ = try element("settings-spacing-enabled", in: hosting.view).accessibilityPerformPress()
        #expect(await settle(hosting) {
            !model.preferences.menuBarSpacing.enabled && !identifiers(in: hosting.view).contains("settings-spacing-spacing")
        })
        #expect(model.preferences.menuBarSpacing == MenuBarSpacing(enabled: false, spacing: 3, selectionPadding: 9))
        #expect(!model.preferences.menuBarSpacing.isSystemDefault)
        #expect(writes.count == 1)
        #expect(!identifiers(in: hosting.view).contains("settings-spacing-reset"))
    }

    @Test func resetRestoresTheSystemDefaultWithOneWriteAndHidesTheControls() async throws {
        let writes = Writes()
        let model = makeModel(MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4), writes: writes)
        let hosting = host(model)
        #expect(try element("settings-spacing-reset", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) {
            model.preferences.menuBarSpacing.isSystemDefault && !identifiers(in: hosting.view).contains("settings-spacing-reset")
        })
        #expect(model.preferences.menuBarSpacing == .systemDefault)
        #expect(writes.count == 1)
        #expect(writes.all.last?.menuBarSpacing == .systemDefault)
        let ids = identifiers(in: hosting.view)
        #expect(!ids.contains("settings-spacing-spacing"))
        #expect(!ids.contains("settings-spacing-padding"))
        #expect(ids.contains("settings-spacing-enabled"))
        #expect(ids.contains("settings-spacing-shared-note"))
    }

    @Test func steppersMoveOnePointPerStepAndStopAtTheRangeEnds() async throws {
        let writes = Writes()
        let model = makeModel(MenuBarSpacing(enabled: true, spacing: 15, selectionPadding: 1), writes: writes)
        let hosting = host(model)
        let spacing = try element("settings-spacing-spacing", in: hosting.view)
        let padding = try element("settings-spacing-padding", in: hosting.view)
        #expect(spacing.accessibilityRole() == .incrementor)
        #expect((spacing.accessibilityValue() as? NSNumber)?.intValue == 15)
        #expect((padding.accessibilityValue() as? NSNumber)?.intValue == 1)

        spacing.performAccessibilityAction("accessibilityPerformIncrement")
        #expect(await settle(hosting) { model.preferences.menuBarSpacing.spacing == 16 })
        #expect(writes.count == 1)
        // At the upper bound another increment changes nothing and writes nothing.
        spacing.performAccessibilityAction("accessibilityPerformIncrement")
        hosting.render()
        #expect(model.preferences.menuBarSpacing.spacing == 16)
        #expect(writes.count == 1)
        spacing.performAccessibilityAction("accessibilityPerformDecrement")
        #expect(await settle(hosting) { model.preferences.menuBarSpacing.spacing == 15 })
        #expect(writes.count == 2)
        #expect(model.preferences.menuBarSpacing.selectionPadding == 1)

        padding.performAccessibilityAction("accessibilityPerformDecrement")
        #expect(await settle(hosting) { model.preferences.menuBarSpacing.selectionPadding == 0 })
        #expect(writes.count == 3)
        padding.performAccessibilityAction("accessibilityPerformDecrement")
        hosting.render()
        #expect(model.preferences.menuBarSpacing == MenuBarSpacing(enabled: true, spacing: 15, selectionPadding: 0))
        #expect(writes.count == 3)
        #expect((spacing.accessibilityValue() as? NSNumber)?.intValue == 15)
        #expect((padding.accessibilityValue() as? NSNumber)?.intValue == 0)
        let content = text(in: hosting.view)
        #expect(content.contains("15 pt"))
        #expect(content.contains("0 pt"))
    }

    @Test func valuesChangedElsewhereAreReflectedWithoutExtraWrites() async {
        let writes = Writes()
        let model = makeModel(MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4), writes: writes)
        let hosting = host(model)
        #expect(text(in: hosting.view).contains("8 pt"))

        var imported = model.preferences
        imported.menuBarSpacing = MenuBarSpacing(enabled: true, spacing: 1, selectionPadding: 0)
        model.preferences = imported
        #expect(await settle(hosting) {
            let content = text(in: hosting.view)
            return content.contains("1 pt") && content.contains("0 pt") && !content.contains("8 pt")
        })
        #expect(writes.count == 1)
    }

    @Test func spacingEditsLeaveEveryOtherPreferenceAlone() {
        let writes = Writes()
        var preferences = Preferences.default
        preferences.autoRehide = false
        preferences.revealOnHover = true
        preferences.itemAliases.setAlias("Clipboard", for: settingsTestItem(1).snapshot)
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { writes.all.append($0) }
        )
        model.preferences.menuBarSpacing = MenuBarSpacing(enabled: true, spacing: 2, selectionPadding: 2)
        model.preferences.menuBarSpacing = .systemDefault
        #expect(writes.count == 2)
        var expected = preferences
        expected.menuBarSpacing = MenuBarSpacing(enabled: true, spacing: 2, selectionPadding: 2)
        #expect(writes.all.first == expected)
        #expect(writes.all.last == preferences)
        #expect(!model.hasPendingChanges)
    }
}

private extension SettingsTestAXElement {
    /// Increment/decrement are not on the shared helper. AppKit steppers and switches perform the
    /// action but report false, so callers verify the model instead of this return value.
    @discardableResult
    func performAccessibilityAction(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard isAccessibilityEnabled(), object.responds(to: selector) else { return false }
        typealias Perform = @convention(c) (AnyObject, Selector) -> Bool
        let perform = unsafeBitCast(object.method(for: selector), to: Perform.self)
        return perform(object, selector)
    }
}

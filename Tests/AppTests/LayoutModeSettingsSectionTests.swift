import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LayoutModeSettingsSectionTests {
    private final class Writes {
        var all: [Preferences] = []
        var count: Int { all.count }
    }

    private func makeModel(_ mode: LayoutMode, writes: Writes = Writes()) -> SettingsModel {
        var preferences = Preferences.default
        preferences.layoutMode = mode
        return SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { writes.all.append($0) }
        )
    }

    private func host(_ model: SettingsModel) -> SettingsTestHostingController {
        settingsTestHost(
            Form { LayoutModeSettingsSection(model: model) }
                .formStyle(.grouped)
                .frame(width: 640)
        )
    }

    private func identifiers(in view: NSView) -> [String] {
        settingsTestAccessibility(view).compactMap { $0.accessibilityIdentifier() }.filter { !$0.isEmpty }
    }

    private func text(in view: NSView) -> String {
        settingsTestAccessibility(view).map(settingsTestAccessibilityText).joined(separator: " ")
    }

    /// The radio group exposes one AXRadioButton per option, labelled with the option title.
    private func radio(_ title: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first {
            $0.accessibilityRole() == .radioButton && $0.accessibilityLabel() == title
        })
    }

    private func isSelected(_ radio: SettingsTestAXElement) -> Bool {
        (radio.accessibilityValue() as? NSNumber)?.intValue == 1
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

    @Test func onDemandShowsBothDescriptionsWithoutTheAccessibilityNote() throws {
        let hosting = host(makeModel(.onDemand))
        let view = hosting.view
        let ids = identifiers(in: view)
        #expect(ids.contains("settings-layout-mode-picker"))
        #expect(ids.contains("settings-layout-mode-on-demand-description"))
        #expect(ids.contains("settings-layout-mode-live-description"))
        #expect(!ids.contains("settings-layout-mode-accessibility-note"))
        #expect(ids.allSatisfy { $0.hasPrefix("settings-layout-mode-") })

        let group = try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == "settings-layout-mode-picker" })
        #expect(group.accessibilityRole() == .radioGroup)
        #expect(group.isAccessibilityEnabled())
        #expect(settingsTestAccessibility(view).filter { $0.accessibilityRole() == .radioButton }.count == 2)
        #expect(isSelected(try radio("On-Demand", in: view)))
        #expect(!isSelected(try radio("Live", in: view)))

        let content = text(in: view)
        #expect(content.contains("Placement"))
        #expect(content.contains("Layout mode"))
        #expect(content.contains("On-Demand applies your saved Shown/Hidden placement at launch, when you Apply Changes, and when displays change."))
        #expect(content.contains("Live also re-applies it after apps launch or quit."))
        #expect(content.contains("may briefly move the pointer"))
        // The copy must not promise more than the mover delivers.
        #expect(!content.lowercased().contains("never"))
        #expect(!content.lowercased().contains("instantly"))
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func choosingLiveWritesOnceSelectsItAndSurfacesTheAccessibilityRequirement() async throws {
        let writes = Writes()
        let model = makeModel(.onDemand, writes: writes)
        let hosting = host(model)
        #expect(try radio("Live", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) { model.preferences.layoutMode == .live })
        #expect(writes.count == 1)
        #expect(writes.all.last?.layoutMode == .live)
        #expect(isSelected(try radio("Live", in: hosting.view)))
        #expect(!isSelected(try radio("On-Demand", in: hosting.view)))
        // The test process holds no Accessibility grant, so the requirement note must appear.
        #expect(model.status(of: .accessibility) != .granted)
        #expect(identifiers(in: hosting.view).contains("settings-layout-mode-accessibility-note"))
        #expect(text(in: hosting.view).contains("Live mode needs Accessibility to move items."))
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func choosingOnDemandFromLiveWritesOnceAndHidesTheNote() async throws {
        let writes = Writes()
        let model = makeModel(.live, writes: writes)
        let hosting = host(model)
        #expect(isSelected(try radio("Live", in: hosting.view)))
        #expect(identifiers(in: hosting.view).contains("settings-layout-mode-accessibility-note"))

        #expect(try radio("On-Demand", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) {
            model.preferences.layoutMode == .onDemand
                && !identifiers(in: hosting.view).contains("settings-layout-mode-accessibility-note")
        })
        #expect(writes.count == 1)
        #expect(writes.all.last?.layoutMode == .onDemand)
        #expect(isSelected(try radio("On-Demand", in: hosting.view)))
    }

    @Test(arguments: LayoutMode.allCases)
    func reselectingTheCurrentModeWritesNothing(mode: LayoutMode) async throws {
        let writes = Writes()
        let model = makeModel(mode, writes: writes)
        let hosting = host(model)
        let title = mode == .live ? "Live" : "On-Demand"
        #expect(isSelected(try radio(title, in: hosting.view)))
        #expect(try radio(title, in: hosting.view).accessibilityPerformPress())
        for _ in 0..<5 {
            hosting.render()
            await Task.yield()
        }
        #expect(model.preferences.layoutMode == mode)
        #expect(writes.count == 0)
        #expect(isSelected(try radio(title, in: hosting.view)))
    }

    @Test func aModeChangedElsewhereIsReflectedWithoutExtraWrites() async throws {
        let writes = Writes()
        let model = makeModel(.onDemand, writes: writes)
        let hosting = host(model)
        var imported = model.preferences
        imported.layoutMode = .live
        model.preferences = imported
        #expect(await settle(hosting) {
            guard let live = try? radio("Live", in: hosting.view) else { return false }
            return isSelected(live) && identifiers(in: hosting.view).contains("settings-layout-mode-accessibility-note")
        })
        #expect(!isSelected(try radio("On-Demand", in: hosting.view)))
        #expect(writes.count == 1)
    }

    @Test func layoutModeEditsLeaveEveryOtherPreferenceAlone() {
        let writes = Writes()
        var preferences = Preferences.default
        preferences.autoRehide = false
        preferences.revealOnHover = true
        preferences.itemAliases.setAlias("Clipboard", for: settingsTestItem(1).snapshot)
        preferences.itemControls.setHidden(true, for: settingsTestItem(2).snapshot)
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { writes.all.append($0) }
        )
        model.preferences.layoutMode = .live
        model.preferences.layoutMode = .onDemand
        #expect(writes.count == 2)
        var expected = preferences
        expected.layoutMode = .live
        #expect(writes.all.first == expected)
        #expect(writes.all.last == preferences)
        #expect(!model.hasPendingChanges)
    }
}

import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NotchSettingsSectionTests {
    /// Stands in for the `notchOverflow` preference: observable so the hosted view re-renders on change.
    @MainActor
    @Observable
    final class ModeBox {
        var mode: NotchOverflowMode
        var writes = 0
        init(_ mode: NotchOverflowMode) { self.mode = mode }

        var binding: Binding<NotchOverflowMode> {
            Binding(
                get: { MainActor.assumeIsolated { self.mode } },
                set: { chosen in
                    MainActor.assumeIsolated {
                        self.mode = chosen
                        self.writes += 1
                    }
                }
            )
        }
    }

    private func makeModel() -> SettingsModel {
        SettingsModel(
            preferences: Preferences.default, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { _ in }
        )
    }

    private func host(_ model: SettingsModel, _ box: ModeBox) -> SettingsTestHostingController {
        settingsTestHost(
            Form { NotchSettingsSection(model: model, mode: box.binding) }
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

    @Test func neverShowsThePickerAndEveryNoteExceptTheAccessibilityWarning() throws {
        let box = ModeBox(.never)
        let hosting = host(makeModel(), box)
        let view = hosting.view
        let ids = identifiers(in: view)
        #expect(ids.contains("settings-notch-picker"))
        #expect(ids.contains("settings-notch-description"))
        #expect(ids.contains("settings-notch-scope-note"))
        #expect(ids.contains("settings-notch-display-note"))
        #expect(!ids.contains("settings-notch-accessibility-note"))
        #expect(ids.allSatisfy { $0.hasPrefix("settings-notch-") })

        let group = try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == "settings-notch-picker" })
        #expect(group.accessibilityRole() == .radioGroup)
        #expect(group.isAccessibilityEnabled())
        #expect(settingsTestAccessibility(view).filter { $0.accessibilityRole() == .radioButton }.count == 2)
        #expect(isSelected(try radio("Never", in: view)))
        #expect(!isSelected(try radio("When needed", in: view)))

        let content = text(in: view)
        #expect(content.contains("Notch"))
        #expect(content.contains("Make room near the notch"))
        #expect(content.contains("When the hidden section is revealed in the menu bar and the notch would clip it, temporarily tuck the shown items closest to the anchor, then put them back when the section hides."))
        #expect(content.contains("Only applies when hidden items are revealed in the menu bar (floating bar off, or when activating an item)."))
        #expect(content.contains("Moves items, so it needs Accessibility and may briefly move the pointer."))
        #expect(content.contains("Has no effect on displays without a notch."))
        // The copy must not promise more than the mover delivers.
        #expect(!content.lowercased().contains("instantly"))
        #expect(!content.lowercased().contains("always works"))
        #expect(box.writes == 0)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func choosingWhenNeededWritesOnceSelectsItAndSurfacesTheAccessibilityRequirement() async throws {
        let box = ModeBox(.never)
        let model = makeModel()
        let hosting = host(model, box)
        #expect(try radio("When needed", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) { box.mode == .whenNeeded })
        #expect(box.writes == 1)
        #expect(isSelected(try radio("When needed", in: hosting.view)))
        #expect(!isSelected(try radio("Never", in: hosting.view)))
        // The test process holds no Accessibility grant, so the requirement note must appear.
        #expect(model.status(of: .accessibility) != .granted)
        #expect(await settle(hosting) { identifiers(in: hosting.view).contains("settings-notch-accessibility-note") })
        #expect(text(in: hosting.view).contains("Making room needs Accessibility to move items."))
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func choosingNeverFromWhenNeededWritesOnceAndHidesTheNote() async throws {
        let box = ModeBox(.whenNeeded)
        let hosting = host(makeModel(), box)
        #expect(isSelected(try radio("When needed", in: hosting.view)))
        #expect(identifiers(in: hosting.view).contains("settings-notch-accessibility-note"))

        #expect(try radio("Never", in: hosting.view).accessibilityPerformPress())
        #expect(await settle(hosting) {
            box.mode == .never && !identifiers(in: hosting.view).contains("settings-notch-accessibility-note")
        })
        #expect(box.writes == 1)
        #expect(isSelected(try radio("Never", in: hosting.view)))
    }

    @Test(arguments: NotchOverflowMode.allCases)
    func reselectingTheCurrentModeWritesNothing(mode: NotchOverflowMode) async throws {
        let box = ModeBox(mode)
        let hosting = host(makeModel(), box)
        let title = mode == .whenNeeded ? "When needed" : "Never"
        #expect(isSelected(try radio(title, in: hosting.view)))
        #expect(try radio(title, in: hosting.view).accessibilityPerformPress())
        for _ in 0..<5 {
            hosting.render()
            await Task.yield()
        }
        #expect(box.mode == mode)
        #expect(box.writes == 0)
        #expect(isSelected(try radio(title, in: hosting.view)))
    }

    @Test func aModeChangedElsewhereIsReflectedWithoutExtraWrites() async throws {
        let box = ModeBox(.never)
        let hosting = host(makeModel(), box)
        box.mode = .whenNeeded
        #expect(await settle(hosting) {
            guard let radio = try? radio("When needed", in: hosting.view) else { return false }
            return isSelected(radio) && identifiers(in: hosting.view).contains("settings-notch-accessibility-note")
        })
        #expect(!isSelected(try radio("Never", in: hosting.view)))
        #expect(box.writes == 0)
    }
}

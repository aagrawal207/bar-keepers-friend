import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct TriggersSettingsTabTests {
    static let focus = LayoutPreset(id: UUID(), name: "Focus", itemControls: ItemControlStore(hiddenInMenuBar: ["ACME"]))
    static let meeting = LayoutPreset(id: UUID(), name: "Meeting", itemControls: ItemControlStore(hiddenInMenuBar: ["Maccy"]))

    @MainActor
    final class Recorder {
        var writes: [Preferences] = []
    }

    static func makeModel(presets: [LayoutPreset], rules: [TriggerRule]) -> (SettingsModel, Recorder) {
        var preferences = Preferences.default
        preferences.presets = presets
        preferences.triggers = rules
        let recorder = Recorder()
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { recorder.writes.append($0) }
        )
        return (model, recorder)
    }

    static func host(_ model: SettingsModel) -> SettingsTestHostingController {
        settingsTestHost(TriggersSettingsTab(model: model).content.frame(width: 640, height: 560))
    }

    // MARK: - Add

    @Test func addRuleWritesOnceWithTheTypedNameDefaultConditionAndFirstPreset() async throws {
        let (model, recorder) = Self.makeModel(presets: [Self.focus, Self.meeting], rules: [])
        let hosting = Self.host(model)
        let window = hosting.testWindow!
        #expect(settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-empty" })
        #expect(!settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-add-hint" })
        let add = try element("settings-trigger-add", in: hosting.view)
        #expect(add.isAccessibilityEnabled())
        #expect(add.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-editor-name" }
        })
        let save = try element("settings-trigger-editor-save", in: hosting.view)
        #expect(!save.isAccessibilityEnabled())
        // An untouched empty name shows no error yet; the disabled button is the only hint.
        #expect(!settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-editor-error" })
        #expect(settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier()?.hasPrefix("settings-trigger-condition-kind-") == true })

        let field = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Battery focus", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityIdentifier() == "settings-trigger-editor-save" && $0.isAccessibilityEnabled()
            }
        })
        #expect(recorder.writes.isEmpty)
        #expect(window.makeFirstResponder(nil))
        #expect(try element("settings-trigger-editor-save", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { recorder.writes.count == 1 && model.preferences.triggers.count == 1 })

        let rule = try #require(model.preferences.triggers.first)
        #expect(rule.name == "Battery focus")
        #expect(rule.isEnabled)
        #expect(rule.conditions == [.onBattery])
        #expect(rule.presetID == Self.focus.id)
        #expect(recorder.writes.count == 1)
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-name-\(rule.id)" }
        })
        let elements = settingsTestAccessibility(hosting.view)
        #expect(elements.first { $0.accessibilityIdentifier() == "settings-trigger-name-\(rule.id)" }.map(settingsTestAccessibilityText) == "Battery focus")
        #expect(elements.first { $0.accessibilityIdentifier() == "settings-trigger-summary-\(rule.id)" }.map(settingsTestAccessibilityText) == "On battery power")
        #expect(elements.first { $0.accessibilityIdentifier() == "settings-trigger-preset-\(rule.id)" }.map(settingsTestAccessibilityText)?.contains("Focus") == true)
        #expect(!elements.contains { $0.accessibilityIdentifier() == "settings-trigger-editor" })
        #expect(!window.isVisible)
    }

    @Test func cancellingTheEditorWritesNothing() async throws {
        let rule = TriggerRule(name: "Office", conditions: [.lowPowerMode], presetID: Self.focus.id)
        let (model, recorder) = Self.makeModel(presets: [Self.focus], rules: [rule])
        let hosting = Self.host(model)
        let window = hosting.testWindow!
        #expect(try element("settings-trigger-edit-\(rule.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-editor-name" }
        })
        let field = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        #expect(field.stringValue == "Office")
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Renamed", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "Renamed" })
        #expect(window.makeFirstResponder(nil))
        #expect(try element("settings-trigger-editor-cancel", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-name-\(rule.id)" }
        })
        #expect(recorder.writes.isEmpty)
        #expect(model.preferences.triggers == [rule])
    }

    // MARK: - Enable and delete

    @Test func enableToggleWritesOneChangePerPress() async throws {
        let rule = TriggerRule(name: "Battery", conditions: [.onBattery], presetID: Self.focus.id)
        let (model, recorder) = Self.makeModel(presets: [Self.focus], rules: [rule])
        let hosting = Self.host(model)
        let toggle = try element("settings-trigger-enabled-\(rule.id)", in: hosting.view)
        #expect(toggle.isAccessibilityEnabled())
        #expect(toggle.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { recorder.writes.count == 1 })
        #expect(model.preferences.triggers[0].isEnabled == false)
        #expect(model.preferences.triggers[0].id == rule.id)
        #expect(recorder.writes[0].triggers[0].isEnabled == false)

        #expect(try element("settings-trigger-enabled-\(rule.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { recorder.writes.count == 2 })
        #expect(model.preferences.triggers == [rule])
    }

    @Test func deleteNeedsConfirmationAndWritesOnce() async throws {
        let keep = TriggerRule(name: "Keep", conditions: [.charging], presetID: Self.focus.id)
        let doomed = TriggerRule(name: "Doomed", conditions: [.onBattery], presetID: Self.focus.id)
        let (model, recorder) = Self.makeModel(presets: [Self.focus], rules: [keep, doomed])
        let hosting = Self.host(model)
        #expect(!settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-delete-prompt-\(doomed.id)" })
        #expect(try element("settings-trigger-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-delete-prompt-\(doomed.id)" }
        })
        #expect(recorder.writes.isEmpty)

        #expect(try element("settings-trigger-cancel-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-delete-\(doomed.id)" }
        })
        #expect(recorder.writes.isEmpty)
        #expect(model.preferences.triggers == [keep, doomed])

        #expect(try element("settings-trigger-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-confirm-delete-\(doomed.id)" }
        })
        #expect(try element("settings-trigger-confirm-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { recorder.writes.count == 1 })
        #expect(model.preferences.triggers == [keep])
        #expect(await waitForUpdate(hosting.view) {
            let ids = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
            return ids.contains("settings-trigger-row-\(keep.id)") && !ids.contains("settings-trigger-row-\(doomed.id)")
        })
    }

    // MARK: - Presets

    @Test func missingPresetIsFlaggedInTheListAndBlocksSaving() async throws {
        let orphan = TriggerRule(name: "Orphan", conditions: [.onBattery], presetID: UUID())
        let healthy = TriggerRule(name: "Healthy", conditions: [.charging], presetID: Self.focus.id)
        let (model, recorder) = Self.makeModel(presets: [Self.focus], rules: [orphan, healthy])
        let hosting = Self.host(model)
        let elements = settingsTestAccessibility(hosting.view)
        let warning = try #require(elements.first { $0.accessibilityIdentifier() == "settings-trigger-missing-preset-\(orphan.id)" })
        #expect(settingsTestAccessibilityText(warning).contains("Missing preset"))
        #expect(!elements.contains { $0.accessibilityIdentifier() == "settings-trigger-preset-\(orphan.id)" })
        #expect(elements.contains { $0.accessibilityIdentifier() == "settings-trigger-preset-\(healthy.id)" })
        #expect(!elements.contains { $0.accessibilityIdentifier() == "settings-trigger-missing-preset-\(healthy.id)" })

        #expect(try element("settings-trigger-edit-\(orphan.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-editor-error" }
        })
        let error = try element("settings-trigger-editor-error", in: hosting.view)
        #expect(settingsTestAccessibilityText(error) == TriggerRuleValidationIssue.missingPreset.message)
        #expect(!(try element("settings-trigger-editor-save", in: hosting.view).isAccessibilityEnabled()))
        #expect(recorder.writes.isEmpty)
    }

    @Test func withoutPresetsAddIsDisabledWithAnExplanation() throws {
        let (model, recorder) = Self.makeModel(presets: [], rules: [])
        let hosting = Self.host(model)
        let add = try element("settings-trigger-add", in: hosting.view)
        #expect(!add.isAccessibilityEnabled())
        #expect(!add.accessibilityPerformPress())
        let hint = try element("settings-trigger-add-hint", in: hosting.view)
        #expect(settingsTestAccessibilityText(hint).lowercased().contains("preset"))
        #expect(settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-empty" })
        #expect(!settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-trigger-editor" })
        #expect(recorder.writes.isEmpty)
    }

    // MARK: - Condition editors

    @Test func editingAWeekdayInATimeRuleWritesOnce() async throws {
        let rule = TriggerRule(
            name: "Office", conditions: [.timeOfDay(startMinute: 540, endMinute: 1020, weekdays: [2, 3, 4, 5, 6])],
            presetID: Self.focus.id
        )
        let (model, recorder) = Self.makeModel(presets: [Self.focus, Self.meeting], rules: [rule])
        let hosting = Self.host(model)
        #expect(try element("settings-trigger-edit-\(rule.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier()?.hasPrefix("settings-trigger-condition-weekday-1-") == true }
        })
        let ids = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        #expect(ids.contains { $0.hasPrefix("settings-trigger-condition-start-") })
        #expect(ids.contains { $0.hasPrefix("settings-trigger-condition-end-") })
        #expect(ids.filter { $0.hasPrefix("settings-trigger-condition-weekday-") }.count == 7)
        #expect(settingsTestSubviews(hosting.view).filter { $0 is NSDatePicker }.count == 2)

        let sunday = try #require(settingsTestAccessibility(hosting.view).first {
            $0.accessibilityIdentifier()?.hasPrefix("settings-trigger-condition-weekday-1-") == true
        })
        #expect(sunday.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).first {
                $0.accessibilityIdentifier()?.hasPrefix("settings-trigger-condition-weekday-1-") == true
            }?.accessibilityValue() as? Int == 1
        })
        #expect(recorder.writes.isEmpty)
        #expect(try element("settings-trigger-editor-save", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { recorder.writes.count == 1 })
        #expect(model.preferences.triggers == [TriggerRule(
            id: rule.id, name: "Office", isEnabled: true,
            conditions: [.timeOfDay(startMinute: 540, endMinute: 1020, weekdays: [1, 2, 3, 4, 5, 6])],
            presetID: Self.focus.id
        )])
    }

    @Test(arguments: TriggerCondition.Kind.allCases)
    func everyConditionKindHasAnEditor(kind: TriggerCondition.Kind) throws {
        let row = TriggerConditionRow(condition: TriggerCondition.defaultCondition(for: kind))
        let hosting = settingsTestHost(ConditionRowHost(row: row).frame(width: 600))
        let ids = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        #expect(ids.contains("settings-trigger-condition-kind-\(row.id)"))
        #expect(ids.contains("settings-trigger-condition-remove-\(row.id)"))
        let parameterIDs: [String]
        switch kind {
        case .onBattery, .charging, .lowPowerMode:
            parameterIDs = []
        case .batteryBelow:
            parameterIDs = ["settings-trigger-condition-percent-\(row.id)"]
        case .wifiConnected:
            parameterIDs = ["settings-trigger-condition-wifi-\(row.id)"]
        case .frontmostApp:
            parameterIDs = ["settings-trigger-condition-bundle-\(row.id)", "settings-trigger-condition-app-picker-\(row.id)"]
        case .externalDisplayConnected:
            parameterIDs = ["settings-trigger-condition-display-\(row.id)"]
        case .timeOfDay:
            parameterIDs = ["settings-trigger-condition-start-\(row.id)", "settings-trigger-condition-end-\(row.id)"]
                + (1...7).map { "settings-trigger-condition-weekday-\($0)-\(row.id)" }
        }
        for identifier in parameterIDs {
            #expect(ids.contains(identifier), "\(kind) editor must expose \(identifier)")
        }
        let otherParameters = ids.filter { $0.hasPrefix("settings-trigger-condition-") }
            .filter { !$0.hasPrefix("settings-trigger-condition-kind-") && !$0.hasPrefix("settings-trigger-condition-remove-") }
            .filter { $0 != "settings-trigger-condition-\(row.id)" }
        #expect(Set(otherParameters) == Set(parameterIDs))
    }

    @Test func clockConversionRoundTripsEveryMinuteInAnyZone() {
        for zone in ["UTC", "Asia/Kolkata", "America/Los_Angeles", "Australia/Lord_Howe"].compactMap(TimeZone.init(identifier:)) {
            for minute in stride(from: 0, through: 1439, by: 7) + [1439] {
                let date = TriggerClockConversion.date(minuteOfDay: minute, timeZone: zone)
                #expect(TriggerClockConversion.minuteOfDay(date, timeZone: zone) == minute, "\(zone.identifier) \(minute)")
            }
        }
        #expect(TriggerClockConversion.minuteOfDay(TriggerClockConversion.date(minuteOfDay: 5000, timeZone: .gmt), timeZone: .gmt) == 1439)
        #expect(TriggerClockConversion.minuteOfDay(TriggerClockConversion.date(minuteOfDay: -3, timeZone: .gmt), timeZone: .gmt) == 0)
    }

    // MARK: - Helpers

    private struct ConditionRowHost: View {
        @State var row: TriggerConditionRow

        var body: some View {
            TriggerConditionRowEditor(row: $row, onRemove: {})
        }
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier })
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

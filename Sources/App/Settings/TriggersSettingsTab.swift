import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Every committed trigger edit is exactly one `model.preferences` assignment. Rules apply presets
/// while their conditions hold; the evaluator restores the earlier arrangement afterward.
struct TriggersSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View { content }

    var content: TriggersSettingsContent { TriggersSettingsContent(model: model) }
}

extension SettingsModel {
    func triggerPresetName(for presetID: UUID) -> String? {
        preferences.presets.first { $0.id == presetID }?.name
    }

    func saveTriggerRule(_ rule: TriggerRule) {
        let updated = TriggerRuleLibrary.upserting(rule, in: preferences.triggers)
        guard updated != preferences.triggers else { return }
        preferences.triggers = updated
    }

    func setTriggerRuleEnabled(_ enabled: Bool, id: UUID) {
        let updated = TriggerRuleLibrary.settingEnabled(enabled, id: id, in: preferences.triggers)
        guard updated != preferences.triggers else { return }
        preferences.triggers = updated
    }

    func deleteTriggerRule(id: UUID) {
        let updated = TriggerRuleLibrary.removing(id: id, from: preferences.triggers)
        guard updated != preferences.triggers else { return }
        preferences.triggers = updated
    }
}

struct TriggersSettingsContent: View {
    private struct Editing: Identifiable {
        var rule: TriggerRule
        var isNew: Bool
        var id: UUID { rule.id }
    }

    @Bindable var model: SettingsModel
    @State private var editing: Editing?

    private var rules: [TriggerRule] { model.preferences.triggers }
    private var presets: [LayoutPreset] { model.preferences.presets }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupBox {
                header
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-trigger-header")
                    .settingsSearchTarget(.triggers)
                    .padding(6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            if let editing {
                TriggerRuleEditor(
                    rule: editing.rule, isNew: editing.isNew, presets: presets,
                    onSave: { rule in
                        model.saveTriggerRule(rule)
                        self.editing = nil
                    },
                    onCancel: { self.editing = nil }
                )
                .id(editing.id)
            } else {
                if rules.isEmpty {
                    emptyState
                    Spacer(minLength: 12)
                } else {
                    ruleList
                }
                footer
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-trigger-content")
    }

    private var header: some View {
        Text("Rules run top to bottom; the first match applies its preset. Your previous arrangement returns when no rules match.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ruleList: some View {
        GroupBox {
            List {
                ForEach(rules) { rule in
                    TriggerRuleRow(model: model, rule: rule) {
                        editing = Editing(rule: rule, isNew: false)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120, maxHeight: .infinity)
            .accessibilityIdentifier("settings-trigger-list")
        }
        .padding(.horizontal, 20)
    }

    private var emptyState: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.badge.clock")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No triggers yet.")
                        .font(.headline)
                    Text("Switch presets based on power, Wi-Fi, an app, a display, or a schedule.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
        .padding(.horizontal, 20)
        .accessibilityIdentifier("settings-trigger-empty")
    }

    private var addHint: String? {
        if presets.isEmpty { return "Save a preset before adding a rule." }
        if rules.count >= TriggerRuleLibrary.maxRules { return "You can have at most \(TriggerRuleLibrary.maxRules) rules." }
        return nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let addHint {
                    Text(addHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-trigger-add-hint")
                }
                Spacer(minLength: 8)
                Button("Add Rule…") {
                    guard let preset = presets.first else { return }
                    editing = Editing(
                        rule: TriggerRule(name: "", conditions: [.onBattery], presetID: preset.id), isNew: true
                    )
                }
                .disabled(addHint != nil)
                .accessibilityIdentifier("settings-trigger-add")
                .settingsSearchTarget(.addTrigger, including: SettingsSearchTarget.triggerEditorControls + (rules.isEmpty ? [.editTrigger, .deleteTrigger] : []))
            }
            Text("Saved rules take effect immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-trigger-footer")
    }
}

private struct TriggerRuleRow: View {
    @Bindable var model: SettingsModel
    let rule: TriggerRule
    let onEdit: () -> Void
    @State private var confirmingDelete = false

    private var displayName: String {
        rule.name.isEmpty ? "Untitled rule" : rule.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { model.setTriggerRuleEnabled($0, id: rule.id) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Enable \(displayName)")
                .help(rule.isEnabled ? "Turn off \(displayName)." : "Turn on \(displayName).")
                .accessibilityIdentifier("settings-trigger-enabled-\(rule.id)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityIdentifier("settings-trigger-name-\(rule.id)")
                    Text(rule.conditionsSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-trigger-summary-\(rule.id)")
                    presetLine
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if !confirmingDelete {
                    Button("Edit…", action: onEdit)
                        .accessibilityIdentifier("settings-trigger-edit-\(rule.id)")
                        .settingsSearchTarget(.editTrigger)
                    Button("Delete…") { confirmingDelete = true }
                        .help("Delete \(displayName). If it is active, your previous arrangement is restored.")
                        .accessibilityIdentifier("settings-trigger-delete-\(rule.id)")
                        .settingsSearchTarget(.deleteTrigger)
                }
            }

            if confirmingDelete {
                HStack(spacing: 8) {
                    Text("Delete \"\(displayName)\"?")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("settings-trigger-delete-prompt-\(rule.id)")
                    Spacer(minLength: 8)
                    Button("Cancel") { confirmingDelete = false }
                        .accessibilityIdentifier("settings-trigger-cancel-delete-\(rule.id)")
                    Button("Delete", role: .destructive) {
                        confirmingDelete = false
                        model.deleteTriggerRule(id: rule.id)
                    }
                    .accessibilityIdentifier("settings-trigger-confirm-delete-\(rule.id)")
                    .settingsSearchTarget(.deleteTrigger)
                }
            }
        }
        .controlSize(.small)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-trigger-row-\(rule.id)")
    }

    @ViewBuilder private var presetLine: some View {
        if let name = model.triggerPresetName(for: rule.presetID) {
            Label("Applies \(name)", systemImage: "square.stack.3d.up")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-trigger-preset-\(rule.id)")
        } else {
            Label("Missing preset", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("The preset this rule applied was deleted, so the rule never runs. Edit it to choose another preset.")
                .accessibilityIdentifier("settings-trigger-missing-preset-\(rule.id)")
        }
    }
}

// MARK: - Editor

/// A condition row keeps its identity while its kind changes, so SwiftUI never confuses rows when
/// one is removed.
struct TriggerConditionRow: Identifiable, Equatable {
    let id: UUID
    var condition: TriggerCondition

    init(id: UUID = UUID(), condition: TriggerCondition) {
        self.id = id
        self.condition = condition
    }
}

struct TriggerRuleEditor: View {
    let isNew: Bool
    let presets: [LayoutPreset]
    let onSave: (TriggerRule) -> Void
    let onCancel: () -> Void
    @State private var draft: TriggerRule
    @State private var rows: [TriggerConditionRow]

    init(
        rule: TriggerRule, isNew: Bool, presets: [LayoutPreset],
        onSave: @escaping (TriggerRule) -> Void, onCancel: @escaping () -> Void
    ) {
        self.isNew = isNew
        self.presets = presets
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: rule)
        _rows = State(initialValue: rule.conditions.map { TriggerConditionRow(condition: $0) })
    }

    private var candidate: TriggerRule {
        var rule = draft
        rule.conditions = rows.map(\.condition)
        return rule
    }

    private var presetExists: Bool { presets.contains { $0.id == draft.presetID } }
    private var issue: TriggerRuleValidationIssue? { candidate.validationIssue(presetExists: presetExists) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Rule name", text: $draft.name)
                        .accessibilityLabel("Rule name")
                        .accessibilityIdentifier("settings-trigger-editor-name")
                        .settingsSearchTarget(.triggerName)
                    Picker("Apply preset", selection: $draft.presetID) {
                        ForEach(presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                        if !presetExists {
                            Text("Missing preset").tag(draft.presetID)
                        }
                    }
                    .accessibilityIdentifier("settings-trigger-editor-preset")
                    .settingsSearchTarget(.triggerPreset)
                } header: {
                    SettingsSearchSectionHeading(
                        target: isNew ? .triggerRule : .editTrigger, id: "settings-trigger-rule-heading",
                        including: isNew ? [.editTrigger, .deleteTrigger] : [.triggerRule, .addTrigger, .deleteTrigger]
                    )
                }

                Section {
                    ForEach($rows) { $row in
                        TriggerConditionRowEditor(row: $row) {
                            rows.removeAll { $0.id == row.id }
                        }
                    }
                    Button("Add Condition") {
                        rows.append(TriggerConditionRow(condition: .onBattery))
                    }
                    .accessibilityIdentifier("settings-trigger-editor-add-condition")
                    .settingsSearchTarget(.addTriggerCondition, including: rows.isEmpty ? [.removeTriggerCondition] : [])
                } header: {
                    SettingsSearchSectionHeading(target: .triggerConditions, id: "settings-trigger-conditions-heading")
                } footer: {
                    Text("All conditions must match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 8) {
                // An untouched empty name is not a mistake yet; every other problem is shown live.
                if let issue, issue != .emptyName || !draft.name.isEmpty {
                    Text(issue.message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-trigger-editor-error")
                }
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings-trigger-editor-cancel")
                Button(isNew ? "Add Rule" : "Save") { onSave(candidate) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(issue != nil)
                    .accessibilityIdentifier("settings-trigger-editor-save")
                    .settingsSearchTarget(.saveTrigger, including: isNew ? [.addTrigger] : [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-trigger-editor")
    }
}

struct TriggerConditionRowEditor: View {
    @Binding var row: TriggerConditionRow
    let onRemove: () -> Void

    private var kind: Binding<TriggerCondition.Kind> {
        Binding(
            get: { row.condition.kind },
            set: { newKind in
                guard newKind != row.condition.kind else { return }
                row.condition = TriggerCondition.defaultCondition(for: newKind)
            }
        )
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Picker("Condition", selection: kind) {
                ForEach(TriggerCondition.Kind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Condition type")
            .accessibilityIdentifier("settings-trigger-condition-kind-\(row.id)")

            TriggerConditionParameterEditor(condition: $row.condition, rowID: row.id)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onRemove()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove condition")
            .help("Remove this condition.")
            .accessibilityIdentifier("settings-trigger-condition-remove-\(row.id)")
            .settingsSearchTarget(.removeTriggerCondition)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-trigger-condition-\(row.id)")
    }
}

/// Parameter controls for one condition. Cases without parameters explain what the condition means.
struct TriggerConditionParameterEditor: View {
    @Binding var condition: TriggerCondition
    let rowID: UUID
    // The picker shows hours in the environment's zone; conversions must use the same zone.
    @Environment(\.timeZone) private var timeZone
    @State private var runningApps: [RunningApp] = []

    struct RunningApp: Identifiable, Hashable {
        let name: String
        let bundleID: String
        var id: String { bundleID }
    }

    var body: some View {
        switch condition {
        case .onBattery:
            note("Running on battery power.")
        case .charging:
            note("Connected to power, even with a full battery.")
        case .lowPowerMode:
            note("Low Power Mode is on.")
        case let .batteryBelow(percent):
            HStack(spacing: 6) {
                TextField("Percent", value: percentBinding(percent), format: .number)
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Battery percentage")
                    .accessibilityIdentifier("settings-trigger-condition-percent-\(rowID)")
                Stepper("Battery percentage", value: percentBinding(percent), in: TriggerCondition.percentRange)
                    .labelsHidden()
                Text("%")
                    .foregroundStyle(.secondary)
            }
        case let .wifiConnected(connected):
            Picker("Wi-Fi", selection: Binding(get: { connected }, set: { condition = .wifiConnected($0) })) {
                Text("Connected").tag(true)
                Text("Not connected").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Wi-Fi state")
            .accessibilityIdentifier("settings-trigger-condition-wifi-\(rowID)")
        case let .frontmostApp(bundleID):
            frontmostAppEditor(bundleID)
        case let .externalDisplayConnected(connected):
            Picker("External display", selection: Binding(get: { connected }, set: { condition = .externalDisplayConnected($0) })) {
                Text("Connected").tag(true)
                Text("Not connected").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("External display state")
            .accessibilityIdentifier("settings-trigger-condition-display-\(rowID)")
        case let .timeOfDay(start, end, weekdays):
            timeOfDayEditor(start: start, end: end, weekdays: weekdays)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func percentBinding(_ current: Int) -> Binding<Int> {
        Binding(
            get: { current },
            set: { condition = .batteryBelow(percent: $0) }
        )
    }

    private func frontmostAppEditor(_ bundleID: String) -> some View {
        let bundleBinding = Binding(get: { bundleID }, set: { condition = .frontmostApp(bundleID: $0) })
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Bundle identifier, such as com.apple.Safari", text: bundleBinding)
                .accessibilityLabel("App bundle identifier")
                .accessibilityIdentifier("settings-trigger-condition-bundle-\(rowID)")
            Picker("Running app", selection: Binding(
                get: { bundleID },
                set: { if !$0.isEmpty { condition = .frontmostApp(bundleID: $0) } }
            )) {
                Text("Choose a running app…").tag("")
                if !bundleID.isEmpty, !runningApps.contains(where: { $0.bundleID == bundleID }) {
                    Text(bundleID).tag(bundleID)
                }
                ForEach(runningApps) { app in
                    Text(app.name).tag(app.bundleID)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Running app")
            .accessibilityIdentifier("settings-trigger-condition-app-picker-\(rowID)")
        }
        .onAppear { runningApps = Self.regularRunningApps() }
    }

    private func timeOfDayEditor(start: Int, end: Int, weekdays: Set<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                DatePicker("From", selection: minuteBinding(start) { .timeOfDay(startMinute: $0, endMinute: end, weekdays: weekdays) },
                           displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("settings-trigger-condition-start-\(rowID)")
                DatePicker("To", selection: minuteBinding(end) { .timeOfDay(startMinute: start, endMinute: $0, weekdays: weekdays) },
                           displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("settings-trigger-condition-end-\(rowID)")
            }
            HStack(spacing: 8) {
                ForEach(Array(TriggerCondition.weekdayRange), id: \.self) { day in
                    Toggle(TriggerCondition.weekdayShortNames[day - 1], isOn: Binding(
                        get: { weekdays.contains(day) },
                        set: { selected in
                            var days = weekdays
                            if selected { days.insert(day) } else { days.remove(day) }
                            condition = .timeOfDay(startMinute: start, endMinute: end, weekdays: days)
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("settings-trigger-condition-weekday-\(day)-\(rowID)")
                }
            }
            Text(start == end
                 ? "Equal times mean the whole day."
                 : (start > end ? "Ends the next morning." : "Ends the same day."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func minuteBinding(_ minute: Int, update: @escaping (Int) -> TriggerCondition) -> Binding<Date> {
        Binding(
            get: { TriggerClockConversion.date(minuteOfDay: minute, timeZone: timeZone) },
            set: { condition = update(TriggerClockConversion.minuteOfDay($0, timeZone: timeZone)) }
        )
    }

    @MainActor
    private static func regularRunningApps() -> [RunningApp] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let bundleID = app.bundleIdentifier, seen.insert(bundleID).inserted else { return nil }
                return RunningApp(name: app.localizedName ?? bundleID, bundleID: bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Maps a minute of the day to a `Date` the hour-and-minute picker can edit and back. Hours and
/// minutes depend only on the time zone, and a fixed Gregorian day has no DST transition.
enum TriggerClockConversion {
    private static func clockCalendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func date(minuteOfDay: Int, timeZone: TimeZone) -> Date {
        let minute = min(max(minuteOfDay, TriggerCondition.minuteRange.lowerBound), TriggerCondition.minuteRange.upperBound)
        let components = DateComponents(year: 2001, month: 1, day: 1, hour: minute / 60, minute: minute % 60)
        return clockCalendar(timeZone).date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    static func minuteOfDay(_ date: Date, timeZone: TimeZone) -> Int {
        let components = clockCalendar(timeZone).dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

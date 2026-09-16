import BarKeepersFriendCore
import SwiftUI

/// Every committed preset edit is exactly one `model.preferences` assignment. Apply only replaces
/// the saved Shown/Hidden intent; the engine derives placement from that, nothing here moves items.
struct PresetsSettingsTab: View {
    @Bindable var model: SettingsModel
    @State private var newPresetName = ""

    private var presets: [LayoutPreset] { model.preferences.presets }
    private var activeID: UUID? { PresetLibrary.activePreset(in: model.preferences)?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    header
                        .settingsSearchTarget(.presets)
                    saveRow
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("settings-preset-save-row")
                        .settingsSearchTarget(.savePreset, including: presets.isEmpty ? SettingsSearchTarget.presetControls : [])
                }
                .padding(6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if presets.isEmpty {
                emptyState
                Spacer(minLength: 12)
            } else {
                presetList
            }

            footer
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-preset-content")
    }

    private var header: some View {
        Text("Applying a preset moves items to its saved arrangement and requires Accessibility.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-preset-header")
    }

    private var saveProblem: PresetLibrary.ValidationProblem? {
        PresetLibrary.addProblem(name: newPresetName, to: presets)
    }

    private var saveRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("New preset name", text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(savePreset)
                    .accessibilityLabel("New preset name")
                    .accessibilityIdentifier("settings-preset-new-name")
                Button("Save Current Layout", action: savePreset)
                    .disabled(saveProblem != nil)
                    .help("Save the current Shown/Hidden arrangement as a new preset.")
                    .accessibilityIdentifier("settings-preset-save")
            }
            // An untouched empty field is not a mistake yet; every other problem is shown live.
            if let problem = saveProblem, problem != .emptyName || !newPresetName.isEmpty {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-preset-save-error")
            }
        }
    }

    private func savePreset() {
        let current = model.preferences
        let preset = PresetLibrary.capturingCurrent(name: newPresetName, preferences: current)
        let updated = PresetLibrary.adding(preset, to: current.presets)
        guard updated != current.presets else { return }
        model.preferences.presets = updated
        newPresetName = ""
    }

    private var presetList: some View {
        GroupBox {
            List {
                ForEach(presets) { preset in
                    PresetRow(model: model, preset: preset, isActive: preset.id == activeID)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120, maxHeight: .infinity)
            .accessibilityIdentifier("settings-preset-list")
        }
        .padding(.horizontal, 20)
    }

    private var emptyState: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "square.on.square")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No presets yet.")
                        .font(.headline)
                    Text("Apply your arrangement in Items, then save it here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-preset-empty")
    }

    private var footer: some View {
        Text("Apply pending changes in Items before saving a preset. Item names are not included.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityIdentifier("settings-preset-footer")
    }
}

private struct PresetRow: View {
    @Bindable var model: SettingsModel
    let preset: LayoutPreset
    let isActive: Bool
    @State private var nameEdit: (text: String, baseline: String)?
    @State private var renameError: String?
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    private var countLabel: String {
        "\(preset.itemControls.hiddenInMenuBar.count) hidden, \(preset.itemControls.shownInMenuBar.count) shown"
    }

    private var applyHelp: String {
        isActive
            ? "This preset already matches the saved arrangement."
            : "Replace the saved arrangement with this preset and move items to match."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "square.on.square")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Preset name", text: Binding(
                        get: { nameEdit?.text ?? preset.name },
                        set: { text in
                            renameError = nil
                            nameEdit = text == preset.name ? nil : (text, nameEdit?.baseline ?? preset.name)
                        }
                    ))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .focused($nameFocused)
                    .accessibilityLabel("Name of preset \(preset.name)")
                    .accessibilityIdentifier("settings-preset-name-\(preset.id)")
                    .settingsSearchTarget(.presetName)
                    .help("Rename \(preset.name). Names save on Return or when you leave the field.")
                    // Committing only on Return or blur avoids persisting every keystroke.
                    .onSubmit { commitRename() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }

                    HStack(spacing: 8) {
                        Text(countLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-preset-counts-\(preset.id)")
                        if isActive {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                                .help("Matches the saved Shown/Hidden arrangement. Placement status is shown in Items.")
                                .accessibilityIdentifier("settings-preset-active-\(preset.id)")
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if !confirmingDelete {
                    HStack(spacing: 8) {
                        Button("Apply") { applyPreset() }
                            .disabled(isActive || model.placementInProgress)
                            .help(applyHelp)
                            .accessibilityIdentifier("settings-preset-apply-\(preset.id)")
                            .settingsSearchTarget(.applyPreset)
                        Button("Update from Current") { updatePreset() }
                            .disabled(isActive)
                            .help("Replace this preset's arrangement with the saved one.")
                            .accessibilityIdentifier("settings-preset-update-\(preset.id)")
                            .settingsSearchTarget(.updatePreset)
                        Button("Delete…") { confirmingDelete = true }
                            .help("Delete \(preset.name). The saved arrangement is not changed.")
                            .accessibilityIdentifier("settings-preset-delete-\(preset.id)")
                            .settingsSearchTarget(.deletePreset)
                    }
                    .controlSize(.small)
                }
            }

            if confirmingDelete {
                HStack(spacing: 8) {
                    Text("Delete \"\(preset.name)\"?")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("settings-preset-delete-prompt-\(preset.id)")
                    Spacer(minLength: 8)
                    Button("Cancel") { confirmingDelete = false }
                        .accessibilityIdentifier("settings-preset-cancel-delete-\(preset.id)")
                    Button("Delete", role: .destructive) { deletePreset() }
                        .accessibilityIdentifier("settings-preset-confirm-delete-\(preset.id)")
                        .settingsSearchTarget(.deletePreset)
                }
                .controlSize(.small)
                .padding(.top, 4)
            }

            if let renameError {
                Text(renameError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-preset-name-error-\(preset.id)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-preset-row-\(preset.id)")
        // A row can leave the list before its focus-loss callback commits the name.
        .onDisappear { commitRename() }
    }

    private func applyPreset() {
        // The stored `isActive` can lag a concurrent preferences change; recheck the live value.
        guard !model.placementInProgress, preset.itemControls != model.preferences.itemControls else { return }
        model.preferences = PresetLibrary.applying(preset, to: model.preferences)
    }

    private func updatePreset() {
        let current = model.preferences
        let updated = PresetLibrary.updating(id: preset.id, from: current, in: current.presets)
        guard updated != current.presets else { return }
        model.preferences.presets = updated
    }

    private func deletePreset() {
        confirmingDelete = false
        let current = model.preferences.presets
        let updated = PresetLibrary.removing(id: preset.id, from: current)
        guard updated != current else { return }
        model.preferences.presets = updated
    }

    private func commitRename() {
        guard let edit = nameEdit else { return }
        // A rename arriving during editing must not be overwritten by a stale Return or blur.
        guard preset.name == edit.baseline, edit.text != edit.baseline else {
            nameEdit = nil
            return
        }
        let current = model.preferences.presets
        if let problem = PresetLibrary.nameProblem(edit.text, existing: current, excludingID: preset.id) {
            // Keep the typed text so the user can fix it instead of retyping.
            renameError = problem.message
            return
        }
        nameEdit = nil
        let updated = PresetLibrary.renaming(id: preset.id, to: edit.text, in: current)
        if updated != current { model.preferences.presets = updated }
    }
}

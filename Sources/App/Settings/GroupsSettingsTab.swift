import AppKit
import BarKeepersFriendCore
import SwiftUI

/// Every committed group edit is exactly one `model.preferences` assignment; groups never touch
/// `ItemControlStore` directly, so the user's Shown/Hidden choices survive grouping.
struct GroupsSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        content
            .task { await model.reloadItems() }
    }

    var content: GroupsSettingsContent { GroupsSettingsContent(model: model) }
}

struct GroupsSettingsContent: View {
    @Bindable var model: SettingsModel
    @State private var newGroupName = ""

    private var groups: [ItemGroup] { model.preferences.itemGroups }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            createRow
            if let error = model.itemsLoadError {
                HStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-group-items-error")
                    Spacer(minLength: 0)
                    Button("Retry Reading") { Task { await model.reloadItems() } }
                        .controlSize(.small)
                        .disabled(model.itemsLoading)
                        .accessibilityIdentifier("settings-group-retry-reading")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if groups.isEmpty {
                emptyState
            } else {
                groupList
            }

            Divider()
            footer
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-group-content")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Item Groups")
                .font(.headline)
            Text("A group combines several items behind one icon in the menu bar. Grouped items are hidden from the menu bar and open from that icon's menu. Your Shown/Hidden choices in Items are kept but do not apply while an item is in a group.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var createProblem: ItemGroupLibrary.ValidationError? {
        if groups.count >= ItemGroupLibrary.maxGroups { return .tooManyGroups }
        return ItemGroupLibrary.nameProblem(newGroupName, in: groups)
    }

    private var createRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("New group name", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createGroup() }
                    .accessibilityLabel("New group name")
                    .accessibilityIdentifier("settings-group-new-name")
                Button("Create Group", action: createGroup)
                    .disabled(createProblem != nil)
                    .accessibilityIdentifier("settings-group-create")
                if model.itemsLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityIdentifier("settings-group-items-loading")
                }
            }
            // An untouched empty field is not a mistake yet; every other problem is shown live.
            if let problem = createProblem, problem != .emptyName || !newGroupName.isEmpty {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-group-create-error")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func createGroup() {
        guard let updated = try? ItemGroupLibrary.adding(name: newGroupName, to: groups) else { return }
        model.preferences.itemGroups = updated
        newGroupName = ""
    }

    private var groupList: some View {
        List {
            ForEach(groups) { group in
                Section {
                    GroupHeaderRow(model: model, group: group)
                    ForEach(memberRows(for: group)) { row in
                        GroupMemberRow(model: model, group: group, row: row)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 120, maxHeight: .infinity)
        .accessibilityIdentifier("settings-group-list")
    }

    /// Every loaded owner once (first appearance, left to right), then members without a running
    /// window so they can still be removed.
    private func memberRows(for group: ItemGroup) -> [GroupMemberRowModel] {
        var rows: [GroupMemberRowModel] = []
        var seen: Set<String> = []
        for item in model.loadedItems {
            guard let key = ItemControlStore.key(for: item.snapshot), seen.insert(key).inserted else { continue }
            var named = item
            named.alias = model.alias(for: item)
            rows.append(GroupMemberRowModel(
                groupID: group.id, key: key, name: named.displayName, image: item.image, isRunning: true
            ))
        }
        for key in group.ownerKeys where seen.insert(key).inserted {
            rows.append(GroupMemberRowModel(
                groupID: group.id, key: key, name: model.preferences.itemAliases.alias(forKey: key) ?? key,
                image: nil, isRunning: false
            ))
        }
        return rows
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No groups yet.")
                .font(.headline)
            Text("Create a group above, then check the items that belong in it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("settings-group-empty")
    }

    private var footer: some View {
        Text("Group changes apply right away and need no Apply Changes. Removing an item from a group leaves it where it is; use Items to show it again.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityIdentifier("settings-group-footer")
    }
}

struct GroupMemberRowModel: Identifiable {
    let groupID: UUID
    let key: String
    let name: String
    let image: NSImage?
    let isRunning: Bool

    /// Every section lists the same owners; a List reuses rows whose ids repeat across sections.
    var id: String { "\(groupID)-\(key)" }
}

private struct GroupHeaderRow: View {
    @Bindable var model: SettingsModel
    let group: ItemGroup
    @State private var nameEdit: (text: String, baseline: String)?
    @State private var renameError: String?
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    private var countLabel: String {
        group.ownerKeys.count == 1 ? "1 item" : "\(group.ownerKeys.count) items"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
                TextField("Group name", text: Binding(
                    get: { nameEdit?.text ?? group.name },
                    set: { text in
                        renameError = nil
                        nameEdit = text == group.name ? nil : (text, nameEdit?.baseline ?? group.name)
                    }
                ))
                .textFieldStyle(.plain)
                .font(.headline)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity)
                .focused($nameFocused)
                .accessibilityLabel("Name of group \(group.name)")
                .accessibilityIdentifier("settings-group-name-\(group.id)")
                .help("Rename \(group.name). Names save on Return or when you leave the field.")
                // Committing only on Return or blur avoids persisting every keystroke.
                .onSubmit { commitRename() }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { commitRename() }
                }

                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-group-count-\(group.id)")

                Spacer(minLength: 8)

                if confirmingDelete {
                    Text("Delete \"\(group.name)\"?")
                        .font(.callout)
                        .accessibilityIdentifier("settings-group-delete-prompt-\(group.id)")
                    Button("Cancel") { confirmingDelete = false }
                        .accessibilityIdentifier("settings-group-cancel-delete-\(group.id)")
                    Button("Delete", role: .destructive) { deleteGroup() }
                        .disabled(model.placementInProgress)
                        .accessibilityIdentifier("settings-group-confirm-delete-\(group.id)")
                } else {
                    Button("Delete…") { confirmingDelete = true }
                        .disabled(model.placementInProgress)
                        .help("Delete \(group.name). Its items leave the group and keep their saved placement.")
                        .accessibilityIdentifier("settings-group-delete-\(group.id)")
                }
            }
            .controlSize(.small)

            if let renameError {
                Text(renameError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-group-name-error-\(group.id)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        // Regrouping can remove a row before its focus-loss callback commits the name.
        .onDisappear { commitRename() }
    }

    private func commitRename() {
        guard let edit = nameEdit else { return }
        // A rename arriving during editing must not be overwritten by a stale Return or blur.
        guard group.name == edit.baseline, edit.text != edit.baseline else {
            nameEdit = nil
            return
        }
        let current = model.preferences.itemGroups
        do {
            let updated = try ItemGroupLibrary.renaming(groupID: group.id, to: edit.text, in: current)
            nameEdit = nil
            if updated != current { model.preferences.itemGroups = updated }
        } catch let error as ItemGroupLibrary.ValidationError {
            // Keep the typed text so the user can fix it; a deleted group has nothing left to fix.
            if error == .unknownGroup { nameEdit = nil } else { renameError = error.message }
        } catch {
            nameEdit = nil
        }
    }

    private func deleteGroup() {
        guard !model.placementInProgress else { return }
        confirmingDelete = false
        model.preferences.itemGroups = ItemGroupLibrary.removing(groupID: group.id, from: model.preferences.itemGroups)
    }
}

private struct GroupMemberRow: View {
    @Bindable var model: SettingsModel
    let group: ItemGroup
    let row: GroupMemberRowModel

    private var isMember: Bool { group.contains(key: row.key) }

    private var otherGroup: ItemGroup? {
        guard let owner = ItemGroupLibrary.group(containing: row.key, in: model.preferences.itemGroups),
              owner.id != group.id else { return nil }
        return owner
    }

    private var title: String {
        row.isRunning ? row.name : "\(row.name) (not running)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { isMember }, set: { setMembership($0) })) {
                HStack(spacing: 10) {
                    if let image = row.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                    }
                    Text(title)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(model.placementInProgress)
            .accessibilityLabel(otherGroup.map { "\(title), in \($0.name)" } ?? title)
            .accessibilityHint("Checked items belong to \(group.name). Checking an item moves it out of any other group.")
            .help(otherGroup.map { "Move \(row.name) from \($0.name) into \(group.name)." }
                  ?? "Include \(row.name) in \(group.name).")
            .accessibilityIdentifier("settings-group-member-\(group.id)-\(row.key)")

            // A sibling, not toggle label content: the toggle is one accessibility element.
            if let otherGroup {
                Text("In \(otherGroup.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-group-member-elsewhere-\(group.id)-\(row.key)")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func setMembership(_ member: Bool) {
        guard !model.placementInProgress else { return }
        let current = model.preferences.itemGroups
        let updated = member
            ? ItemGroupLibrary.assigning(key: row.key, to: group.id, in: current)
            : ItemGroupLibrary.unassigning(key: row.key, in: current)
        guard updated != current else { return }
        model.preferences.itemGroups = updated
    }
}

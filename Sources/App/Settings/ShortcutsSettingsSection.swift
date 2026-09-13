import BarKeepersFriendCore
import SwiftUI

/// General-tab sections for keyboard shortcuts: the toggle-bar shortcut (switch plus recorder)
/// and one recorder per manageable item. Every commit is a single `model.preferences` write.
/// `failures` are the keys `HotkeyService.lastRegistrationFailures` reported after the last apply.
struct ShortcutsSettingsSection: View {
    @Bindable var model: SettingsModel
    var failures: [String] = []

    struct Row: Identifiable, Equatable {
        let key: String
        let name: String
        /// False for a saved shortcut whose item is not in the menu bar right now (app quit).
        let isPresent: Bool
        var id: String { key }
    }

    static let itemHint = "An item shortcut reveals the hidden section and opens that item's menu. Needs Accessibility."
    static let unavailableText = "Shortcut unavailable, possibly claimed by another app."
    static let requiresFloatingBarText = "Not active: item shortcuts need the floating bar."

    var body: some View {
        Section("Shortcuts") {
            Toggle("Toggle the bar with a global shortcut", isOn: $model.preferences.enableGlobalHotkey)
                .accessibilityIdentifier("settings-shortcut-toggle-enabled")
            if model.preferences.enableGlobalHotkey {
                LabeledContent("Toggle bar") {
                    HotkeyRecorderView(
                        id: "settings-shortcut-toggle",
                        combo: model.preferences.toggleHotkey,
                        allowsClear: false,
                        conflict: { [model] combo in
                            HotkeyAssignments.conflict(for: combo, toggle: nil, itemHotkeys: model.preferences.itemHotkeys)
                        },
                        onCommit: { [model] combo in
                            if let combo { model.setToggleHotkey(combo) }
                        }
                    )
                }
                if failures.contains(HotkeyService.toggleFailureIdentifier) {
                    unavailable(id: "settings-shortcut-toggle-unavailable")
                }
            }
        }

        Section("Item shortcuts") {
            Text(Self.itemHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-shortcut-items-hint")

            // One line for the whole section; every row would otherwise repeat the same reason.
            if !model.preferences.useFloatingBar {
                Label(Self.requiresFloatingBarText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-shortcut-items-requires-floating-bar")
            }

            let rows = Self.rows(for: model)
            let plan = model.itemHotkeyPlan
            if rows.isEmpty {
                Text(model.itemsLoading ? "Reading the menu bar…" : "No manageable items found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(model.itemsLoading ? "settings-shortcut-items-loading" : "settings-shortcut-items-empty")
            }
            ForEach(rows) { row in
                itemRow(row, plan: plan)
            }
        }
        // The Items tab normally loads the list; this section may be the first one shown.
        .task { await model.reloadItems() }
    }

    /// Loaded items first (menu-bar order, one row per owner), then saved shortcuts for absent
    /// owners so a shortcut can still be cleared after its app quits.
    static func rows(for model: SettingsModel) -> [Row] {
        var seen: Set<String> = []
        var rows: [Row] = []
        for item in model.loadedItems {
            guard let key = ItemControlStore.key(for: item.snapshot), seen.insert(key).inserted else { continue }
            var named = item
            named.alias = model.alias(for: item)
            rows.append(Row(key: key, name: named.displayName, isPresent: true))
        }
        for key in model.preferences.itemHotkeys.keys.sorted() where !seen.contains(key) {
            rows.append(Row(key: key, name: model.preferences.itemAliases.alias(forKey: key) ?? key, isPresent: false))
        }
        return rows
    }

    @ViewBuilder
    private func itemRow(_ row: Row, plan: HotkeyAssignments.Plan) -> some View {
        LabeledContent {
            HotkeyRecorderView(
                id: "settings-shortcut-item-\(row.key)",
                combo: model.preferences.itemHotkeys[row.key],
                conflict: { [model] combo in
                    HotkeyAssignments.conflict(
                        for: combo,
                        toggle: model.preferences.toggleHotkey,
                        itemHotkeys: model.preferences.itemHotkeys,
                        excludingOwner: row.key
                    )
                },
                onCommit: { [model] combo in model.setItemHotkey(combo, forOwnerKey: row.key) }
            )
        } label: {
            Text(row.name)
                .lineLimit(1)
                .accessibilityIdentifier("settings-shortcut-item-\(row.key)-name")
            if !row.isPresent {
                Text("Not in the menu bar right now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-shortcut-item-\(row.key)-absent")
            }
        }
        if let reason = plan.skipped[row.key], reason != .requiresFloatingBar {
            Text(Self.inactiveText(for: reason))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-shortcut-item-\(row.key)-inactive")
        }
        if failures.contains(row.key) {
            unavailable(id: "settings-shortcut-item-\(row.key)-unavailable")
        }
    }

    private func unavailable(id: String) -> some View {
        Label(Self.unavailableText, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }

    /// Explains a saved shortcut the service will not register, using the same plan it follows.
    static func inactiveText(for reason: HotkeyAssignments.Plan.SkipReason) -> String {
        switch reason {
        case .notAssignable:
            "Not active: this saved shortcut is not usable. Record a new one."
        case .conflict(.systemReserved):
            "Not active: reserved by macOS. Record a new one."
        case .conflict(.toggleBar):
            "Not active: same as the toggle-bar shortcut."
        case .conflict(.item(let owner)):
            "Not active: \(owner) uses the same shortcut."
        case .overCapacity:
            "Not active: at most \(HotkeyAssignments.maxItemHotkeys) item shortcuts can be live."
        case .requiresFloatingBar:
            requiresFloatingBarText
        }
    }
}

extension SettingsModel {
    /// One preferences write per commit; an identical value writes nothing.
    func setToggleHotkey(_ combo: HotkeyCombo) {
        guard preferences.toggleHotkey != combo else { return }
        preferences.toggleHotkey = combo
    }

    /// One preferences write per commit; `nil` removes the entry, and an identical value writes nothing.
    func setItemHotkey(_ combo: HotkeyCombo?, forOwnerKey key: String) {
        guard preferences.itemHotkeys[key] != combo else { return }
        if let combo {
            preferences.itemHotkeys[key] = combo
        } else {
            preferences.itemHotkeys.removeValue(forKey: key)
        }
    }

    /// The service's registration plan for the current preferences, so rows never overstate what is live.
    var itemHotkeyPlan: HotkeyAssignments.Plan {
        HotkeyService.plan(for: preferences)
    }
}

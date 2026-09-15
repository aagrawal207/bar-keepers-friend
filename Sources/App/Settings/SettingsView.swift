import AppKit
import BarKeepersFriendCore
import SwiftUI

// Placement edits stay local to the Items tab's model until explicitly applied.
struct SettingsView: View {
    /// Raw values are sidebar accessibility identifiers; the cases are the window controller's API.
    enum Tab: String, CaseIterable, Identifiable {
        case general, items, style, behavior, shortcuts, presets, triggers, groups, widgets

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .items: "Items"
            case .style: "Style"
            case .behavior: "Behavior"
            case .shortcuts: "Shortcuts"
            case .presets: "Presets"
            case .triggers: "Triggers"
            case .groups: "Groups"
            case .widgets: "Widgets"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .items: "menubar.rectangle"
            case .style: "paintpalette"
            case .behavior: "slider.horizontal.3"
            case .shortcuts: "keyboard"
            case .presets: "square.on.square"
            case .triggers: "bolt"
            case .groups: "square.grid.2x2"
            case .widgets: "star.square.on.square"
            }
        }

        // Include conditional controls without mounting panes or reading the menu bar to index them.
        private var searchTerms: String {
            switch self {
            case .general:
                """
                Launch at login Permissions Accessibility Screen Recording
                Menu bar spacing Reduce menu bar item spacing Selection padding Reset to system default
                Backup Layout file Export Import startup
                """
            case .items:
                """
                Arrange Menu Bar Items Hidden Shown Always Hidden Placement Display name Show in bar
                Move earlier Move later Hide All Show All Apply Changes Discard Retry Retry Reading
                Placement Preview After Apply Last Observed apps applications alias aliases nickname rename order
                """
            case .style:
                """
                Style the menu bar Tint color Gradient end color Opacity Shape Full Rounded Pill
                Corner radius Border width Border color Shadow Preview Reset Style
                Icons Menu bar icon App icon symbol theme appearance styles styling colour transparency background
                """
                    + " " + AppIconChoice.MenuBarSymbol.allCases.map(\.displayName).joined(separator: " ")
                    + " " + AppIconChoice.AppTheme.allCases.map(\.displayName).joined(separator: " ")
            case .behavior:
                """
                Hidden items Show hidden items in a floating bar Floating bar style Horizontal strip Vertical list
                Dismiss the bar when the pointer leaves it
                Behavior Automatically re-hide Re-hide after Reveal on hover Reveal on scroll or swipe
                mouse auto-rehide delay
                Notch Make room near the notch Never When needed tuck shown items
                """
            case .shortcuts:
                """
                Shortcuts Item shortcuts Toggle the bar with a global shortcut Toggle bar Record Clear
                keyboard hotkey
                """
            case .presets:
                "Layout Presets New preset name Save Current Layout Rename Apply Update from Current Delete profiles arrangements"
            case .triggers:
                TriggerCondition.Kind.allCases.map(\.displayName).joined(separator: " ")
                    + " Add Rule Edit Rule Rule name Conditions Apply preset Add Condition Remove Condition Save Delete"
                    + " automatic automation percentage wifi network connected not connection application bundle monitor screen weekdays schedule"
            case .groups:
                "Item Groups New group name Create Group Rename Delete members membership add move remove apps applications"
            case .widgets:
                WidgetAction.Kind.allCases.map(\.displayName).joined(separator: " ")
                    + " Add Widget Edit Widget Name Symbol SF Symbol name Action Link Choose App Bundle identifier Shortcut name Save Delete"
                    + " custom menu bar icon url http https mail email application shortcuts"
            }
        }

        static func matching(_ query: String) -> [Self] {
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            func containsWords(_ text: String) -> Bool {
                words.allSatisfy { text.localizedStandardContains($0) }
            }
            let matches = allCases.filter { containsWords("\($0.title) \($0.searchTerms)") }
            return matches.filter { containsWords($0.title) } + matches.filter { !containsWords($0.title) }
        }
    }

    static let windowSize = CGSize(width: 820, height: 720)
    /// Tahoe floats the sidebar 8pt inside the window, so the detail keeps at least 630pt of width.
    static let sidebarWidth: CGFloat = 180

    @Bindable var model: SettingsModel
    @State private var selectedTab: Tab
    @State private var searchText = ""

    init(model: SettingsModel, initialTab: Tab = .general) {
        self.model = model
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        // A constant visibility plus no toggle keeps the sidebar, the only pane switcher, on screen.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // toolbar(removing:) must sit inside the width modifier; outside it, the width is lost.
            SettingsSidebar(selection: $selectedTab, searchText: $searchText, appTheme: model.preferences.appIcon.appTheme)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .onAppear { consumeRequestedTab() }
        .onChange(of: model.requestedTab) { _, _ in consumeRequestedTab() }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectedTab.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settings-detail-title")
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
            paneContent
        }
        // Fully flexible so the split view sizes this column: a column's minimum size becomes an
        // autolayout constraint, and wrapped pane text would make that minimum taller than the window.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-detail")
    }

    @ViewBuilder private var paneContent: some View {
        switch selectedTab {
        case .general: GeneralSettingsTab(model: model)
        case .items: ItemsSettingsTab(model: model)
        case .style: StyleSettingsTab(model: model)
        case .behavior: BehaviorSettingsTab(model: model)
        case .shortcuts: ShortcutsSettingsTab(model: model)
        case .presets: PresetsSettingsTab(model: model)
        case .triggers: TriggersSettingsTab(model: model)
        case .groups: GroupsSettingsTab(model: model)
        case .widgets: WidgetsSettingsTab(model: model)
        }
    }

    private func consumeRequestedTab() {
        guard let tab = model.requestedTab else { return }
        searchText = ""
        selectedTab = tab
        model.requestedTab = nil
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            LaunchAtLoginSection(model: model)

            PermissionsSection(model: model)

            // System-wide and logout-gated like Launch at login, so it sits with the other machine settings.
            SpacingSettingsSection(model: model, needsLogout: model.spacingNeedsLogout)

            BackupSettingsSection(model: model)
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-general-content")
    }
}

// MARK: - Behavior tab

private struct BehaviorSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Hidden items") {
                Toggle("Show hidden items in a floating bar", isOn: $model.preferences.useFloatingBar)
                if model.preferences.useFloatingBar {
                    Picker("Floating bar style", selection: $model.preferences.floatingBarStyle) {
                        Text("Horizontal strip").tag(FloatingBarStyle.horizontal)
                        Text("Vertical list").tag(FloatingBarStyle.vertical)
                    }
                    .pickerStyle(.radioGroup)
                    Toggle("Dismiss the bar when the pointer leaves it", isOn: $model.preferences.dismissBarOnMouseExit)
                }
            }

            Section("Behavior") {
                Toggle("Automatically re-hide", isOn: $model.preferences.autoRehide)
                if model.preferences.autoRehide {
                    LabeledContent("Re-hide after") {
                        Stepper(
                            value: $model.preferences.autoRehideDelay,
                            in: Preferences.autoRehideDelayRange,
                            step: 1
                        ) {
                            Text("\(Int(model.preferences.autoRehideDelay))s")
                        }
                    }
                }
                Toggle("Reveal on hover", isOn: $model.preferences.revealOnHover)
                    .disabled(!model.preferences.useFloatingBar)
                Text("Hover over the BKF icon to open the floating bar. Moving away closes only a hover-opened bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Reveal on scroll or swipe", isOn: $model.preferences.revealOnScroll)
                    .disabled(!model.preferences.useFloatingBar)
                Text("Scroll down or swipe left on the menu bar to open the floating bar; the opposite gesture closes it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NotchSettingsSection(model: model, mode: $model.preferences.notchOverflow)
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-behavior-content")
        // The notch section warns when Accessibility is missing; the probe lives in General's pane,
        // so this pane refreshes it too or a stale "Not granted" warning would show here.
        .onAppear { model.refreshPermissions() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.refreshPermissions()
            }
        }
    }
}

// MARK: - Shortcuts tab

private struct ShortcutsSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            ShortcutsSettingsSection(model: model, failures: model.hotkeyRegistrationFailures)
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-shortcuts-content")
    }
}

/// The "General" section. `register()` can succeed while macOS still waits for the user's
/// approval, so the toggle alone would show "on" for an item that never launches.
struct LaunchAtLoginSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .accessibilityIdentifier("settings-launch-at-login")
            if let notice = model.loginItemNotice {
                HStack(spacing: 8) {
                    Label(notice.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-launch-at-login-notice")
                    Spacer(minLength: 8)
                    if notice == .needsApproval {
                        Button("Open Login Items…") { model.openLoginItemSettings() }
                            .controlSize(.small)
                            .accessibilityIdentifier("settings-launch-at-login-open")
                    }
                }
            }
        }
        .onAppear { model.refreshLoginItemStatus() }
        .task {
            // Approval happens in System Settings; poll so the notice clears without reopening.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.refreshLoginItemStatus()
            }
        }
    }
}

struct BackupSettingsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section("Backup") {
            LabeledContent("Layout file") {
                HStack {
                    Button("Export…") { model.exportLayout() }
                        .accessibilityIdentifier("settings-backup-export")
                    Button("Import…") { model.importLayout() }
                        .accessibilityIdentifier("settings-backup-import")
                }
            }
            if let message = model.transferMessage {
                // A write failure carries the system's full sentence; wrap it rather than truncate.
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.transferFailed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-backup-status")
            }
        }
    }
}

// MARK: - Permissions section

/// Surfaces the two optional permissions the Pro features rely on, so the user isn't left with a
/// silently-failing "Hidden" toggle or blank icons. Each row shows the live status and, when not
/// granted, a button that routes to the right System Settings pane. Polls while visible so a grant
/// the user just flipped in System Settings updates here without reopening Settings.
///
/// Both permissions are OPTIONAL — the cosmetic hide/show baseline needs neither — so this never
/// nags or blocks; it explains what each unlocks and gets out of the way once granted.
private struct PermissionsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section("Permissions") {
            PermissionRow(
                model: model,
                permission: .accessibility,
                title: "Accessibility",
                purpose: "Lets the app hide and reveal menu bar items by moving them."
            )
            PermissionRow(
                model: model,
                permission: .screenRecording,
                title: "Screen Recording",
                purpose: "Lets the floating bar show each hidden icon's real image."
            )
        }
        .onAppear { model.refreshPermissions() }
        .task {
            // Poll gently while Settings is open so a just-granted permission flips to "Granted"
            // without the user having to reopen the window. Two cheap syscalls per tick.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.refreshPermissions()
            }
        }
    }
}

/// One permission row: title + one-line purpose, a status chip, and (only when not granted) an
/// "Open Settings…" button.
private struct PermissionRow: View {
    @Bindable var model: SettingsModel
    let permission: Permission
    let title: String
    let purpose: String

    private var status: PermissionStatus { model.status(of: permission) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                statusChip
                Spacer(minLength: 8)
                if status != .granted {
                    Button("Open Settings…") { model.openPermissionSettings(permission) }
                        .controlSize(.small)
                }
            }
            Text(purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusChip: some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        case .lapsed:
            Label("Needs re-approval", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        case .denied, .notDetermined:
            Label("Not granted", systemImage: "circle")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .font(.caption)
        }
    }
}

// MARK: - Items tab

struct ItemsSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        content
            .task { await model.reloadItems() }
    }

    var content: ItemsSettingsContent { ItemsSettingsContent(model: model) }
}

struct ItemsSettingsContent: View {
    @Bindable var model: SettingsModel
    private var items: [FloatingBarItem] { model.loadedItems }
    private var loading: Bool { model.itemsLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            placementPreview
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            listHeader

            if let error = model.itemsLoadError {
                HStack(spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-items-error")
                    Spacer(minLength: 0)
                    Button("Retry Reading") { Task { await model.reloadItems() } }
                        .controlSize(.small)
                        .disabled(loading)
                        .accessibilityIdentifier("settings-items-retry-reading")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if loading && items.isEmpty {
                loadingState
            } else if items.isEmpty {
                emptyState
            } else {
                groupedList
            }

            Divider()
            placementFooter
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-items-content")
    }

    private var placementPreview: some View {
        let preview = model.placementPreview
        return SettingsPlacementPreview(
            shown: preview.shown, hidden: preview.hidden, alwaysHidden: preview.alwaysHidden, unknown: preview.unknown,
            style: model.preferences.floatingBarStyle,
            useFloatingBar: model.preferences.useFloatingBar,
            hasPendingChanges: model.hasPendingChanges,
            placementInProgress: model.placementInProgress,
            anchorSymbol: model.preferences.appIcon.menuBarSymbol
        )
    }

    private var groupedList: some View {
        let parts = model.partition(items)
        return List {
            if !parts.hidden.isEmpty {
                Section("Hidden (\(parts.hidden.count))") {
                    ForEach(parts.hidden) { item in
                        ItemRow(model: model, item: item)
                    }
                }
            }
            if !parts.alwaysHidden.isEmpty {
                Section("Always Hidden (\(parts.alwaysHidden.count))") {
                    ForEach(parts.alwaysHidden) { item in
                        ItemRow(model: model, item: item)
                    }
                }
            }
            if !parts.shown.isEmpty {
                Section("Shown (\(parts.shown.count))") {
                    ForEach(parts.shown) { item in
                        ItemRow(model: model, item: item)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 120, maxHeight: .infinity)
        .accessibilityIdentifier("settings-items-list")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Arrange Menu Bar Items")
                .font(.headline)
            Text("Choose Shown, Hidden, or Always Hidden, review the preview, then Apply Changes. Editing placement here does not move items. Always Hidden items appear only when you Option-click the BKF icon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Show in bar and the order arrows change only the floating bar and save immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-items-bar-controls-help")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("Items (\(items.count))")
                .font(.subheadline.weight(.medium))
            if loading && !items.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                Text("Refreshing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-items-refreshing")
            }
            Spacer()
            if !items.isEmpty {
                bulkActions
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var bulkActions: some View {
        HStack(spacing: 8) {
            Button("Hide All") {
                model.setPlacement(.hidden, forAll: items)
            }
            .disabled(!model.canSetPlacement(.hidden, forAll: items))
            .accessibilityIdentifier("settings-placement-hide-all")
            Button("Show All") {
                model.setPlacement(.shown, forAll: items)
            }
            .disabled(!model.canSetPlacement(.shown, forAll: items))
            .accessibilityIdentifier("settings-placement-show-all")
        }
        .controlSize(.small)
    }

    private var placementFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.placementInProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    placementStatus(model.placementMessage ?? "Applying placement...")
                }
            } else if let message = model.placementMessage {
                placementStatus(message)
            } else if model.placementFailed {
                placementStatus("Placement could not be completed. Retry to try the saved placement again.")
            } else if model.placementPending {
                placementStatus("Saved placement is waiting to be applied.")
            }
            if let notice = model.draftDiscardedNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-placement-draft-discarded")
            }

            HStack(spacing: 8) {
                Text(model.pendingChangeCount == 1 ? "1 pending change" : "\(model.pendingChangeCount) pending changes")
                    .font(.callout)
                    .help("Placement drafts remain when Settings closes, but are not saved across app restarts. Discard affects placement edits only.")
                    .accessibilityIdentifier("settings-placement-count")
                Spacer(minLength: 8)
                if !model.hasPendingChanges && (model.placementFailed || model.placementPending) {
                    Button("Retry") { model.retryPlacement() }
                        .disabled(model.placementInProgress)
                        .help("Try the saved placement again.")
                        .accessibilityIdentifier("settings-placement-retry")
                }
                Button("Discard") { model.discardPlacementChanges() }
                    .disabled(!model.hasPendingChanges || model.placementInProgress)
                    .accessibilityIdentifier("settings-placement-discard")
                Button("Apply Changes") { model.applyPlacementChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasPendingChanges || model.placementInProgress)
                    .accessibilityIdentifier("settings-placement-apply")
            }
            Text("Apply and Discard affect placement only. Names save separately on Return or when you leave the field.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-placement-footer")
    }

    private func placementStatus(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(model.placementFailed && !model.placementInProgress ? .red : .secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(message)
            .accessibilityIdentifier("settings-placement-status")
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("Reading the menu bar…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-items-loading")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "menubar.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(model.itemsLoadError == nil ? "No manageable items found." : "Items could not be loaded.")
                .font(.headline)
            Text(model.itemsLoadError == nil
                 ? "This list contains manageable menu bar items, not every system item."
                 : "Use Retry Reading to load the items again. Your placement draft is kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ItemRow: View {
    @Bindable var model: SettingsModel
    let item: FloatingBarItem
    @State private var aliasEdit: (text: String, baseline: String)?
    @FocusState private var aliasFocused: Bool

    private var displayName: String {
        var current = item
        current.alias = model.alias(for: item)
        return current.displayName
    }

    private var placement: ItemPlacement { model.placement(of: item) }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .opacity(placement.isHidden ? 0.5 : 1)

            TextField(displayName, text: Binding(
                get: { aliasEdit?.text ?? model.alias(for: item) },
                set: { text in
                    let saved = model.alias(for: item)
                    aliasEdit = text == saved ? nil : (text, aliasEdit?.baseline ?? saved)
                }
            ))
                .textFieldStyle(.plain)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity)
                .focused($aliasFocused)
                .accessibilityLabel("Display name for \(displayName)")
                .accessibilityIdentifier("settings-item-alias-\(item.id)")
                .help("Rename \(displayName). Names save on Return or when you leave the field; they do not need Apply.")
                // Committing only on Return or blur avoids persisting every keystroke.
                .onSubmit { commitAlias() }
                .onChange(of: aliasFocused) { _, focused in
                    if !focused { commitAlias() }
                }

            Spacer(minLength: 8)

            if let group = model.group(containing: item) {
                Text("In group \(group.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Grouped items stay hidden behind their group icon. Manage them in the Groups tab.")
                    .accessibilityIdentifier("settings-item-grouped-\(item.id)")
            } else if model.hasPendingChange(for: item) {
                Text("Pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-item-pending-\(item.id)")
            } else if item.observedPlacement == nil {
                Text("Unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("No placement observation is available. The control shows saved intent or its default, not a confirmed position.")
            }

            if placement.isHidden {
                barControls
            }

            Picker("", selection: Binding(
                get: { placement },
                set: { model.setPlacement($0, for: item) }
            )) {
                Text("Shown").tag(ItemPlacement.shown)
                Text("Hidden").tag(ItemPlacement.hidden)
                Text("Always Hidden").tag(ItemPlacement.alwaysHidden)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.placementInProgress || model.group(containing: item) != nil)
            .accessibilityLabel("Placement for \(displayName)")
            .accessibilityHint("Changes are staged until you choose Apply Changes.")
            .help("Placement for \(displayName). Changes are staged until Apply Changes. Always Hidden items show only on Option-click.")
            .accessibilityIdentifier("settings-item-placement-\(item.id)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        // Regrouping can remove a row before its focus-loss callback commits the name.
        .onDisappear { commitAlias() }
    }

    /// Floating-bar presentation for tucked rows; these save immediately and never move an item.
    private var barControls: some View {
        HStack(spacing: 4) {
            Toggle("Show in bar", isOn: Binding(
                get: { model.isShownInBar(item) },
                set: { model.setShownInBar($0, for: item) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .help("Draw \(displayName) in the floating bar. Off keeps it hidden in the menu bar without a bar icon. Saves immediately.")
            .accessibilityIdentifier("settings-item-bar-visible-\(item.id)")
            Button {
                model.moveInBar(item, .earlier)
            } label: {
                Image(systemName: "chevron.up")
            }
            .controlSize(.small)
            .disabled(!model.canMoveInBar(item, .earlier))
            .help("Move \(displayName) earlier in the floating bar (left in a strip, up in a list). Saves immediately.")
            .accessibilityLabel("Move \(displayName) earlier in the bar")
            .accessibilityIdentifier("settings-item-bar-earlier-\(item.id)")
            Button {
                model.moveInBar(item, .later)
            } label: {
                Image(systemName: "chevron.down")
            }
            .controlSize(.small)
            .disabled(!model.canMoveInBar(item, .later))
            .help("Move \(displayName) later in the floating bar (right in a strip, down in a list). Saves immediately.")
            .accessibilityLabel("Move \(displayName) later in the bar")
            .accessibilityIdentifier("settings-item-bar-later-\(item.id)")
        }
    }

    private func commitAlias() {
        guard let edit = aliasEdit else { return }
        aliasEdit = nil
        // A rename arriving during editing must not be overwritten by a stale Return or blur.
        guard model.alias(for: item) == edit.baseline, edit.text != edit.baseline else { return }
        model.setAlias(edit.text, for: item)
    }
}

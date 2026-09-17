import AppKit
import BarKeepersFriendCore
import SwiftUI

// Placement edits stay local to the Items tab's model until explicitly applied.
struct SettingsView: View {
    /// Raw values are sidebar accessibility identifiers; the cases are the window controller's API.
    enum Tab: String, CaseIterable, Identifiable, Sendable {
        case general, items, style, behavior, shortcuts, advanced, presets, triggers, groups, about

        var id: Self { self }
        static let advancedTabs: [Self] = [.presets, .triggers, .groups]
        static var sidebarTabs: [Self] { allCases.filter { $0.sidebarTab == $0 } }
        var sidebarTab: Self { Self.advancedTabs.contains(self) ? .advanced : self }

        var title: String {
            switch self {
            case .general: "General"
            case .items: "Items"
            case .style: "Style"
            case .behavior: "Behavior"
            case .shortcuts: "Shortcuts"
            case .advanced: "Advanced"
            case .presets: "Presets"
            case .triggers: "Triggers"
            case .groups: "Groups"
            case .about: "About"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .items: "menubar.rectangle"
            case .style: "paintpalette"
            case .behavior: "slider.horizontal.3"
            case .shortcuts: "keyboard"
            case .advanced: "gearshape.2"
            case .presets: "square.on.square"
            case .triggers: "bolt"
            case .groups: "square.grid.2x2"
            case .about: "info.circle"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "Start with the basics and permissions."
            case .items: "Choose which icons stay in your menu bar."
            case .style: "Choose the look of your menu bar and BKF."
            case .behavior: "Choose how hidden icons appear and close."
            case .shortcuts: "Open the bar or an item from your keyboard."
            case .advanced: "Optional tools and menu bar adjustments."
            case .presets: "Save arrangements you can switch between."
            case .triggers: "Apply a preset when your conditions are met."
            case .groups: "Collect related icons under one menu bar button."
            case .about: "Version, project information, and help."
            }
        }
    }

    static let windowSize = CGSize(width: 820, height: 720)
    /// Tahoe floats the sidebar 8pt inside the window, so the detail keeps at least 630pt of width.
    static let sidebarWidth: CGFloat = 180

    @Bindable var model: SettingsModel
    @State private var selectedTab: Tab
    @State private var searchText = ""
    @State private var searchHighlight: SettingsSearchHighlight?

    init(model: SettingsModel, initialTab: Tab = .general) {
        self.model = model
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        // A constant visibility plus no toggle keeps the sidebar, the only pane switcher, on screen.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // toolbar(removing:) must sit inside the width modifier; outside it, the width is lost.
            SettingsSidebar(selection: sidebarSelection, searchText: $searchText, appTheme: model.preferences.appIcon.appTheme) { tab, query in
                searchHighlight = SettingsSearchHighlight(targets: tab.highlightTargets(for: query))
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .onAppear { consumeRequestedTab() }
        .onChange(of: model.requestedTab) { _, _ in consumeRequestedTab() }
        .onChange(of: searchText) { _, query in
            if !query.isEmpty { searchHighlight = nil }
        }
        .onDisappear { searchHighlight = nil }
        .task(id: searchHighlight?.id) {
            guard let id = searchHighlight?.id else { return }
            do { try await Task.sleep(for: SettingsSearchHighlight.duration) } catch { return }
            if searchHighlight?.id == id { searchHighlight = nil }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: selectedTab.systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTab.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("settings-detail-title")
                        .settingsSearchTarget(.pageTitle)
                    Text(selectedTab.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selectedTab.sidebarTab == .advanced, selectedTab != .advanced {
                    Button { sidebarSelection.wrappedValue = .advanced } label: {
                        Label("Advanced", systemImage: "chevron.left")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Advanced")
                    .accessibilityIdentifier("settings-back-to-advanced")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider()
            paneContent
        }
        // Fully flexible so the split view sizes this column: a column's minimum size becomes an
        // autolayout constraint, and wrapped pane text would make that minimum taller than the window.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-detail")
        .environment(\.settingsSearchHighlight, searchHighlight)
    }

    private var sidebarSelection: Binding<Tab> {
        Binding(get: { selectedTab }, set: { tab in
            if selectedTab != tab { searchHighlight = nil }
            selectedTab = tab
        })
    }

    @ViewBuilder private var paneContent: some View {
        switch selectedTab {
        case .general: GeneralSettingsTab(model: model) { sidebarSelection.wrappedValue = .items }
        case .items: ItemsSettingsTab(model: model)
        case .style: StyleSettingsTab(model: model)
        case .behavior: BehaviorSettingsTab(model: model)
        case .shortcuts: ShortcutsSettingsTab(model: model)
        case .advanced: AdvancedSettingsTab(model: model) { sidebarSelection.wrappedValue = $0 }
        case .presets: PresetsSettingsTab(model: model)
        case .triggers: TriggersSettingsTab(model: model)
        case .groups: GroupsSettingsTab(model: model)
        case .about: AboutSettingsTab(model: model)
        }
    }

    private func consumeRequestedTab() {
        guard let tab = model.requestedTab else { return }
        searchText = ""
        searchHighlight = nil
        selectedTab = tab
        model.requestedTab = nil
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @Bindable var model: SettingsModel
    let showItems: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep the icons you need")
                            .font(.headline)
                        Text("Choose Hidden in Items, then Apply Changes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Arrange Items…", action: showItems)
                        .accessibilityIdentifier("settings-open-items")
                        .settingsSearchTarget(.arrangeItems)
                }
                .padding(.vertical, 4)
            } header: {
                SettingsSearchSectionHeading(target: .getStarted, id: "settings-get-started-heading")
            }

            LaunchAtLoginSection(model: model)

            PermissionsSection(model: model)
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
            Section {
                Toggle("Show hidden items in a floating bar", isOn: $model.preferences.useFloatingBar)
                    .accessibilityIdentifier("settings-floating-bar-enabled")
                    .settingsSearchTarget(.floatingBar, including: model.preferences.useFloatingBar ? [] : [.floatingBarStyle, .dismissOnExit])
                if model.preferences.useFloatingBar {
                    Picker("Floating bar style", selection: $model.preferences.floatingBarStyle) {
                        Text("Horizontal strip").tag(FloatingBarStyle.horizontal)
                        Text("Vertical list").tag(FloatingBarStyle.vertical)
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("settings-floating-bar-style")
                    .settingsSearchTarget(.floatingBarStyle)
                }
            } header: {
                SettingsSearchSectionHeading(target: .hiddenItems, id: "settings-hidden-items-heading")
            }

            Section {
                Toggle("Automatically re-hide", isOn: $model.preferences.autoRehide)
                    .accessibilityIdentifier("settings-auto-rehide")
                    .settingsSearchTarget(.autoRehide, including: model.preferences.autoRehide ? [] : [.autoRehideDelay])
                if model.preferences.autoRehide {
                    LabeledContent("Re-hide after") {
                        Stepper(
                            value: $model.preferences.autoRehideDelay,
                            in: Preferences.autoRehideDelayRange,
                            step: 1
                        ) {
                            Text("\(Int(model.preferences.autoRehideDelay))s")
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-auto-rehide-delay-row")
                    .settingsSearchTarget(.autoRehideDelay)
                }
                if model.preferences.useFloatingBar {
                    Toggle("Dismiss the bar when the pointer leaves it", isOn: $model.preferences.dismissBarOnMouseExit)
                        .accessibilityIdentifier("settings-dismiss-on-exit")
                        .settingsSearchTarget(.dismissOnExit)
                }
            } header: {
                SettingsSearchSectionHeading(target: .closingBar, id: "settings-closing-bar-heading")
            }

            Section {
                Toggle("Reveal on hover", isOn: $model.preferences.revealOnHover)
                    .disabled(!model.preferences.useFloatingBar)
                    .accessibilityIdentifier("settings-reveal-hover")
                    .settingsSearchTarget(.hover)
                Text("Hover over BKF to open the floating bar. Moving away closes only a hover-opened bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Reveal on scroll or swipe", isOn: $model.preferences.revealOnScroll)
                    .disabled(!model.preferences.useFloatingBar)
                    .accessibilityIdentifier("settings-reveal-scroll")
                    .settingsSearchTarget(.scroll)
                Text("Scroll down or swipe left on the menu bar to open; reverse the gesture to close.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-scroll-description")
            } header: {
                SettingsSearchSectionHeading(target: .revealGestures, id: "settings-reveal-gestures-heading")
            }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-behavior-content")
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
        Section {
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .accessibilityIdentifier("settings-launch-at-login")
                .settingsSearchTarget(.launchAtLogin)
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
        } header: {
            SettingsSearchSectionHeading(target: .startup, id: "settings-startup-heading")
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
        Section {
            LabeledContent("Layout file") {
                HStack {
                    Button("Export…") { model.exportLayout() }
                        .accessibilityIdentifier("settings-backup-export")
                        .settingsSearchTarget(.exportLayout)
                    Button("Import…") { model.importLayout() }
                        .accessibilityIdentifier("settings-backup-import")
                        .settingsSearchTarget(.importLayout)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-backup-row")
            .settingsSearchTarget(.layoutFile)
            if let message = model.transferMessage {
                // A write failure carries the system's full sentence; wrap it rather than truncate.
                Text(message)
                    .font(.callout)
                    .foregroundStyle(model.transferFailed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-backup-status")
            }
        } header: {
            SettingsSearchSectionHeading(target: .backup, id: "settings-backup-heading")
        }
    }
}

// MARK: - Permissions section

/// Permissions unlock item placement and the mirror; neither is required for basic in-place hiding.
private struct PermissionsSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section {
            PermissionRow(
                model: model,
                permission: .accessibility,
                title: "Accessibility",
                purpose: "Lets Apply Changes move icons and lets the floating bar open their menus."
            )
            PermissionRow(
                model: model,
                permission: .screenRecording,
                title: "Screen Recording",
                purpose: "Lets the floating bar show each hidden icon's real image."
            )
        } header: {
            SettingsSearchSectionHeading(target: .permissions, id: "settings-permissions-heading")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-permission-\(permission.rawValue)")
        .settingsSearchTarget(permission == .accessibility ? .accessibility : .screenRecording)
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
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-placement-preview")
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
        .onDisappear { model.cancelPlacementDrag() }
    }

    private var placementPreview: some View {
        let preview = model.placementPreview(includingSuppressed: true)
        return SettingsPlacementPreview(
            shown: preview.shown, hidden: preview.hidden, alwaysHidden: preview.alwaysHidden, unknown: preview.unknown,
            style: model.preferences.floatingBarStyle,
            useFloatingBar: model.preferences.useFloatingBar,
            hasPendingChanges: model.hasPendingChanges,
            placementInProgress: model.placementInProgress,
            anchorSymbol: model.preferences.appIcon.menuBarSymbol,
            dragModel: model
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
            Text("Drag icons between bars or between other icons to reorder. Apply Changes saves the arrangement; Discard undoes your edits.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Icons from the same app move together. Show in bar saves immediately; ordering waits for Apply.")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-items-list-header")
        .settingsSearchTarget(.itemArrangement, including: items.isEmpty ? [.bulkPlacement] : [])
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-placement-bulk")
        .settingsSearchTarget(.bulkPlacement)
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
                    .help("Placement and order drafts remain when Settings closes, but are not saved across app restarts.")
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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-placement-actions")
            .settingsSearchTarget(.placementActions)
            Text("Apply and Discard affect placement and order. Names save separately on Return or when you leave the field.")
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

    /// Visibility saves independently; order arrows share the drag editor's draft.
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
            .help("Move \(displayName) earlier (left in a strip, up in a list), then Apply Changes.")
            .accessibilityLabel("Move \(displayName) earlier in the bar")
            .accessibilityIdentifier("settings-item-bar-earlier-\(item.id)")
            Button {
                model.moveInBar(item, .later)
            } label: {
                Image(systemName: "chevron.down")
            }
            .controlSize(.small)
            .disabled(!model.canMoveInBar(item, .later))
            .help("Move \(displayName) later (right in a strip, down in a list), then Apply Changes.")
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

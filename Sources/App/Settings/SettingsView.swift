import BarKeepersFriendCore
import SwiftUI

/// The settings UI: a tabbed window. "General" holds the behavior toggles; "Items" is the
/// per-item manager (show-in-bar / search-only, alias, order) plus an honest, read-only
/// reflection of the OS-owned visible/hidden state.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            GeneralSettingsTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            ItemsSettingsTab(model: model)
                .tabItem { Label("Items", systemImage: "menubar.rectangle") }
        }
        .frame(width: 460, height: 580)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
            }

            PermissionsSection(model: model)

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

            Section("Shortcut") {
                Toggle("Toggle the bar with a global shortcut", isOn: $model.preferences.enableGlobalHotkey)
                if model.preferences.enableGlobalHotkey {
                    LabeledContent("Toggle bar") {
                        Text(HotkeyCarbon.displayString(for: model.preferences.toggleHotkey))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Auto re-hide") {
                Toggle("Automatically re-hide", isOn: $model.preferences.autoRehide)
                if model.preferences.autoRehide {
                    LabeledContent("Re-hide after") {
                        Stepper(
                            value: $model.preferences.autoRehideDelay,
                            in: 2...120,
                            step: 1
                        ) {
                            Text("\(Int(model.preferences.autoRehideDelay))s")
                        }
                    }
                }
            }

            Section("Backup") {
                LabeledContent("Layout file") {
                    HStack {
                        Button("Export…") { model.exportLayout() }
                        Button("Import…") { model.importLayout() }
                    }
                }
                if let message = model.transferMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(model.transferFailed ? .red : .secondary)
                }
            }

            Section {
                // A plain full-width row, not a LabeledContent: a "Tip" label would claim the
                // leading column and squeeze this sentence into a narrow trailing one, wrapping it
                // into ragged lines. Spanning the row lets it sit on one line (or wrap cleanly to
                // two if the window is narrow). fixedSize(vertical) lets it grow to whatever height
                // the wrapped text needs instead of being clipped to one line.
                Text("Tip: click the menu bar anchor to reveal hidden items, or right-click it to open settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
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

/// Per-item manager: a single list of every menu bar item with a Shown / Hidden control. Flipping
/// an item to Hidden moves it behind the anchor (into the floating bar); Shown moves it back. This
/// is the whole point of the app, made direct — no dragging, no jargon.
private struct ItemsSettingsTab: View {
    @Bindable var model: SettingsModel
    /// The listed items, loaded asynchronously (enumerating + attributing the live menu bar).
    @State private var items: [FloatingBarItem] = []
    @State private var loading = true
    /// Bumped when a row's Shown/Hidden flips, to force a cheap re-partition (no menu-bar re-scan)
    /// so the row visibly moves between sections. Re-enumerating on every toggle would flash the
    /// loading spinner for a second; the item set hasn't changed, only the intent has.
    @State private var repartitionToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if loading {
                loadingState
            } else if items.isEmpty {
                emptyState
            } else {
                groupedList
            }
        }
        .padding(.top, 8)
        .task { await reload() }
    }

    /// The items split into "Hidden (N)" and "Shown (N)" sections, so the two states are easy to
    /// scan rather than interleaved. Toggling a row re-partitions on the next reload, which is
    /// triggered by the row itself after the move settles.
    private var groupedList: some View {
        // `repartitionToken` is read so SwiftUI re-evaluates this when a toggle bumps it.
        _ = repartitionToken
        let parts = model.partition(items)
        return List {
            if !parts.hidden.isEmpty {
                Section("Hidden (\(parts.hidden.count))") {
                    ForEach(parts.hidden) { item in
                        ItemRow(model: model, item: item, onToggle: { repartitionToken += 1 })
                    }
                }
            }
            if !parts.shown.isEmpty {
                Section("Shown (\(parts.shown.count))") {
                    ForEach(parts.shown) { item in
                        ItemRow(model: model, item: item, onToggle: { repartitionToken += 1 })
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Reloads the list. Run on appear; also re-run after a toggle so the new Shown/Hidden state
    /// is reflected once the move settles.
    private func reload() async {
        loading = true
        items = await model.items()
        loading = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Choose which menu bar items to hide.")
                    .font(.callout)
                Spacer()
                if !loading && !items.isEmpty {
                    bulkActions
                }
            }
            Text("Hidden items move into Bar Keeper's Friend's bar — click the menu bar icon (or press the shortcut) to reveal them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// "Hide all" / "Show all" bulk toggles. Each is disabled when it would be a no-op (everything
    /// already in that state), so the buttons double as a hint of the current split. Both mutate
    /// the intent once (single reconcile) and re-partition so rows resettle into their sections.
    private var bulkActions: some View {
        let parts = model.partition(items)
        return HStack(spacing: 8) {
            Button("Hide All") {
                model.setHidden(true, forAll: items)
                repartitionToken += 1
            }
            .disabled(parts.shown.isEmpty)
            Button("Show All") {
                model.setHidden(false, forAll: items)
                repartitionToken += 1
            }
            .disabled(parts.hidden.isEmpty)
        }
        .controlSize(.small)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("Reading the menu bar…")
                .font(.callout)
                .foregroundStyle(.secondary)
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
            Text("No manageable items found.")
                .font(.headline)
            Text("Only third-party menu bar items can be hidden. System items (Control Center, the clock, Spotlight) are left alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row in the Items list: glyph, editable name, and a Shown/Hidden toggle. Toggling moves the
/// real item across the anchor (via the engine's reconcile, fired by the preferences change).
private struct ItemRow: View {
    @Bindable var model: SettingsModel
    let item: FloatingBarItem
    /// Called after the user flips Shown/Hidden, so the parent can re-partition the list and the
    /// row visibly moves between the "Hidden" and "Shown" sections.
    var onToggle: () -> Void = {}
    @State private var alias: String = ""
    @State private var hidden: Bool = false
    @FocusState private var aliasFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .opacity(hidden ? 0.5 : 1)

            TextField(item.displayName, text: $alias)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focused($aliasFocused)
                // Commit the nickname on Return or when the field loses focus — NOT on every
                // keystroke. setAlias mutates preferences, which fires the app-wide onChange
                // (persist + re-apply); doing that per character would thrash the disk.
                .onSubmit { model.setAlias(alias, for: item) }
                .onChange(of: aliasFocused) { _, focused in
                    if !focused { model.setAlias(alias, for: item) }
                }

            Spacer(minLength: 8)

            Picker("", selection: $hidden) {
                Text("Shown").tag(false)
                Text("Hidden").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 4)
        .onAppear {
            alias = model.alias(for: item)
            hidden = model.isHidden(item)
        }
        .onChange(of: hidden) { _, newValue in
            model.setHidden(newValue, for: item)
            onToggle()
        }
    }
}

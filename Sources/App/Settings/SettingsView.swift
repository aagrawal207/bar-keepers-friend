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
                LabeledContent("Tip") {
                    Text("Click the menu bar anchor to reveal hidden items. Right-click it to open settings.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if loading {
                loadingState
            } else if items.isEmpty {
                emptyState
            } else {
                List(items) { item in
                    ItemRow(model: model, item: item)
                }
                .listStyle(.inset)
            }
        }
        .padding(.top, 8)
        .task { await reload() }
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
            Text("Choose which menu bar items to hide.")
                .font(.callout)
            Text("Hidden items move into Bar Keeper's Friend's bar — click the menu bar icon (or press the shortcut) to reveal them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
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
        }
    }
}

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
                Toggle("Show section dividers", isOn: $model.preferences.showSectionDividers)
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

            Section("Reveal on hover") {
                Toggle("Reveal when hovering the anchor", isOn: $model.preferences.hoverToReveal)
                if model.preferences.hoverToReveal {
                    LabeledContent("Hover delay") {
                        Stepper(
                            value: $model.preferences.hoverRevealDelay,
                            in: 0.05...2,
                            step: 0.05
                        ) {
                            Text(String(format: "%.2fs", model.preferences.hoverRevealDelay))
                        }
                    }
                }
            }

            Section("Shortcuts") {
                Toggle("Toggle the bar with a global shortcut", isOn: $model.preferences.enableGlobalHotkey)
                if model.preferences.enableGlobalHotkey {
                    LabeledContent("Toggle bar") {
                        Text(HotkeyCarbon.displayString(for: model.preferences.toggleHotkey))
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Enable the search panel", isOn: $model.preferences.enableSearch)
                if model.preferences.enableSearch {
                    LabeledContent("Search") {
                        Text(HotkeyCarbon.displayString(for: model.preferences.searchHotkey))
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

/// Per-item manager. Lists the items currently hidden (mirrored into the bar), letting the user
/// set each one's bar visibility ("show in bar" vs "search only"), a search alias, and order.
///
/// Honesty is the whole point of this tab's framing: macOS — not us — owns whether an item is
/// *visible or hidden in the real menu bar* (we never move other apps' items). So there is NO
/// control here that claims to hide/show an item in the system bar; the header says plainly that
/// the user changes that by ⌘-dragging across the anchor. What this tab DOES control is our own
/// floating bar and search, which is genuinely ours.
private struct ItemsSettingsTab: View {
    @Bindable var model: SettingsModel
    /// Local working copy of the listed items, so drag-to-reorder has stable identities and the
    /// list doesn't thrash as the live provider changes underneath it. Refreshed on appear.
    @State private var items: [FloatingBarItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(items) { item in
                        ItemRow(model: model, item: item)
                    }
                    .onMove { indices, newOffset in
                        items.move(fromOffsets: indices, toOffset: newOffset)
                        model.reorderBarItems(items)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(.top, 8)
        .onAppear {
            // Pick up items added since the last capture (no-op while the bar is in use), then
            // read the current set. A short hop lets a triggered refresh land first.
            model.refreshItemList()
            items = model.items()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("These settings control Bar Keeper's Friend's own floating bar and search.")
                .font(.callout)
            Text("macOS decides whether an item is visible or hidden in the real menu bar — hold ⌘ and drag an icon across the anchor to change that.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "menubar.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No hidden items yet.")
                .font(.headline)
            Text("Hold ⌘ and drag menu bar icons to the left of the anchor to hide them here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row in the Items list: glyph, name, a read-only "in hidden bar" badge, the show-in-bar
/// toggle, and an expandable alias field.
private struct ItemRow: View {
    @Bindable var model: SettingsModel
    let item: FloatingBarItem
    @State private var alias: String = ""
    @State private var showsInBar: Bool = true
    @FocusState private var aliasFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: item.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .opacity(showsInBar ? 1 : 0.4)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .lineLimit(1)
                    Text(showsInBar ? "In hidden bar" : "Search only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle("Show in bar", isOn: $showsInBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.isControllable(item))
                    .help(model.isControllable(item)
                        ? "Show this item in the floating bar (off = findable in search only)"
                        : "This item has no stable identity, so it can't be managed")
            }

            if model.isControllable(item) {
                TextField("Search name (alias)", text: $alias)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($aliasFocused)
                    // Commit on Return or when the field loses focus — NOT on every keystroke.
                    // setAlias mutates preferences, which fires the app-wide onChange (persist +
                    // re-apply hotkeys/hover); doing that per character would thrash the disk and
                    // re-register Carbon hotkeys on each letter.
                    .onSubmit { model.setAlias(alias, for: item) }
                    .onChange(of: aliasFocused) { _, focused in
                        if !focused { model.setAlias(alias, for: item) }
                    }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            alias = model.alias(for: item)
            showsInBar = model.showsInBar(item)
        }
        .onChange(of: showsInBar) { _, newValue in
            model.setShowsInBar(newValue, for: item)
        }
    }
}

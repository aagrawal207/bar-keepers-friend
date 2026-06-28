import BarKeepersFriendCore
import SwiftUI

/// The settings UI. Phase 1 exposes only what the cosmetic engine actually supports;
/// Pro-layer toggles (permissions, search, overflow bar) are added as those phases land.
struct SettingsView: View {
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
        .frame(width: 440, height: 560)
    }
}

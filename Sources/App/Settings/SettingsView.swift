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

            Section("Hidden section") {
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

            Section {
                LabeledContent("Tip") {
                    Text("Click the menu bar anchor to reveal hidden items. Right-click it to open settings.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
    }
}

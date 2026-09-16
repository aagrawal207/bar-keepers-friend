import BarKeepersFriendCore
import SwiftUI

struct AdvancedSettingsTab: View {
    @Bindable var model: SettingsModel
    let navigate: (SettingsView.Tab) -> Void

    var body: some View {
        Form {
            Section("Optional tools") {
                HStack(spacing: 10) {
                    ForEach(SettingsView.Tab.advancedTabs) { tab in
                        Button { navigate(tab) } label: {
                            Label(tab.title, systemImage: tab.systemImage)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .accessibilityIdentifier("settings-advanced-\(tab.rawValue)")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-advanced-tools")
                .settingsSearchTarget(.advancedTools)
                Text("Save layouts, automate changes, or collect related icons into groups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SpacingSettingsSection(model: model, needsLogout: model.spacingNeedsLogout)
            NotchSettingsSection(model: model, mode: $model.preferences.notchOverflow)
            BackupSettingsSection(model: model)
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-advanced-content")
        // The notch warning must follow permission changes even when General has never been opened.
        .onAppear { model.refreshPermissions() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                model.refreshPermissions()
            }
        }
    }
}

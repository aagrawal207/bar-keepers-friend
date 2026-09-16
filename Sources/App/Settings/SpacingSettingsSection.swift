import BarKeepersFriendCore
import SwiftUI

/// Custom spacing is system-wide and takes effect per app at relaunch.
struct SpacingSettingsSection: View {
    @Bindable var model: SettingsModel
    var needsLogout: Bool

    private var spacing: MenuBarSpacing { model.preferences.menuBarSpacing }

    var body: some View {
        Section("Menu bar spacing") {
            HStack {
                Toggle("Reduce menu bar item spacing", isOn: $model.preferences.menuBarSpacing.enabled)
                    .accessibilityIdentifier("settings-spacing-enabled")
                    .settingsSearchTarget(.spacing)
                Spacer(minLength: 12)
                if spacing.enabled {
                    Button("Reset to system default") { model.preferences.menuBarSpacing = .systemDefault }
                        .help("Turns custom spacing off and restores the system values (\(MenuBarSpacing.systemDefault.spacing) pt).")
                        .accessibilityIdentifier("settings-spacing-reset")
                }
            }

            if spacing.enabled {
                HStack(spacing: 20) {
                    LabeledContent("Spacing") {
                        Stepper(value: $model.preferences.menuBarSpacing.spacing, in: MenuBarSpacing.validRange) {
                            Text("\(spacing.spacing) pt")
                                .monospacedDigit()
                        }
                        .fixedSize()
                        .accessibilityIdentifier("settings-spacing-spacing")
                    }
                    LabeledContent("Selection padding") {
                        Stepper(value: $model.preferences.menuBarSpacing.selectionPadding, in: MenuBarSpacing.validRange) {
                            Text("\(spacing.selectionPadding) pt")
                                .monospacedDigit()
                        }
                        .fixedSize()
                        .accessibilityIdentifier("settings-spacing-padding")
                    }
                }
            }

            Text("System-wide: all apps share these values.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-spacing-shared-note")

            if needsLogout {
                Label(
                    "Relaunch menu bar apps or log out to see the change.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-spacing-logout-note")
            }
        }
    }
}

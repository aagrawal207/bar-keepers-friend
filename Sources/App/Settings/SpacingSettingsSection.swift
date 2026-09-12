import BarKeepersFriendCore
import SwiftUI

/// General-tab section for system-wide status item spacing. Edits go straight to `model.preferences`;
/// the coordinator writes the global domain and passes back whether a relaunch is still pending.
struct SpacingSettingsSection: View {
    @Bindable var model: SettingsModel
    var needsLogout: Bool

    private var spacing: MenuBarSpacing { model.preferences.menuBarSpacing }

    var body: some View {
        Section("Menu bar spacing") {
            Toggle("Reduce menu bar item spacing", isOn: $model.preferences.menuBarSpacing.enabled)
                .accessibilityIdentifier("settings-spacing-enabled")

            if spacing.enabled {
                LabeledContent("Spacing") {
                    Stepper(value: $model.preferences.menuBarSpacing.spacing, in: MenuBarSpacing.validRange) {
                        Text("\(spacing.spacing) pt")
                            .monospacedDigit()
                    }
                    .accessibilityIdentifier("settings-spacing-spacing")
                }
                LabeledContent("Selection padding") {
                    Stepper(value: $model.preferences.menuBarSpacing.selectionPadding, in: MenuBarSpacing.validRange) {
                        Text("\(spacing.selectionPadding) pt")
                            .monospacedDigit()
                    }
                    .accessibilityIdentifier("settings-spacing-padding")
                }
                // The system default is "no custom spacing", so a reset also turns the toggle off.
                Button("Reset to system default") { model.preferences.menuBarSpacing = .systemDefault }
                    .help("Turns custom spacing off and restores the system values (\(MenuBarSpacing.systemDefault.spacing) pt).")
                    .accessibilityIdentifier("settings-spacing-reset")
            }

            Text("This is a system-wide setting shared by all apps, not just this one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-spacing-shared-note")

            if needsLogout {
                Label(
                    "Takes effect for each app after it relaunches, or after you log out and back in.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-spacing-logout-note")
            }
        }
    }
}

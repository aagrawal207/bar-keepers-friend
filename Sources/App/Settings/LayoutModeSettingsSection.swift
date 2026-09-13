import BarKeepersFriendCore
import SwiftUI

/// General-tab section choosing when saved placement is re-applied. Each choice writes preferences
/// once through the model; enabling Live needs Accessibility, which the note below points out.
struct LayoutModeSettingsSection: View {
    @Bindable var model: SettingsModel

    private var accessibilityGranted: Bool { model.status(of: .accessibility) == .granted }

    /// Re-selecting the current radio must not re-persist and re-apply an unchanged mode.
    private var layoutMode: Binding<LayoutMode> {
        Binding(
            get: { model.preferences.layoutMode },
            set: { mode in
                guard mode != model.preferences.layoutMode else { return }
                model.preferences.layoutMode = mode
            }
        )
    }

    var body: some View {
        Section("Placement") {
            Picker("Layout mode", selection: layoutMode) {
                Text("On-Demand").tag(LayoutMode.onDemand)
                Text("Live").tag(LayoutMode.live)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings-layout-mode-picker")

            Text("On-Demand applies your saved Shown/Hidden placement at launch, when you Apply Changes, and when displays change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-layout-mode-on-demand-description")
            Text("Live also re-applies it after apps launch or quit. It waits for the pointer to be idle and may briefly move the pointer while placing items.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-layout-mode-live-description")

            if model.preferences.layoutMode == .live, !accessibilityGranted {
                Label(
                    "Live mode needs Accessibility to move items. Grant it in the Permissions section.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-layout-mode-accessibility-note")
            }
        }
    }
}

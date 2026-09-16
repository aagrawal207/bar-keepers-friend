import BarKeepersFriendCore
import SwiftUI

/// Re-selecting the current mode must not persist or re-apply an unchanged preference.
struct NotchSettingsSection: View {
    @Bindable var model: SettingsModel
    var mode: Binding<NotchOverflowMode>

    private var accessibilityGranted: Bool { model.status(of: .accessibility) == .granted }

    private var selection: Binding<NotchOverflowMode> {
        Binding(
            get: { mode.wrappedValue },
            set: { chosen in
                guard chosen != mode.wrappedValue else { return }
                mode.wrappedValue = chosen
            }
        )
    }

    var body: some View {
        Section {
            Picker("Make room near the notch", selection: selection) {
                Text("Never").tag(NotchOverflowMode.never)
                Text("When needed").tag(NotchOverflowMode.whenNeeded)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings-notch-picker")
            .settingsSearchTarget(.notchMakeRoom)

            Text("When a notch would clip revealed menu bar items, temporarily tuck nearby shown icons and restore them when the section hides. Requires Accessibility and may briefly move the pointer. No effect on displays without a notch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-notch-description")

            if mode.wrappedValue == .whenNeeded, !accessibilityGranted {
                Label(
                    "Grant Accessibility in General → Permissions to move items.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-notch-accessibility-note")
            }
        } header: {
            SettingsSearchSectionHeading(target: .notch, id: "settings-notch-heading")
        }
    }
}

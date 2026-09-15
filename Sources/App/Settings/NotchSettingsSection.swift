import BarKeepersFriendCore
import SwiftUI

/// Behavior-tab section for the `notchOverflow` preference, passed as `mode`. Each choice writes the
/// binding once (one persisted preference), and re-selecting the current radio writes nothing.
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
        Section("Notch") {
            Picker("Make room near the notch", selection: selection) {
                Text("Never").tag(NotchOverflowMode.never)
                Text("When needed").tag(NotchOverflowMode.whenNeeded)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings-notch-picker")

            Text("When hidden items are revealed in the menu bar itself (floating bar off, or while activating an item) and the notch would clip them, the shown items closest to the anchor are tucked away, then put back when the section hides. Moves items, so it needs Accessibility and may briefly move the pointer. Has no effect on displays without a notch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-notch-description")

            if mode.wrappedValue == .whenNeeded, !accessibilityGranted {
                Label(
                    "Making room needs Accessibility to move items. Grant it in the Permissions section.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-notch-accessibility-note")
            }
        }
    }
}

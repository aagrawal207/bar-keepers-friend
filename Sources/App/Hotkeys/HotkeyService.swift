import AppKit
import BarKeepersFriendCore
import Carbon.HIToolbox

/// Registers global keyboard shortcuts using Carbon's `RegisterEventHotKey`. This API delivers
/// hotkeys system-wide without needing Accessibility permission (unlike a CGEventTap), which
/// matters because the floating bar's whole point is to work with minimal permissions.
///
/// AGENT: implement registration here. The public surface below is fixed — the coordinator
/// wires `onToggle` / `onSearch` and calls `apply(preferences:)`. Do not change the signatures.
@MainActor
final class HotkeyService {
    /// Invoked on the main actor when the toggle-bar hotkey fires.
    var onToggle: (() -> Void)?
    /// Invoked on the main actor when the search hotkey fires.
    var onSearch: (() -> Void)?

    /// Registers/updates the global hotkeys to match the given preferences. Unregisters all when
    /// `enableGlobalHotkey`/`enableSearch` are off or the combos are invalid. Safe to call
    /// repeatedly (e.g. after a settings change) — it tears down and rebuilds as needed.
    func apply(preferences: Preferences) {
        // AGENT: register kept combos via RegisterEventHotKey + InstallEventHandler, route the
        // matching hotkey id to onToggle/onSearch. Track registered EventHotKeyRefs so this can
        // unregister cleanly on the next apply and on teardown.
    }

    /// Unregisters every hotkey. Called on teardown.
    func teardown() {
        // AGENT: UnregisterEventHotKey for each registered ref; remove the event handler.
    }
}

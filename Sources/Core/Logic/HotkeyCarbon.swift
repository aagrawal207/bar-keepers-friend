import Foundation

/// Pure helpers for translating a `HotkeyCombo`'s device-independent modifier flags into the
/// Carbon modifier mask that `RegisterEventHotKey` expects. Kept in Core, free of Carbon and
/// AppKit imports, so the mapping is unit-testable without a window server or event loop.
///
/// Carbon modifier constants (from `<Carbon/Carbon.h>`), reproduced here as plain values so
/// Core needn't import Carbon:
///   cmdKey = 0x0100, shiftKey = 0x0200, optionKey = 0x0800, controlKey = 0x1000.
public enum HotkeyCarbon {
    public static let cmdKey: UInt32 = 0x0100
    public static let shiftKey: UInt32 = 0x0200
    public static let optionKey: UInt32 = 0x0800
    public static let controlKey: UInt32 = 0x1000

    /// Converts a combo's `NSEvent.ModifierFlags`-style raw value into a Carbon modifier mask.
    public static func carbonModifiers(from combo: HotkeyCombo) -> UInt32 {
        var mask: UInt32 = 0
        if combo.modifiers & HotkeyCombo.command != 0 { mask |= cmdKey }
        if combo.modifiers & HotkeyCombo.shift != 0 { mask |= shiftKey }
        if combo.modifiers & HotkeyCombo.option != 0 { mask |= optionKey }
        if combo.modifiers & HotkeyCombo.control != 0 { mask |= controlKey }
        return mask
    }

    /// A short human-readable description of a combo, e.g. "⌥⌘B", for display in settings.
    /// Returns "Unset" for an invalid combo.
    public static func displayString(for combo: HotkeyCombo) -> String {
        guard combo.isValid else { return "Unset" }
        var symbols = ""
        if combo.modifiers & HotkeyCombo.control != 0 { symbols += "⌃" }
        if combo.modifiers & HotkeyCombo.option != 0 { symbols += "⌥" }
        if combo.modifiers & HotkeyCombo.shift != 0 { symbols += "⇧" }
        if combo.modifiers & HotkeyCombo.command != 0 { symbols += "⌘" }
        return symbols + (keyName(for: combo.keyCode) ?? "?")
    }

    /// Maps a virtual key code (`kVK_*`) to a display label for the common keys we expect a
    /// user to choose. Unknown codes return `nil` so the caller can show a placeholder.
    public static func keyName(for keyCode: Int) -> String? {
        keyNames[keyCode]
    }

    /// Letter, digit, and a few named keys — enough to render the defaults and typical choices.
    private static let keyNames: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
    ]
}

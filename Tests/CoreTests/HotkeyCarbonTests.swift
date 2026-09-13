import Testing
@testable import BarKeepersFriendCore

/// Unit tests for `HotkeyCarbon`, the pure (Carbon- and AppKit-free) mapping helper. The
/// `HotkeyService` itself needs a live event loop and the window server, so it isn't unit-tested
/// here — only this deterministic translation layer, which is where the easy-to-get-wrong bit
/// arithmetic lives.
@Suite struct HotkeyCarbonTests {

    // MARK: - carbonModifiers

    @Test func eachModifierMapsToItsCarbonMask() {
        #expect(HotkeyCarbon.carbonModifiers(from: combo(HotkeyCombo.command)) == HotkeyCarbon.cmdKey)
        #expect(HotkeyCarbon.carbonModifiers(from: combo(HotkeyCombo.option)) == HotkeyCarbon.optionKey)
        #expect(HotkeyCarbon.carbonModifiers(from: combo(HotkeyCombo.shift)) == HotkeyCarbon.shiftKey)
        #expect(HotkeyCarbon.carbonModifiers(from: combo(HotkeyCombo.control)) == HotkeyCarbon.controlKey)
    }

    @Test func combinedModifiersOrTogether() {
        // defaultToggle is ⌥⌘B, so its Carbon mask is cmdKey | optionKey.
        #expect(HotkeyCarbon.carbonModifiers(from: .defaultToggle) == (HotkeyCarbon.cmdKey | HotkeyCarbon.optionKey))

        let all = HotkeyCombo(
            keyCode: 11,
            modifiers: HotkeyCombo.command | HotkeyCombo.shift | HotkeyCombo.option | HotkeyCombo.control
        )
        let expected = HotkeyCarbon.cmdKey | HotkeyCarbon.shiftKey | HotkeyCarbon.optionKey | HotkeyCarbon.controlKey
        #expect(HotkeyCarbon.carbonModifiers(from: all) == expected)
    }

    @Test func noModifiersMapToZero() {
        #expect(HotkeyCarbon.carbonModifiers(from: HotkeyCombo(keyCode: 11, modifiers: 0)) == 0)
    }

    // MARK: - displayString

    @Test func displayStringForDefaults() {
        #expect(HotkeyCarbon.displayString(for: .defaultToggle) == "⌥⌘B")
    }

    @Test func displayStringForInvalidComboIsUnset() {
        // Invalid because there are no modifiers.
        #expect(HotkeyCarbon.displayString(for: HotkeyCombo(keyCode: 11, modifiers: 0)) == "Unset")
    }

    @Test func displayStringOrdersModifiersControlOptionShiftCommand() {
        let combo = HotkeyCombo(
            keyCode: 1, // "S"
            modifiers: HotkeyCombo.command | HotkeyCombo.shift | HotkeyCombo.option | HotkeyCombo.control
        )
        #expect(HotkeyCarbon.displayString(for: combo) == "⌃⌥⇧⌘S")
    }

    // MARK: - keyName

    @Test func keyNameForKnownCodes() {
        #expect(HotkeyCarbon.keyName(for: 11) == "B")
        #expect(HotkeyCarbon.keyName(for: 3) == "F")
    }

    @Test func keyNameForUnmappedCodeIsNil() {
        // 999 is not in the table of supported keys.
        #expect(HotkeyCarbon.keyName(for: 999) == nil)
    }

    @Test func keyNamesCoverArrowsFunctionKeysPunctuationAndNavigation() {
        #expect(HotkeyCarbon.keyName(for: 123) == "←")
        #expect(HotkeyCarbon.keyName(for: 124) == "→")
        #expect(HotkeyCarbon.keyName(for: 125) == "↓")
        #expect(HotkeyCarbon.keyName(for: 126) == "↑")
        #expect(HotkeyCarbon.keyName(for: 98) == "F7")
        #expect(HotkeyCarbon.keyName(for: 100) == "F8")
        #expect(HotkeyCarbon.keyName(for: 101) == "F9")
        #expect(HotkeyCarbon.keyName(for: 109) == "F10")
        #expect(HotkeyCarbon.keyName(for: 103) == "F11")
        #expect(HotkeyCarbon.keyName(for: 111) == "F12")
        #expect(HotkeyCarbon.keyName(for: 105) == "F13")
        #expect(HotkeyCarbon.keyName(for: 90) == "F20")
        #expect(HotkeyCarbon.keyName(for: 27) == "-")
        #expect(HotkeyCarbon.keyName(for: 24) == "=")
        #expect(HotkeyCarbon.keyName(for: 33) == "[")
        #expect(HotkeyCarbon.keyName(for: 30) == "]")
        #expect(HotkeyCarbon.keyName(for: 42) == "\\")
        #expect(HotkeyCarbon.keyName(for: 41) == ";")
        #expect(HotkeyCarbon.keyName(for: 39) == "'")
        #expect(HotkeyCarbon.keyName(for: 43) == ",")
        #expect(HotkeyCarbon.keyName(for: 47) == ".")
        #expect(HotkeyCarbon.keyName(for: 44) == "/")
        #expect(HotkeyCarbon.keyName(for: 50) == "`")
        #expect(HotkeyCarbon.keyName(for: 51) == "⌫")
        #expect(HotkeyCarbon.keyName(for: 117) == "⌦")
        #expect(HotkeyCarbon.keyName(for: 115) == "Home")
        #expect(HotkeyCarbon.keyName(for: 119) == "End")
        #expect(HotkeyCarbon.keyName(for: 116) == "Page Up")
        #expect(HotkeyCarbon.keyName(for: 121) == "Page Down")
        // Keypad keys stay unnamed so the recorder refuses them instead of displaying "?".
        #expect(HotkeyCarbon.keyName(for: 82) == nil)
    }

    @Test func keyNamesAreUniquePerCode() {
        // Every named code must render distinctly, or two shortcuts would read as the same one.
        let codes = (0...127).compactMap { code in HotkeyCarbon.keyName(for: code).map { (code, $0) } }
        #expect(Set(codes.map(\.1)).count == codes.count)
        #expect(codes.count >= 80)
    }

    @Test func displayStringForNewlyNamedKeys() {
        #expect(HotkeyCarbon.displayString(for: HotkeyCombo(keyCode: 126, modifiers: HotkeyCombo.control | HotkeyCombo.option)) == "⌃⌥↑")
        #expect(HotkeyCarbon.displayString(for: HotkeyCombo(keyCode: 111, modifiers: HotkeyCombo.command)) == "⌘F12")
        #expect(HotkeyCarbon.displayString(for: HotkeyCombo(keyCode: 44, modifiers: HotkeyCombo.command | HotkeyCombo.shift)) == "⇧⌘/")
    }

    // MARK: - modifierSymbols

    @Test func modifierSymbolsMatchDisplayStringOrderAndIgnoreOtherFlags() {
        let all = HotkeyCombo.control | HotkeyCombo.option | HotkeyCombo.shift | HotkeyCombo.command
        #expect(HotkeyCarbon.modifierSymbols(for: all) == "⌃⌥⇧⌘")
        #expect(HotkeyCarbon.modifierSymbols(for: HotkeyCombo.command | HotkeyCombo.option) == "⌥⌘")
        #expect(HotkeyCarbon.modifierSymbols(for: 0) == "")
        // fn / numeric-pad bits render nothing.
        #expect(HotkeyCarbon.modifierSymbols(for: (1 << 23) | (1 << 21)) == "")
    }

    // MARK: - HotkeyCombo.isValid

    @Test func validComboHasKeyAndModifier() {
        #expect(HotkeyCombo.defaultToggle.isValid)
        #expect(HotkeyCombo(keyCode: 0, modifiers: HotkeyCombo.command).isValid)
    }

    @Test func comboWithoutModifierIsInvalid() {
        #expect(!HotkeyCombo(keyCode: 11, modifiers: 0).isValid)
    }

    @Test func negativeKeyCodeIsInvalid() {
        #expect(!HotkeyCombo(keyCode: -1, modifiers: HotkeyCombo.command).isValid)
    }

    @Test func outOfRangeKeyCodeIsInvalidNotFatal() {
        // A virtual key code is 16-bit, and the Carbon registration does a TRAPPING UInt32(keyCode)
        // at startup. A corrupt/hostile persisted or imported keyCode beyond 0xFFFF must be treated
        // as "unset" (so registration skips it) rather than crashing the app on every launch.
        #expect(!HotkeyCombo(keyCode: 0x1_0000, modifiers: HotkeyCombo.command).isValid)
        #expect(!HotkeyCombo(keyCode: Int.max, modifiers: HotkeyCombo.command).isValid)
        #expect(HotkeyCombo(keyCode: 0xFFFF, modifiers: HotkeyCombo.command).isValid) // top valid
    }

    // MARK: - Helpers

    /// A valid combo using `keyCode` 11 ("B") and a single device-independent modifier flag.
    private func combo(_ modifier: UInt) -> HotkeyCombo {
        HotkeyCombo(keyCode: 11, modifiers: modifier)
    }
}

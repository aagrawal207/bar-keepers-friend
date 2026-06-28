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

    // MARK: - Helpers

    /// A valid combo using `keyCode` 11 ("B") and a single device-independent modifier flag.
    private func combo(_ modifier: UInt) -> HotkeyCombo {
        HotkeyCombo(keyCode: 11, modifiers: modifier)
    }
}

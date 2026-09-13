import Foundation

/// Pure rules for which shortcuts the app may claim and how the toggle-bar and per-item
/// shortcuts share one keyboard. The recorder UI and `HotkeyService` both consult these, so a
/// combo the recorder rejects can never be registered and a registered combo always displays.
public enum HotkeyAssignments {
    /// Why a combo cannot be assigned as requested.
    public enum Conflict: Equatable, Hashable, Sendable {
        /// macOS handles the combo before any app sees it, or claiming it would break every app.
        case systemReserved
        /// The combo is the toggle-bar shortcut.
        case toggleBar
        /// Another item already uses the combo.
        case item(ownerKey: String)
    }

    /// Carbon hotkey slots are cheap, but each live shortcut is one more key the user cannot
    /// type into other apps; 32 is far beyond any real menu bar.
    public static let maxItemHotkeys = 32

    /// The four device-independent flags a shortcut may carry; everything else (fn, numeric
    /// pad, caps lock, device-specific bits) is stripped before comparison or storage.
    public static let modifierMask: UInt =
        HotkeyCombo.command | HotkeyCombo.option | HotkeyCombo.control | HotkeyCombo.shift

    /// Shift alone would capture plain capital letters system-wide, so a shortcut needs one of these.
    public static let primaryModifierMask: UInt = HotkeyCombo.command | HotkeyCombo.option | HotkeyCombo.control

    /// Cmd-Q, Cmd-W, Cmd-Tab, Cmd-Space, Cmd-H, Cmd-M, Cmd-`, Option-Cmd-Esc, Control-Cmd-Q.
    public static let reservedSystemCombos: Set<HotkeyCombo> = [
        HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.command),
        HotkeyCombo(keyCode: 13, modifiers: HotkeyCombo.command),
        HotkeyCombo(keyCode: 48, modifiers: HotkeyCombo.command),
        HotkeyCombo(keyCode: 49, modifiers: HotkeyCombo.command),
        HotkeyCombo(keyCode: 4, modifiers: HotkeyCombo.command),
        HotkeyCombo(keyCode: 46, modifiers: HotkeyCombo.command),
        HotkeyCombo(keyCode: 50, modifiers: HotkeyCombo.command),
        HotkeyCombo(keyCode: 53, modifiers: HotkeyCombo.command | HotkeyCombo.option),
        HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.command | HotkeyCombo.control),
    ]

    /// Strips flags that are not part of a shortcut's identity (see `modifierMask`).
    public static func normalizedModifiers(_ raw: UInt) -> UInt {
        raw & modifierMask
    }

    public static func isSystemReserved(_ combo: HotkeyCombo) -> Bool {
        reservedSystemCombos.contains(normalized(combo))
    }

    /// Valid, carries Command/Option/Control, and is not owned by macOS.
    public static func isAssignable(_ combo: HotkeyCombo) -> Bool {
        combo.isValid
            && combo.modifiers & primaryModifierMask != 0
            && !isSystemReserved(combo)
    }

    /// The first reason `combo` cannot be assigned, or `nil` when it is free. `toggle` is the
    /// combo reserved for toggling the bar (pass `nil` when recording the toggle itself), and
    /// `excludingOwner` is the item being edited, so re-recording its own combo is not a clash.
    public static func conflict(
        for combo: HotkeyCombo,
        toggle: HotkeyCombo?,
        itemHotkeys: [String: HotkeyCombo],
        excludingOwner: String? = nil
    ) -> Conflict? {
        let combo = normalized(combo)
        if isSystemReserved(combo) { return .systemReserved }
        if let toggle, normalized(toggle) == combo { return .toggleBar }
        // Sorted so a combo shared by several owners (possible via import) reports one deterministic name.
        let owners = itemHotkeys
            .filter { $0.key != excludingOwner && normalized($0.value) == combo }
            .keys.sorted()
        if let owner = owners.first { return .item(ownerKey: owner) }
        return nil
    }

    // MARK: - Registration plan

    /// Which saved item shortcuts go live and, for the rest, why not. Shared by the service
    /// (which registers exactly `items`, in order) and Settings (which annotates skipped rows).
    public struct Plan: Equatable, Sendable {
        public struct Entry: Equatable, Sendable {
            public let ownerKey: String
            public let combo: HotkeyCombo

            public init(ownerKey: String, combo: HotkeyCombo) {
                self.ownerKey = ownerKey
                self.combo = combo
            }
        }

        public enum SkipReason: Equatable, Sendable {
            /// Invalid or missing a primary modifier, e.g. from a hand-edited layout file.
            case notAssignable
            case conflict(Conflict)
            case overCapacity
            /// Item activation goes through the floating bar's icon cache, which reflow mode never fills.
            case requiresFloatingBar
        }

        /// Registration order: sorted by owner key so slot indices are stable across launches.
        public let items: [Entry]
        public let skipped: [String: SkipReason]

        public init(items: [Entry], skipped: [String: SkipReason]) {
            self.items = items
            self.skipped = skipped
        }

        public var isEmpty: Bool { items.isEmpty && skipped.isEmpty }
    }

    /// The live toggle (nil when off or unassignable) wins any clash; among items sharing a combo the
    /// first owner by key wins. Without the floating bar every item is skipped: nothing could resolve it.
    public static func plan(
        registeredToggle: HotkeyCombo?,
        itemHotkeys: [String: HotkeyCombo],
        capacity: Int = maxItemHotkeys,
        floatingBarEnabled: Bool = true
    ) -> Plan {
        var items: [Plan.Entry] = []
        var skipped: [String: Plan.SkipReason] = [:]
        var claimed: [HotkeyCombo: String] = [:]
        let toggle = registeredToggle.map(normalized)
        for (owner, raw) in itemHotkeys.sorted(by: { $0.key < $1.key }) {
            let combo = normalized(raw)
            if !floatingBarEnabled {
                skipped[owner] = .requiresFloatingBar
            } else if isSystemReserved(combo) {
                skipped[owner] = .conflict(.systemReserved)
            } else if !isAssignable(combo) {
                skipped[owner] = .notAssignable
            } else if combo == toggle {
                skipped[owner] = .conflict(.toggleBar)
            } else if let first = claimed[combo] {
                skipped[owner] = .conflict(.item(ownerKey: first))
            } else if items.count >= capacity {
                skipped[owner] = .overCapacity
            } else {
                claimed[combo] = owner
                items.append(Plan.Entry(ownerKey: owner, combo: combo))
            }
        }
        return Plan(items: items, skipped: skipped)
    }

    private static func normalized(_ combo: HotkeyCombo) -> HotkeyCombo {
        HotkeyCombo(keyCode: combo.keyCode, modifiers: normalizedModifiers(combo.modifiers))
    }
}

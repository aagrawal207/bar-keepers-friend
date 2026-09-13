import Testing
@testable import BarKeepersFriendCore

/// The shared assignment rules: the recorder rejects exactly what the service would refuse to
/// register, so these pin both the conflict detection and the registration plan.
@Suite struct HotkeyAssignmentsTests {
    private let cmd = HotkeyCombo.command
    private let opt = HotkeyCombo.option
    private let ctrl = HotkeyCombo.control
    private let shift = HotkeyCombo.shift

    private func combo(_ keyCode: Int, _ modifiers: UInt) -> HotkeyCombo {
        HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    // MARK: - System reserved

    @Test(arguments: [
        HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.command),                          // Cmd-Q
        HotkeyCombo(keyCode: 13, modifiers: HotkeyCombo.command),                          // Cmd-W
        HotkeyCombo(keyCode: 48, modifiers: HotkeyCombo.command),                          // Cmd-Tab
        HotkeyCombo(keyCode: 49, modifiers: HotkeyCombo.command),                          // Cmd-Space
        HotkeyCombo(keyCode: 4, modifiers: HotkeyCombo.command),                           // Cmd-H
        HotkeyCombo(keyCode: 46, modifiers: HotkeyCombo.command),                          // Cmd-M
        HotkeyCombo(keyCode: 50, modifiers: HotkeyCombo.command),                          // Cmd-`
        HotkeyCombo(keyCode: 53, modifiers: HotkeyCombo.command | HotkeyCombo.option),     // Option-Cmd-Esc
        HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.command | HotkeyCombo.control),    // Control-Cmd-Q
    ])
    func denylistedSystemCombosAreReservedAndNotAssignable(reserved: HotkeyCombo) {
        #expect(HotkeyAssignments.isSystemReserved(reserved))
        #expect(!HotkeyAssignments.isAssignable(reserved))
        #expect(HotkeyAssignments.conflict(for: reserved, toggle: nil, itemHotkeys: [:]) == .systemReserved)
        #expect(HotkeyAssignments.reservedSystemCombos.count == 9)
    }

    @Test func addingAModifierToAReservedComboFreesIt() {
        // Shift-Cmd-Q is not the logout/quit combo; Option-Cmd-Q is not Cmd-Q.
        #expect(!HotkeyAssignments.isSystemReserved(combo(12, cmd | shift)))
        #expect(!HotkeyAssignments.isSystemReserved(combo(12, cmd | opt)))
        #expect(HotkeyAssignments.isAssignable(combo(12, cmd | shift)))
    }

    @Test func reservedCheckIgnoresNonShortcutFlags() {
        // fn (1<<23) and numeric-pad (1<<21) bits ride along on real key events.
        let cmdQWithFn = combo(12, cmd | (1 << 23) | (1 << 21))
        #expect(HotkeyAssignments.isSystemReserved(cmdQWithFn))
        #expect(HotkeyAssignments.normalizedModifiers(cmd | (1 << 23) | (1 << 21)) == cmd)
        #expect(HotkeyAssignments.normalizedModifiers(cmd | opt | ctrl | shift | 0xFF) == cmd | opt | ctrl | shift)
    }

    // MARK: - isAssignable

    @Test func assignableNeedsAPrimaryModifier() {
        #expect(HotkeyAssignments.isAssignable(.defaultToggle))
        #expect(HotkeyAssignments.isAssignable(combo(11, cmd)))
        #expect(HotkeyAssignments.isAssignable(combo(11, opt)))
        #expect(HotkeyAssignments.isAssignable(combo(11, ctrl)))
        #expect(HotkeyAssignments.isAssignable(combo(11, shift | cmd)))
        // Shift alone is valid per HotkeyCombo but would swallow every capital B system-wide.
        #expect(HotkeyCombo(keyCode: 11, modifiers: shift).isValid)
        #expect(!HotkeyAssignments.isAssignable(combo(11, shift)))
        #expect(!HotkeyAssignments.isAssignable(combo(11, 0)))
        #expect(!HotkeyAssignments.isAssignable(combo(-1, cmd)))
        #expect(!HotkeyAssignments.isAssignable(combo(0x1_0000, cmd)))
    }

    // MARK: - conflict(for:)

    @Test func freeComboHasNoConflict() {
        let items = ["Maccy": combo(46, cmd | opt)]
        #expect(HotkeyAssignments.conflict(for: combo(11, ctrl | opt), toggle: .defaultToggle, itemHotkeys: items) == nil)
    }

    @Test func toggleComboConflictsUnlessRecordingTheToggleItself() {
        #expect(HotkeyAssignments.conflict(for: .defaultToggle, toggle: .defaultToggle, itemHotkeys: [:]) == .toggleBar)
        // Recording the toggle passes nil so its own current combo is not a clash.
        #expect(HotkeyAssignments.conflict(for: .defaultToggle, toggle: nil, itemHotkeys: [:]) == nil)
    }

    @Test func itemComboConflictsExceptForTheOwnerBeingEdited() {
        let items = ["Maccy": combo(46, cmd | opt), "Itsycal": combo(34, cmd | opt)]
        #expect(HotkeyAssignments.conflict(for: combo(46, cmd | opt), toggle: .defaultToggle, itemHotkeys: items) == .item(ownerKey: "Maccy"))
        #expect(HotkeyAssignments.conflict(for: combo(46, cmd | opt), toggle: .defaultToggle, itemHotkeys: items, excludingOwner: "Maccy") == nil)
        #expect(HotkeyAssignments.conflict(for: combo(46, cmd | opt), toggle: .defaultToggle, itemHotkeys: items, excludingOwner: "Itsycal") == .item(ownerKey: "Maccy"))
    }

    @Test func conflictPrecedenceIsSystemThenToggleThenItem() {
        let cmdQ = combo(12, cmd)
        #expect(HotkeyAssignments.conflict(for: cmdQ, toggle: cmdQ, itemHotkeys: ["A": cmdQ]) == .systemReserved)
        #expect(HotkeyAssignments.conflict(for: .defaultToggle, toggle: .defaultToggle, itemHotkeys: ["A": .defaultToggle]) == .toggleBar)
    }

    @Test func sharedItemComboReportsTheAlphabeticallyFirstOwner() {
        let shared = combo(46, cmd | opt)
        let items = ["Zed": shared, "Alpha": shared, "Mid": shared]
        #expect(HotkeyAssignments.conflict(for: shared, toggle: nil, itemHotkeys: items) == .item(ownerKey: "Alpha"))
        #expect(HotkeyAssignments.conflict(for: shared, toggle: nil, itemHotkeys: items, excludingOwner: "Alpha") == .item(ownerKey: "Mid"))
    }

    @Test func conflictComparesNormalizedModifiers() {
        // A stored combo carrying a stray fn bit still clashes with the clean version.
        let stored = combo(46, cmd | opt | (1 << 23))
        #expect(HotkeyAssignments.conflict(for: combo(46, cmd | opt), toggle: nil, itemHotkeys: ["Maccy": stored]) == .item(ownerKey: "Maccy"))
        #expect(HotkeyAssignments.conflict(for: stored, toggle: combo(46, cmd | opt), itemHotkeys: [:]) == .toggleBar)
    }

    // MARK: - plan

    @Test func planRegistersAssignableItemsInOwnerKeyOrder() {
        let items = ["Zed": combo(6, cmd | opt), "Alpha": combo(0, cmd | opt), "Mid": combo(46, cmd | opt)]
        let plan = HotkeyAssignments.plan(registeredToggle: .defaultToggle, itemHotkeys: items)
        #expect(plan.items.map(\.ownerKey) == ["Alpha", "Mid", "Zed"])
        #expect(plan.items.map(\.combo) == [combo(0, cmd | opt), combo(46, cmd | opt), combo(6, cmd | opt)])
        #expect(plan.skipped.isEmpty)
        #expect(!plan.isEmpty)
        #expect(HotkeyAssignments.plan(registeredToggle: nil, itemHotkeys: [:]).isEmpty)
    }

    @Test func planLetsTheToggleWinAndAllowsItsComboWhenTheToggleIsOff() {
        let items = ["Maccy": HotkeyCombo.defaultToggle]
        let on = HotkeyAssignments.plan(registeredToggle: .defaultToggle, itemHotkeys: items)
        #expect(on.items.isEmpty)
        #expect(on.skipped == ["Maccy": .conflict(.toggleBar)])
        let off = HotkeyAssignments.plan(registeredToggle: nil, itemHotkeys: items)
        #expect(off.items.map(\.ownerKey) == ["Maccy"])
        #expect(off.skipped.isEmpty)
    }

    @Test func planGivesASharedComboToTheFirstOwnerOnly() {
        let shared = combo(46, cmd | opt)
        let plan = HotkeyAssignments.plan(registeredToggle: nil, itemHotkeys: ["Zed": shared, "Alpha": shared])
        #expect(plan.items.map(\.ownerKey) == ["Alpha"])
        #expect(plan.skipped == ["Zed": .conflict(.item(ownerKey: "Alpha"))])
    }

    @Test func planSkipsReservedAndUnassignableCombos() {
        let items = [
            "Quit": combo(12, cmd),           // Cmd-Q: reserved
            "Caps": combo(11, shift),         // shift only
            "Bare": combo(11, 0),             // no modifiers
            "Huge": combo(0x1_0000, cmd),     // out of range
            "Good": combo(11, ctrl | opt),
        ]
        let plan = HotkeyAssignments.plan(registeredToggle: .defaultToggle, itemHotkeys: items)
        #expect(plan.items.map(\.ownerKey) == ["Good"])
        #expect(plan.skipped == [
            "Quit": .conflict(.systemReserved),
            "Caps": .notAssignable,
            "Bare": .notAssignable,
            "Huge": .notAssignable,
        ])
    }

    @Test func planStopsAtCapacityAndReportsTheOverflow() {
        // Distinct combos: Cmd-Option plus each letter/digit key code below 32 that is a real key.
        var items: [String: HotkeyCombo] = [:]
        for code in 0..<40 {
            items[String(format: "Owner%02d", code)] = combo(code, cmd | opt | ctrl)
        }
        let plan = HotkeyAssignments.plan(registeredToggle: nil, itemHotkeys: items)
        #expect(plan.items.count == HotkeyAssignments.maxItemHotkeys)
        #expect(HotkeyAssignments.maxItemHotkeys == 32)
        #expect(plan.items.first?.ownerKey == "Owner00")
        #expect(plan.items.last?.ownerKey == "Owner31")
        let overflow = plan.skipped.filter { $0.value == .overCapacity }.keys.sorted()
        #expect(overflow == (32..<40).map { String(format: "Owner%02d", $0) })
        let small = HotkeyAssignments.plan(registeredToggle: nil, itemHotkeys: items, capacity: 2)
        #expect(small.items.map(\.ownerKey) == ["Owner00", "Owner01"])
        #expect(small.skipped.count == 38)
    }

    @Test func planSkipsEveryItemWhileTheFloatingBarIsOff() {
        // Reflow mode has no icon cache to resolve an item from, so even clean combos stay inert.
        let items = [
            "Good": combo(46, cmd | opt),
            "Clash": HotkeyCombo.defaultToggle,
            "Quit": combo(12, cmd),
        ]
        let off = HotkeyAssignments.plan(registeredToggle: .defaultToggle, itemHotkeys: items, floatingBarEnabled: false)
        #expect(off.items.isEmpty)
        #expect(off.skipped == [
            "Good": .requiresFloatingBar,
            "Clash": .requiresFloatingBar,
            "Quit": .requiresFloatingBar,
        ])
        #expect(!off.isEmpty)
        #expect(HotkeyAssignments.plan(registeredToggle: nil, itemHotkeys: [:], floatingBarEnabled: false).isEmpty)

        // The default is the floating-bar case, and the other reasons resurface once it is on.
        let on = HotkeyAssignments.plan(registeredToggle: .defaultToggle, itemHotkeys: items, floatingBarEnabled: true)
        #expect(on == HotkeyAssignments.plan(registeredToggle: .defaultToggle, itemHotkeys: items))
        #expect(on.items.map(\.ownerKey) == ["Good"])
        #expect(on.skipped == ["Clash": .conflict(.toggleBar), "Quit": .conflict(.systemReserved)])
    }

    @Test func planStoresNormalizedCombosSoRegistrationSeesOnlyShortcutFlags() {
        let dirty = combo(46, cmd | opt | (1 << 23))
        let plan = HotkeyAssignments.plan(registeredToggle: nil, itemHotkeys: ["Maccy": dirty])
        #expect(plan.items == [HotkeyAssignments.Plan.Entry(ownerKey: "Maccy", combo: combo(46, cmd | opt))])
    }
}

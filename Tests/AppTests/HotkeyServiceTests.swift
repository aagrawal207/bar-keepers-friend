import AppKit
import BarKeepersFriendCore
import Testing

/// Drives `HotkeyService` through a fake registrar: no Carbon registration, no key events. The
/// registry that routes fired ids is process-wide, so the suite is serialized.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct HotkeyServiceTests {
    @MainActor
    final class FakeRegistrar: HotkeyRegistrar {
        struct Registration: Equatable {
            let id: UInt32
            let keyCode: UInt32
            let carbonModifiers: UInt32
        }

        private(set) var live: [UInt32: Registration] = [:]
        private(set) var registerCalls: [Registration] = []
        private(set) var unregisterCalls: [UInt32] = []
        private(set) var installCalls = 0
        private(set) var removeCalls = 0
        var installSucceeds = true
        /// Key codes the "system" refuses, as if another app already held them.
        var refusedKeyCodes: Set<UInt32> = []
        static let refusalStatus: OSStatus = -9878 // eventHotKeyExistsErr

        func installHandler() -> Bool {
            installCalls += 1
            return installSucceeds
        }

        func removeHandler() { removeCalls += 1 }

        func register(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus {
            let registration = Registration(id: id, keyCode: keyCode, carbonModifiers: carbonModifiers)
            registerCalls.append(registration)
            guard !refusedKeyCodes.contains(keyCode) else { return Self.refusalStatus }
            live[id] = registration
            return noErr
        }

        func unregister(id: UInt32) {
            unregisterCalls.append(id)
            live.removeValue(forKey: id)
        }

        var liveIDs: Set<UInt32> { Set(live.keys) }
    }

    private let cmdOpt = HotkeyCombo.command | HotkeyCombo.option
    private let optCmdMask = HotkeyCarbon.cmdKey | HotkeyCarbon.optionKey
    private let maccy = HotkeyCombo(keyCode: 46, modifiers: HotkeyCombo.command | HotkeyCombo.option)   // Option-Command-M
    private let itsycal = HotkeyCombo(keyCode: 34, modifiers: HotkeyCombo.command | HotkeyCombo.option) // Option-Command-I

    private func preferences(
        enableToggle: Bool = true, toggle: HotkeyCombo = .defaultToggle, items: [String: HotkeyCombo] = [:],
        useFloatingBar: Bool = true
    ) -> Preferences {
        var preferences = Preferences.default
        preferences.enableGlobalHotkey = enableToggle
        preferences.toggleHotkey = toggle
        preferences.itemHotkeys = items
        preferences.useFloatingBar = useFloatingBar
        return preferences
    }

    @Test func reflowModeRegistersOnlyTheToggleAndRevivesItemsWhenTheBarReturns() {
        let registrar = FakeRegistrar()
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        var fired: [String] = []
        service.onActivateItem = { fired.append($0) }

        let reflow = preferences(items: ["Maccy": maccy, "Itsycal": itsycal], useFloatingBar: false)
        service.apply(preferences: reflow)
        #expect(registrar.liveIDs == [1])
        #expect(registrar.registerCalls.count == 1)
        #expect(service.lastRegistrationFailures.isEmpty, "a planned skip is not a registration failure")
        let plan = HotkeyService.plan(for: reflow)
        #expect(plan.items.isEmpty)
        #expect(plan.skipped == ["Maccy": .requiresFloatingBar, "Itsycal": .requiresFloatingBar])
        // A stale item id from an earlier floating-bar session must not route anywhere.
        HotkeyService.dispatchFiredHotkey(id: 1000)
        HotkeyService.dispatchFiredHotkey(id: 1001)
        #expect(fired.isEmpty)

        service.apply(preferences: preferences(items: ["Maccy": maccy, "Itsycal": itsycal]))
        #expect(registrar.liveIDs == [1, 1000, 1001])
        HotkeyService.dispatchFiredHotkey(id: 1001)
        #expect(fired == ["Maccy"])

        service.apply(preferences: reflow)
        #expect(registrar.liveIDs == [1])
        #expect(Set(registrar.unregisterCalls).isSuperset(of: [1000, 1001]))
    }

    @Test func applyRegistersTheToggleInSlotOneAndItemsFromSlotOneThousandInOwnerOrder() {
        let registrar = FakeRegistrar()
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        service.apply(preferences: preferences(items: ["Maccy": maccy, "Itsycal": itsycal]))

        #expect(registrar.installCalls == 1)
        #expect(registrar.liveIDs == [1, 1000, 1001])
        #expect(registrar.live[1] == .init(id: 1, keyCode: 11, carbonModifiers: optCmdMask))
        // Sorted owner keys: Itsycal before Maccy, so slot indices are stable across launches.
        #expect(registrar.live[1000] == .init(id: 1000, keyCode: 34, carbonModifiers: optCmdMask))
        #expect(registrar.live[1001] == .init(id: 1001, keyCode: 46, carbonModifiers: optCmdMask))
        #expect(service.lastRegistrationFailures.isEmpty)
        #expect(HotkeyService.plan(for: preferences(items: ["Maccy": maccy, "Itsycal": itsycal])).items.map(\.ownerKey) == ["Itsycal", "Maccy"])
    }

    @Test func aDisabledOrUnassignableToggleLeavesSlotOneEmptyButItemsStillRegister() {
        for toggle in [preferences(enableToggle: false, items: ["Maccy": maccy]),
                       preferences(toggle: HotkeyCombo(keyCode: 12, modifiers: HotkeyCombo.command), items: ["Maccy": maccy]),
                       preferences(toggle: HotkeyCombo(keyCode: 11, modifiers: HotkeyCombo.shift), items: ["Maccy": maccy])] {
            let registrar = FakeRegistrar()
            let service = HotkeyService(registrar: registrar)
            service.apply(preferences: toggle)
            #expect(registrar.liveIDs == [1000])
            #expect(HotkeyService.registeredToggle(in: toggle) == nil)
            service.teardown()
        }
    }

    @Test func theToggleWinsAnItemThatUsesTheSameCombo() {
        let registrar = FakeRegistrar()
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        var fired: [String] = []
        service.onActivateItem = { fired.append($0) }

        service.apply(preferences: preferences(items: ["Clash": .defaultToggle, "Maccy": maccy]))
        #expect(registrar.liveIDs == [1, 1000])
        #expect(registrar.live[1000]?.keyCode == 46)
        #expect(service.lastRegistrationFailures.isEmpty, "a planned skip is not a registration failure")
        HotkeyService.dispatchFiredHotkey(id: 1000)
        #expect(fired == ["Maccy"])

        // With the toggle off the item may have that combo.
        service.apply(preferences: preferences(enableToggle: false, items: ["Clash": .defaultToggle, "Maccy": maccy]))
        #expect(registrar.liveIDs == [1000, 1001])
        #expect(registrar.live[1000]?.keyCode == 11)
        HotkeyService.dispatchFiredHotkey(id: 1000)
        #expect(fired == ["Maccy", "Clash"])
    }

    @Test func reapplyTearsDownEveryLiveRegistrationBeforeRebuildingAndKeepsOneHandler() {
        let registrar = FakeRegistrar()
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        service.apply(preferences: preferences(items: ["Maccy": maccy, "Itsycal": itsycal]))
        let first = registrar.registerCalls.count
        #expect(first == 3)

        service.apply(preferences: preferences(items: ["Maccy": maccy]))
        #expect(Set(registrar.unregisterCalls) == [1, 1000, 1001])
        #expect(registrar.liveIDs == [1, 1000])
        #expect(registrar.live[1000]?.keyCode == 46)
        #expect(registrar.registerCalls.count == first + 2)
        #expect(registrar.installCalls == 1)
        #expect(registrar.removeCalls == 0)

        service.apply(preferences: preferences(enableToggle: false))
        #expect(registrar.liveIDs.isEmpty)
        #expect(registrar.installCalls == 1)
    }

    @Test func itemSlotsAreCappedAtThirtyTwo() {
        var items: [String: HotkeyCombo] = [:]
        for code in 0..<40 {
            items[String(format: "Owner%02d", code)] = HotkeyCombo(keyCode: code, modifiers: HotkeyCombo.control | HotkeyCombo.option)
        }
        let registrar = FakeRegistrar()
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        service.apply(preferences: preferences(items: items))
        let itemIDs = registrar.liveIDs.filter { $0 >= 1000 }
        #expect(itemIDs.count == 32)
        #expect(itemIDs == Set(1000..<1032))
        #expect(registrar.liveIDs.contains(1))
        #expect(service.lastRegistrationFailures.isEmpty)

        var fired: [String] = []
        service.onActivateItem = { fired.append($0) }
        HotkeyService.dispatchFiredHotkey(id: 1031)
        HotkeyService.dispatchFiredHotkey(id: 1032)
        #expect(fired == ["Owner31"])
    }

    @Test func refusedRegistrationsAreRecordedByKeyAndNeverStopTheOthers() {
        let registrar = FakeRegistrar()
        registrar.refusedKeyCodes = [46] // Maccy's Option-Command-M is "held by another app"
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        service.apply(preferences: preferences(items: ["Maccy": maccy, "Itsycal": itsycal]))
        #expect(registrar.liveIDs == [1, 1000])
        #expect(service.lastRegistrationFailures == ["Maccy"])

        var fired: [String] = []
        service.onActivateItem = { fired.append($0) }
        // The refused slot id must not route anywhere.
        HotkeyService.dispatchFiredHotkey(id: 1001)
        HotkeyService.dispatchFiredHotkey(id: 1000)
        #expect(fired == ["Itsycal"])

        registrar.refusedKeyCodes = [11]
        service.apply(preferences: preferences(items: ["Maccy": maccy]))
        #expect(service.lastRegistrationFailures == [HotkeyService.toggleFailureIdentifier])
        #expect(registrar.liveIDs == [1000])

        registrar.refusedKeyCodes = []
        service.apply(preferences: preferences(items: ["Maccy": maccy]))
        #expect(service.lastRegistrationFailures.isEmpty)
        #expect(registrar.liveIDs == [1, 1000])
    }

    @Test func firedIDsRouteToTheToggleOrTheOwningItemAndUnknownIDsAreIgnored() {
        let registrar = FakeRegistrar()
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        var toggles = 0
        var fired: [String] = []
        service.onToggle = { toggles += 1 }
        service.onActivateItem = { fired.append($0) }
        service.apply(preferences: preferences(items: ["Maccy": maccy, "Itsycal": itsycal]))

        HotkeyService.dispatchFiredHotkey(id: 1)
        HotkeyService.dispatchFiredHotkey(id: 1000)
        HotkeyService.dispatchFiredHotkey(id: 1001)
        HotkeyService.dispatchFiredHotkey(id: 999)
        HotkeyService.dispatchFiredHotkey(id: 1002)
        HotkeyService.dispatchFiredHotkey(id: 2)
        #expect(toggles == 1)
        #expect(fired == ["Itsycal", "Maccy"])
    }

    @Test func aStaleItemIDStopsRoutingAfterReapply() {
        let registrar = FakeRegistrar()
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        var fired: [String] = []
        service.onActivateItem = { fired.append($0) }
        service.apply(preferences: preferences(items: ["Maccy": maccy, "Itsycal": itsycal]))
        service.apply(preferences: preferences(items: ["Maccy": maccy]))

        HotkeyService.dispatchFiredHotkey(id: 1001)
        #expect(fired.isEmpty)
        HotkeyService.dispatchFiredHotkey(id: 1000)
        #expect(fired == ["Maccy"])
    }

    @Test func teardownUnregistersEverythingRemovesTheHandlerAndSilencesFiredIDs() {
        let registrar = FakeRegistrar()
        let service = HotkeyService(registrar: registrar)
        var toggles = 0
        service.onToggle = { toggles += 1 }
        service.apply(preferences: preferences(items: ["Maccy": maccy]))
        #expect(registrar.liveIDs == [1, 1000])

        service.teardown()
        #expect(registrar.liveIDs.isEmpty)
        #expect(registrar.removeCalls == 1)
        HotkeyService.dispatchFiredHotkey(id: 1)
        #expect(toggles == 0)

        // A later apply reinstalls the handler exactly once more.
        service.apply(preferences: preferences())
        #expect(registrar.installCalls == 2)
        #expect(registrar.liveIDs == [1])
        HotkeyService.dispatchFiredHotkey(id: 1)
        #expect(toggles == 1)
        service.teardown()
        #expect(registrar.removeCalls == 2)
    }

    @Test func aFailedHandlerInstallIsRetriedOnTheNextApplyAndNeverBlocksRegistration() {
        let registrar = FakeRegistrar()
        registrar.installSucceeds = false
        let service = HotkeyService(registrar: registrar)
        defer { service.teardown() }
        service.apply(preferences: preferences())
        #expect(registrar.installCalls == 1)
        #expect(registrar.liveIDs == [1])

        registrar.installSucceeds = true
        service.apply(preferences: preferences())
        #expect(registrar.installCalls == 2)
        service.apply(preferences: preferences())
        #expect(registrar.installCalls == 2)
        service.teardown()
        #expect(registrar.removeCalls == 1)
    }

    @Test func twoServicesRouteOnlyTheirOwnIDs() {
        // The registry is process-wide; the most recent registration for an id owns it.
        let first = HotkeyService(registrar: FakeRegistrar())
        let second = HotkeyService(registrar: FakeRegistrar())
        defer { first.teardown(); second.teardown() }
        var firstToggles = 0
        var secondToggles = 0
        first.onToggle = { firstToggles += 1 }
        second.onToggle = { secondToggles += 1 }
        first.apply(preferences: preferences())
        second.apply(preferences: preferences())
        HotkeyService.dispatchFiredHotkey(id: 1)
        #expect(firstToggles == 0)
        #expect(secondToggles == 1)

        second.teardown()
        HotkeyService.dispatchFiredHotkey(id: 1)
        #expect(firstToggles == 0)
        #expect(secondToggles == 1)
    }
}

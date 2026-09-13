import AppKit
import BarKeepersFriendCore
import Carbon.HIToolbox

/// Registers global keyboard shortcuts using Carbon's `RegisterEventHotKey`. This API delivers
/// hotkeys system-wide without needing Accessibility permission (unlike a CGEventTap), which
/// matters because the floating bar's whole point is to work with minimal permissions.
///
/// Why Carbon, despite being old: `RegisterEventHotKey` is still the only public way to claim a
/// global hotkey without either the Accessibility entitlement (CGEventTap) or sandbox-incompatible
/// IOKit. The downside is its C API — the event handler is a bare C function pointer that cannot
/// capture Swift context — which is the tricky part under Swift 6 strict concurrency.
///
/// The concurrency story: Carbon delivers hotkey events on the main run loop (the main thread).
/// We exploit that. A process-wide `@MainActor` table maps each registered hotkey id back to the
/// owning `HotkeyService`, and the C trampoline reaches it via `MainActor.assumeIsolated` — sound
/// precisely *because* the dispatch is already on the main thread, so no hop or `@Sendable`
/// smuggling is needed. (A single app only ever has one `HotkeyService`, but the table keeps the
/// design honest and avoids a captured global singleton.)
///
/// The Carbon calls themselves sit behind `HotkeyRegistrar`, so tests assert what would be
/// registered without an event loop; `CarbonHotkeyRegistrar` is the production implementation.
@MainActor
final class HotkeyService {
    /// Invoked on the main actor when the toggle-bar hotkey fires.
    var onToggle: (() -> Void)?

    /// Invoked on the main actor with the owner key (`ItemControlStore.key`) whose item shortcut fired.
    var onActivateItem: ((String) -> Void)?

    /// Marks the toggle slot in `lastRegistrationFailures`; owner keys are app names or bundle ids.
    static let toggleFailureIdentifier = "bkf.toggle-bar"

    /// Owner keys (or `toggleFailureIdentifier`) whose combo Carbon refused in the last `apply`,
    /// typically because another app already holds it. Rebuilt on every `apply`.
    private(set) var lastRegistrationFailures: [String] = []

    /// The shortcuts we manage. The id is what Carbon hands back in the event, so the handler
    /// can tell which fired. Item ids are dense from `itemBaseID`, reassigned on every `apply`.
    private enum Slot: Hashable {
        case toggle
        case item(Int)

        static let toggleID: UInt32 = 1
        static let itemBaseID: UInt32 = 1000

        var id: UInt32 {
            switch self {
            case .toggle: Self.toggleID
            case .item(let index): Self.itemBaseID + UInt32(index)
            }
        }

        init?(id: UInt32) {
            if id == Self.toggleID {
                self = .toggle
            } else if id >= Self.itemBaseID, id < Self.itemBaseID + UInt32(HotkeyAssignments.maxItemHotkeys) {
                self = .item(Int(id - Self.itemBaseID))
            } else {
                return nil
            }
        }
    }

    /// Ids currently claimed through the registrar. Rebuilt on every `apply`.
    private var registeredIDs: Set<UInt32> = []
    /// Owner key behind each live item slot, so a fired id resolves to the item to activate.
    private var itemOwners: [UInt32: String] = [:]
    private var handlerInstalled = false
    private let registrar: HotkeyRegistrar

    init(registrar: HotkeyRegistrar = CarbonHotkeyRegistrar()) {
        self.registrar = registrar
    }

    /// The toggle combo `apply` will register for `preferences`, or nil when the shortcut is off or
    /// unassignable (reserved by macOS, shift-only, or corrupt). Shared with the plan below.
    static func registeredToggle(in preferences: Preferences) -> HotkeyCombo? {
        guard preferences.enableGlobalHotkey, HotkeyAssignments.isAssignable(preferences.toggleHotkey) else { return nil }
        return preferences.toggleHotkey
    }

    /// Exactly the item shortcuts `apply` registers for `preferences`, with the reason for each
    /// skipped one. Settings renders the same plan so a row never claims a shortcut that is not live.
    static func plan(for preferences: Preferences) -> HotkeyAssignments.Plan {
        HotkeyAssignments.plan(
            registeredToggle: registeredToggle(in: preferences),
            itemHotkeys: preferences.itemHotkeys,
            floatingBarEnabled: preferences.useFloatingBar
        )
    }

    /// (Re)registers every global hotkey to match `preferences`. Tears down whatever was
    /// registered before, then registers the toggle-bar combo when `enableGlobalHotkey` is on and
    /// assignable, followed by the planned item shortcuts (the toggle wins any clash). Safe to
    /// call repeatedly (e.g. after a settings change): it fully rebuilds, so it never
    /// double-registers.
    func apply(preferences: Preferences) {
        // Start clean so a disabled/changed combo doesn't linger. We keep the event handler.
        unregisterAll()
        lastRegistrationFailures = []

        let toggle = Self.registeredToggle(in: preferences)
        if let toggle {
            register(combo: toggle, slot: .toggle, failureKey: Self.toggleFailureIdentifier)
        }
        for (index, entry) in Self.plan(for: preferences).items.enumerated() {
            let slot = Slot.item(index)
            if register(combo: entry.combo, slot: slot, failureKey: entry.ownerKey) {
                itemOwners[slot.id] = entry.ownerKey
            }
        }

        // No registrations survived (everything off/invalid)? Drop ourselves from the table so a
        // stray event can never reach a now-inert service. The handler stays installed but inert.
        if registeredIDs.isEmpty {
            HotkeyRegistry.shared.remove(self)
        }
    }

    /// Unregisters every hotkey and removes the shared event handler. Called on teardown.
    func teardown() {
        unregisterAll()
        if handlerInstalled {
            registrar.removeHandler()
            handlerInstalled = false
        }
        HotkeyRegistry.shared.remove(self)
    }

    // MARK: - Registration

    /// Registers one combo for `slot`. Installs the shared handler on first use and records the
    /// service in the global table so the C trampoline can route events back. A failed
    /// registration (e.g. the combo is already claimed system-wide) is logged, recorded under
    /// `failureKey`, and skipped, never fatal: one unavailable shortcut must not sink the others.
    @discardableResult
    private func register(combo: HotkeyCombo, slot: Slot, failureKey: String) -> Bool {
        installHandlerIfNeeded()

        let status = registrar.register(
            id: slot.id,
            keyCode: UInt32(combo.keyCode),
            carbonModifiers: HotkeyCarbon.carbonModifiers(from: combo)
        )
        guard status == noErr else {
            DebugLog.log("HotkeyService: RegisterEventHotKey failed for \(slot) (\(HotkeyCarbon.displayString(for: combo))), OSStatus \(status)")
            lastRegistrationFailures.append(failureKey)
            return false
        }

        registeredIDs.insert(slot.id)
        // Re-key the table on every successful registration. Cheap, and it guarantees the table
        // points at this service whenever at least one hotkey is live.
        HotkeyRegistry.shared.set(self, for: slot.id)
        DebugLog.log("HotkeyService: registered \(slot) as \(HotkeyCarbon.displayString(for: combo))")
        return true
    }

    /// Unregisters all live ids and clears the table entries, leaving the handler in place.
    private func unregisterAll() {
        for id in registeredIDs {
            registrar.unregister(id: id)
            HotkeyRegistry.shared.remove(forID: id)
        }
        registeredIDs.removeAll()
        itemOwners.removeAll()
    }

    /// Installs the one shared Carbon event handler for `kEventHotKeyPressed`, once. Guarded by
    /// `handlerInstalled` so repeated `apply` calls never stack handlers.
    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        if registrar.installHandler() {
            handlerInstalled = true
        } else {
            DebugLog.log("HotkeyService: InstallEventHandler failed")
        }
    }

    /// Dispatches a fired hotkey id to the right closure. Called by the C trampoline, already on
    /// the main thread (Carbon delivers on the main run loop), so it touches `@MainActor` state
    /// directly. Unknown ids are ignored.
    fileprivate func handle(id: UInt32) {
        switch Slot(id: id) {
        case .toggle:
            onToggle?()
        case .item:
            if let owner = itemOwners[id] { onActivateItem?(owner) }
        case nil:
            break
        }
    }

    /// Routes a fired hotkey id through the registry to its service. The C trampoline calls this
    /// after reading the id from the Carbon event; tests call it in place of a real key press.
    static func dispatchFiredHotkey(id: UInt32) {
        HotkeyRegistry.shared.service(for: id)?.handle(id: id)
    }
}

// MARK: - Registrar seam

/// The Carbon calls `HotkeyService` depends on, isolated so tests observe registrations without
/// touching the event loop. Ids are the service's slot ids; a registrar owns the Carbon refs.
@MainActor
protocol HotkeyRegistrar: AnyObject {
    /// Installs the shared hotkey event handler. Returns false when the system refuses.
    func installHandler() -> Bool
    func removeHandler()
    /// Claims `keyCode` + `carbonModifiers` under `id`. `noErr` means the shortcut is now live.
    func register(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus
    func unregister(id: UInt32)
}

/// Production registrar: thin wrappers over `RegisterEventHotKey` and friends.
@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    /// A four-char signature shared by all our hotkey ids, mostly for tidiness in the Carbon
    /// id struct. The per-hotkey `id` is what actually disambiguates.
    private static let signature: OSType = {
        // 'BKF1' as a big-endian OSType.
        let chars: [UInt8] = Array("BKF1".utf8)
        return chars.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            nil, // userData: we route via the global table instead of a captured pointer.
            &ref
        )
        guard status == noErr else {
            DebugLog.log("HotkeyService: InstallEventHandler failed, OSStatus \(status)")
            return false
        }
        handlerRef = ref
        return true
    }

    func removeHandler() {
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    func register(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32) -> OSStatus {
        // A stale ref under the same id would leak a live registration.
        unregister(id: id)
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return status == noErr ? OSStatus(eventInternalErr) : status }
        refs[id] = ref
        return noErr
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }
}

/// Process-wide map from a fired hotkey id to the `HotkeyService` that should handle it.
///
/// This exists so the C event handler — which can't capture Swift state — has somewhere to look
/// up the owning service. It's `@MainActor` because every access (registration and the handler
/// callback) happens on the main thread, so the isolation is a statement of fact, not a lock.
/// The service is held weakly: the registry must never be the reason a torn-down service stays
/// alive, and a dangling id simply resolves to `nil` and is dropped.
@MainActor
private final class HotkeyRegistry {
    static let shared = HotkeyRegistry()
    private init() {}

    private final class Box {
        weak var service: HotkeyService?
        init(_ service: HotkeyService) { self.service = service }
    }

    private var byID: [UInt32: Box] = [:]

    func set(_ service: HotkeyService, for id: UInt32) {
        byID[id] = Box(service)
    }

    func remove(forID id: UInt32) {
        byID.removeValue(forKey: id)
    }

    /// Drops every entry pointing at `service` (used on teardown / when it goes inert).
    func remove(_ service: HotkeyService) {
        byID = byID.filter { $0.value.service !== service && $0.value.service != nil }
    }

    func service(for id: UInt32) -> HotkeyService? {
        byID[id]?.service
    }
}

/// The C trampoline `InstallEventHandler` calls when a registered hotkey fires. As a plain C
/// function it can't capture context, so it reads the fired `EventHotKeyID` from the event and
/// hands the id to the registry. Carbon dispatches this on the main thread, which makes
/// `MainActor.assumeIsolated` sound: we're already on the main actor's thread, so reaching
/// `@MainActor` state needs no hop. Returning `noErr` marks the event handled.
private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    MainActor.assumeIsolated {
        HotkeyService.dispatchFiredHotkey(id: id)
    }
    return noErr
}

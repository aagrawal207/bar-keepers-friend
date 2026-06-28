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
@MainActor
final class HotkeyService {
    /// Invoked on the main actor when the toggle-bar hotkey fires.
    var onToggle: (() -> Void)?

    /// The shortcuts we manage. The raw value is the per-hotkey id Carbon hands back in the event,
    /// so the handler can tell which fired. Kept stable across re-registration.
    private enum Slot: UInt32 {
        case toggle = 1
    }

    /// A live registration: the ref we must unregister, and the slot it stands for.
    private struct Registration {
        let ref: EventHotKeyRef
        let slot: Slot
    }

    /// Currently-registered hotkeys, by slot. Rebuilt on every `apply`.
    private var registrations: [Slot: Registration] = [:]

    /// The installed Carbon event handler. Installed lazily on first registration and kept for
    /// the service's lifetime — Carbon lets one handler serve every hotkey, so there's no reason
    /// to churn it as combos come and go; we only remove it in `teardown`.
    private var handlerRef: EventHandlerRef?

    /// A four-char signature shared by all our hotkey ids, mostly for tidiness in the Carbon
    /// id struct. The per-hotkey `id` (the `Slot` raw value) is what actually disambiguates.
    private static let signature: OSType = {
        // 'BKF1' as a big-endian OSType.
        let chars: [UInt8] = Array("BKF1".utf8)
        return chars.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    /// (Re)registers the global hotkeys to match `preferences`. Tears down whatever was
    /// registered before, then registers the kept, valid combos — toggle when
    /// `enableGlobalHotkey` is on and its combo is valid, search likewise. Safe to call
    /// repeatedly (e.g. after a settings change): it fully rebuilds, so it never double-registers.
    func apply(preferences: Preferences) {
        // Start clean so a disabled/changed combo doesn't linger. We keep the event handler.
        unregisterAll()

        if preferences.enableGlobalHotkey && preferences.toggleHotkey.isValid {
            register(combo: preferences.toggleHotkey, slot: .toggle)
        }

        // No registrations survived (everything off/invalid)? Drop ourselves from the table so a
        // stray event can never reach a now-inert service. The handler stays installed but inert.
        if registrations.isEmpty {
            HotkeyRegistry.shared.remove(self)
        }
    }

    /// Unregisters every hotkey and removes the shared event handler. Called on teardown.
    func teardown() {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        HotkeyRegistry.shared.remove(self)
    }

    // MARK: - Registration

    /// Registers one combo for `slot`. Installs the shared handler on first use and records the
    /// service in the global table so the C trampoline can route events back. A failed
    /// `RegisterEventHotKey` (e.g. the combo is already claimed system-wide) is logged and
    /// skipped — never fatal, since one unavailable shortcut shouldn't sink the others.
    private func register(combo: HotkeyCombo, slot: Slot) {
        installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            HotkeyCarbon.carbonModifiers(from: combo),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            DebugLog.log("HotkeyService: RegisterEventHotKey failed for \(slot) (\(HotkeyCarbon.displayString(for: combo))), OSStatus \(status)")
            return
        }

        registrations[slot] = Registration(ref: ref, slot: slot)
        // Re-key the table on every successful registration. Cheap, and it guarantees the table
        // points at this service whenever at least one hotkey is live.
        HotkeyRegistry.shared.set(self, for: slot.rawValue)
        DebugLog.log("HotkeyService: registered \(slot) as \(HotkeyCarbon.displayString(for: combo))")
    }

    /// Unregisters all live refs and clears the table entries, leaving the handler in place.
    private func unregisterAll() {
        for (slot, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
            HotkeyRegistry.shared.remove(forID: slot.rawValue)
        }
        registrations.removeAll()
    }

    /// Installs the one shared Carbon event handler for `kEventHotKeyPressed`, once. Guarded by
    /// `handlerRef` so repeated `apply` calls never stack handlers.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

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

        if status == noErr {
            handlerRef = ref
        } else {
            DebugLog.log("HotkeyService: InstallEventHandler failed, OSStatus \(status)")
        }
    }

    /// Dispatches a fired hotkey id to the right closure. Called by the C trampoline, already on
    /// the main thread (Carbon delivers on the main run loop), so it touches `@MainActor` state
    /// directly. Unknown ids are ignored.
    fileprivate func handle(id: UInt32) {
        switch Slot(rawValue: id) {
        case .toggle: onToggle?()
        case nil: break
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
        HotkeyRegistry.shared.service(for: id)?.handle(id: id)
    }
    return noErr
}

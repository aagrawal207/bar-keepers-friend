import BarKeepersFriendCore
import CoreFoundation
import Foundation

/// The user's global defaults domain behind a seam, so tests never touch the real one.
@MainActor
protocol GlobalDefaultsWriting: AnyObject {
    func integer(forKey key: String) -> Int?
    /// `nil` removes the key.
    func set(_ value: Int?, forKey key: String)
}

/// The real per-user global domain, written to both the ByHost and any-host plists: the documented
/// recipe uses `-currentHost`, AppKit's search list reads both, and a reset must clear either copy.
@MainActor
final class SystemGlobalDefaults: GlobalDefaultsWriting {
    private static let hosts: [CFString] = [kCFPreferencesCurrentHost, kCFPreferencesAnyHost]

    func integer(forKey key: String) -> Int? {
        for host in Self.hosts {
            guard let raw = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host) else {
                continue
            }
            if let number = raw as? NSNumber {
                return Int(exactly: number)
            }
            if let text = raw as? String {
                return Int(text.trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        return nil
    }

    func set(_ value: Int?, forKey key: String) {
        for host in Self.hosts {
            let stored: CFPropertyList? = value.map { NSNumber(value: $0) }
            CFPreferencesSetValue(key as CFString, stored, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host)
            if !CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host) {
                DebugLog.log("Menu bar spacing: could not synchronize global defaults for \(key)")
            }
        }
    }
}

/// Applies the spacing preference to the global domain. It never relaunches or signals another
/// app: each one picks the values up the next time it creates its status items.
@MainActor
final class MenuBarSpacingService {
    /// The undocumented AppKit keys, spelled exactly as the `defaults` recipes use them.
    nonisolated static let spacingKey = "NSStatusItemSpacing"
    nonisolated static let selectionPaddingKey = "NSStatusItemSelectionPadding"

    private let defaults: GlobalDefaultsWriting

    init(defaults: GlobalDefaultsWriting = SystemGlobalDefaults()) {
        self.defaults = defaults
    }

    /// Writes both keys (clamped) when enabled, removes both when disabled. Returns whether any
    /// stored value changed, which is exactly when the user needs the relaunch/log-out note.
    @discardableResult
    func apply(_ spacing: MenuBarSpacing) -> Bool {
        let desired = Self.storedValues(for: spacing)
        var changed = false
        for (key, value) in [(Self.spacingKey, desired.spacing), (Self.selectionPaddingKey, desired.selectionPadding)] {
            guard defaults.integer(forKey: key) != value else { continue }
            defaults.set(value, forKey: key)
            changed = true
        }
        if changed {
            let summary = spacing.enabled
                ? "spacing=\(desired.spacing ?? 0) selectionPadding=\(desired.selectionPadding ?? 0)"
                : "removed (system default)"
            DebugLog.log("Menu bar spacing: global defaults updated, \(summary)")
        }
        return changed
    }

    /// Launch-time re-application only asserts an enabled preference: a disabled one must not
    /// erase spacing the user configured outside this app.
    @discardableResult
    func applyAtLaunch(_ spacing: MenuBarSpacing) -> Bool {
        spacing.enabled ? apply(spacing) : false
    }

    /// What the global domain holds right now, unclamped. Absent keys read as the system default;
    /// a single present key reads as enabled with the other value at its system default.
    func current() -> MenuBarSpacing {
        let spacing = defaults.integer(forKey: Self.spacingKey)
        let padding = defaults.integer(forKey: Self.selectionPaddingKey)
        guard spacing != nil || padding != nil else { return .systemDefault }
        return MenuBarSpacing(
            enabled: true,
            spacing: spacing ?? MenuBarSpacing.systemDefault.spacing,
            selectionPadding: padding ?? MenuBarSpacing.systemDefault.selectionPadding
        )
    }

    private static func storedValues(for spacing: MenuBarSpacing) -> (spacing: Int?, selectionPadding: Int?) {
        guard spacing.enabled else { return (nil, nil) }
        let clamped = spacing.clamped()
        return (clamped.spacing, clamped.selectionPadding)
    }
}

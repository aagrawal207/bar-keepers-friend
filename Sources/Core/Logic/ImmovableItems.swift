import Foundation

/// Decides which menu bar items must never be moved or hidden.
///
/// Some system items either can't be relocated or break the system UI if disturbed
/// (Control Center modules, Spotlight, the clock, iPhone Mirroring / Live Activities).
/// Attempting to move them corrupts the layout, so the model refuses before issuing any
/// command. Keeping this as a pure predicate makes the policy testable and auditable.
public enum ImmovableItems {

    /// Bundle identifiers that own items the app must leave alone.
    public static let denylistedBundleIDs: Set<String> = [
        "com.apple.controlcenter",      // Control Center + most of its modules
        "com.apple.Spotlight",          // Spotlight (self-relaunches; special-cased)
        "com.apple.systemuiserver",     // legacy system menu extras host
        "com.apple.mediaremote",        // Now Playing
    ]

    /// Window-title fragments that indicate a system item even when the bundle id is
    /// ambiguous (on Tahoe, owner attribution is unreliable — FB18327911).
    public static let denylistedTitleFragments: [String] = [
        "Clock",
        "iPhone Mirroring",
        "BentoBox",        // Control Center's container
    ]

    /// Returns `true` if the given item must not be moved or hidden.
    public static func isImmovable(_ item: MenuBarItemSnapshot) -> Bool {
        if let bundleID = item.ownerBundleID, denylistedBundleIDs.contains(bundleID) {
            return true
        }
        if let title = item.title {
            for fragment in denylistedTitleFragments where title.localizedCaseInsensitiveContains(fragment) {
                return true
            }
        }
        return false
    }

    /// Filters a list down to the items that are safe to manage.
    public static func movableItems(from items: [MenuBarItemSnapshot]) -> [MenuBarItemSnapshot] {
        items.filter { !isImmovable($0) }
    }
}

import Foundation

/// Decides which menu bar items must never be moved or hidden.
///
/// Some system items either can't be relocated or break the system UI if disturbed
/// (Control Center modules, Spotlight, the clock, iPhone Mirroring / Live Activities).
/// Attempting to move them corrupts the layout, so the model refuses before issuing any
/// command. Keeping this as a pure predicate makes the policy testable and auditable.
public enum ImmovableItems {

    /// Bundle identifiers that own items the app must leave alone. Kept for correctness if a real
    /// reverse-DNS id is ever set on a snapshot — but note `MenuBarItemSnapshot.ownerBundleID` is in
    /// practice populated with a *display name*, not a bundle id (enumeration uses
    /// `kCGWindowOwnerName`; attribution uses `localizedName`), so these entries do not match on
    /// their own. The display-name guard below is what actually fires today.
    public static let denylistedBundleIDs: Set<String> = [
        "com.apple.controlcenter",      // Control Center + most of its modules
        "com.apple.Spotlight",          // Spotlight (self-relaunches; special-cased)
        "com.apple.systemuiserver",     // legacy system menu extras host
        "com.apple.mediaremote",        // Now Playing
    ]

    /// Owner *display names* the app must leave alone. This is what `ownerBundleID` actually carries
    /// (see the note above), so this is the set that fires in production. Only "Control Center" is
    /// listed: it is the exact string the attribution layer already treats as canonical
    /// (`AXAttributionProvider` keys its module-label special-case on `app.name == "Control Center"`),
    /// so it is a known invariant, not a guess. Other system owners (Spotlight, Now Playing) and the
    /// localized Control Center *module* labels (Wi-Fi, Battery, …) need on-device observation of the
    /// real attributed strings before they can be added safely — tracked under "Needs hardware
    /// verification". Matching here is strictly protective: it can only make more items immovable.
    public static let denylistedOwnerLabels: Set<String> = [
        "Control Center",
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
        // `ownerBundleID` carries a display name in practice, so check it against BOTH the
        // display-name denylist (the one that actually fires) and the reverse-DNS list (a no-op
        // today, kept correct for any future caller that sets a real bundle id).
        if let owner = item.ownerBundleID,
           denylistedOwnerLabels.contains(owner) || denylistedBundleIDs.contains(owner) {
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

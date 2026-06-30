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

    /// Returns `true` if the item must not be moved or hidden, given a set of owning PIDs whose
    /// items are off-limits. Use on ATTRIBUTED snapshots, where each item carries its REAL owning
    /// pid (post-`AXAttributionProvider`): a single Control-Center pid then catches EVERY Control
    /// Center module (Wi-Fi, Battery, Sound, Clock, the screen-recording privacy indicator, …) at
    /// once — locale-independent and complete, unlike listing each module's display name, which
    /// `denylistedOwnerLabels` deliberately does not attempt (the labels are localized and the set
    /// is open-ended). Passing the app's OWN pid likewise guarantees a stray "Hide All" can never
    /// sweep the app's own status windows into a move.
    ///
    /// CRITICAL: only valid on ATTRIBUTED snapshots. On RAW snapshots every item reports the bogus
    /// blanket Control-Center pid (FB18327911), so a pid set applied there would mark *everything*
    /// immovable — the same trap as the display-name guard (see `isImmovableOnRawSnapshot`). The
    /// move planner and the Settings picker both attribute first, so both may pass a pid set here.
    public static func isImmovable(_ item: MenuBarItemSnapshot, immovablePIDs: Set<pid_t>) -> Bool {
        if immovablePIDs.contains(item.ownerPID) { return true }
        return isImmovable(item)
    }

    /// Returns `true` if the given item must not be moved or hidden. Call this on ATTRIBUTED
    /// snapshots (post-`AXAttributionProvider`), where `ownerBundleID` is the item's real owner
    /// label — so "Control Center" means the genuine Control Center. The move planner runs here.
    public static func isImmovable(_ item: MenuBarItemSnapshot) -> Bool {
        // `ownerBundleID` carries a display name in practice, so check it against BOTH the
        // display-name denylist (the one that actually fires) and the reverse-DNS list (a no-op
        // today, kept correct for any future caller that sets a real bundle id).
        if let owner = item.ownerBundleID, denylistedOwnerLabels.contains(owner) {
            return true
        }
        return isImmovableOnRawSnapshot(item)
    }

    /// Raw-safe immovability: the subset of `isImmovable`'s signals that are valid BEFORE
    /// attribution. On Tahoe (FB18327911) the RAW `kCGWindowOwnerName` reports many genuine
    /// third-party items as "Control Center", so the `denylistedOwnerLabels` display-name guard
    /// must NOT run on raw snapshots — it would drop real, hideable items. The reverse-DNS
    /// bundle-id set and the title-fragment list stay: a raw snapshot never carries a real
    /// reverse-DNS id today (so that branch is an inert no-op, kept for any future raw caller that
    /// does set one) and a real "Clock"/"iPhone Mirroring" title is a trustworthy signal on raw
    /// input. The floating-bar resolver (which filters raw snapshots, attribution runs AFTER it)
    /// uses this; the move planner uses the full `isImmovable` on attributed snapshots.
    public static func isImmovableOnRawSnapshot(_ item: MenuBarItemSnapshot) -> Bool {
        if let owner = item.ownerBundleID, denylistedBundleIDs.contains(owner) {
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

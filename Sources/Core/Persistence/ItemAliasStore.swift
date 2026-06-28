import Foundation

/// User-chosen searchable nicknames for menu bar items, persisted as Codable JSON.
///
/// ## Why this exists
///
/// On macOS 26 (Tahoe) we often can't read a status item's real title: `kCGWindowName`
/// comes back as a generic placeholder like `"Item-0"` (and is `nil` entirely without
/// Screen Recording permission). That makes the Quick Search panel useless for the very
/// items the user most wants to find — the hidden ones. The fix is to let the user attach
/// their own alias to an item, so search can match a name *they* chose.
///
/// ## Why key by owner identity, not window id
///
/// The obvious key would be `MenuBarItemSnapshot.windowID`, but `CGWindowID` is volatile:
/// it's reassigned every time the owning app recreates its status item, which happens on
/// every relaunch (and sometimes mid-session). An alias keyed by window id would silently
/// evaporate the next time you log in. We instead key by the *attributed owner identity* —
/// the app's bundle id — which is stable across relaunches and reboots. The trade-off is
/// granularity: an app showing two status items can't have them aliased separately, since
/// they share a bundle id. That's an acceptable loss for the common case (one item per app),
/// and it's the only identity we can actually rely on (see `MenuBarItemSnapshot.windowID`
/// and `ownerPID` notes — the raw PID is also unreliable on Tahoe).
///
/// The model is a plain value type wrapping a dictionary, so it round-trips through
/// `encode` / `decode` and is fully unit-testable without any system handles.
public struct ItemAliasStore: Equatable, Sendable, Codable {

    /// Aliases keyed by owner identity (see `key(for:)`); value is the user's chosen name.
    /// Exposed read-only so the only ways to mutate are through `setAlias`, which enforce
    /// trimming and empty-means-remove invariants.
    public private(set) var aliases: [String: String]

    public init(aliases: [String: String] = [:]) {
        self.aliases = aliases
    }

    // MARK: - Key derivation

    /// The stable identity an alias is keyed on, or `nil` if the item can't be aliased.
    ///
    /// Returns the snapshot's `ownerBundleID` when present and non-empty. We deliberately do
    /// *not* fall back to the window id or PID: an alias is only worth storing if its key
    /// survives a relaunch, and only the bundle id does. An unattributed item (no bundle id
    /// yet, or an empty string) simply can't be aliased — callers treat the `nil` as "skip".
    public static func key(for snapshot: MenuBarItemSnapshot) -> String? {
        guard let bundleID = snapshot.ownerBundleID, !bundleID.isEmpty else {
            return nil
        }
        return bundleID
    }

    // MARK: - Snapshot-keyed access

    /// The alias for `snapshot`, or `nil` if none is set (or the item has no derivable key).
    public func alias(for snapshot: MenuBarItemSnapshot) -> String? {
        guard let key = Self.key(for: snapshot) else { return nil }
        return alias(forKey: key)
    }

    /// Sets, replaces, or clears the alias for `snapshot`.
    ///
    /// The alias is trimmed of surrounding whitespace first. An empty or whitespace-only
    /// alias (or an explicit `nil`) *removes* the entry rather than storing a blank string —
    /// that's how the settings UI "clears" an alias: the user blanks the field and we forget
    /// it, leaving search to fall back to title/bundle matching. A snapshot with no derivable
    /// key (see `key(for:)`) is a no-op, since there's nowhere stable to store it.
    public mutating func setAlias(_ alias: String?, for snapshot: MenuBarItemSnapshot) {
        guard let key = Self.key(for: snapshot) else { return }
        setAlias(alias, forKey: key)
    }

    // MARK: - Direct-key access (for a settings UI editing by owner identity)

    /// The alias stored under `key`, or `nil` if none.
    public func alias(forKey key: String) -> String? {
        aliases[key]
    }

    /// Sets, replaces, or clears the alias under `key`, with the same trim-and-empty-removes
    /// semantics as `setAlias(_:for:)`. Lets a future settings UI edit aliases by owner
    /// identity directly, without needing a live snapshot in hand.
    public mutating func setAlias(_ alias: String?, forKey key: String) {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            aliases[key] = nil
        } else {
            aliases[key] = trimmed
        }
    }
}

import Foundation

/// Per-item presentation controls for the floating bar, persisted as Codable JSON.
///
/// ## What this controls — and what it deliberately does NOT
///
/// Bar Keeper's Friend never *moves* another app's menu bar item (that needs the fragile
/// private window-server APIs we refuse to call — see `SystemWindowServer.move`). So whether an
/// item is *visible* or *hidden* in the real macOS menu bar is positional and OS-owned: the user
/// sets it by ⌘-dragging the icon across our anchor. This store does NOT pretend to change that.
///
/// What it genuinely owns is how OUR OWN floating bar presents the items it mirrors:
///   - `suppressedFromBar` — "show in search only": the item is still mirrored, still findable in
///     search, still activatable, but we don't draw its row in the floating bar. This is the one
///     tier we can honestly offer; calling it "Always-Hidden" would imply a positional section we
///     can't create, so the UI labels it "Show in bar" / "Search only".
///   - `barOrder` — an explicit left-to-right order for rows within our panel, overriding the
///     default positional order for the items the user pinned.
///
/// ## Why key by owner identity, not window id
///
/// Identical reasoning to [[ItemAliasStore]]: `CGWindowID` is reassigned every relaunch and the
/// raw PID is unreliable on Tahoe (FB18327911), so anything keyed by them would silently evaporate.
/// We key by the attributed owner bundle id, which survives relaunch/reboot. The accepted trade-off
/// is granularity — two status items from one app share a key and so are controlled together. Kept
/// as a SEPARATE store from `ItemAliasStore` (not merged) so each stays single-purpose.
public struct ItemControlStore: Equatable, Sendable, Codable {

    /// Owner identities (see `key(for:)`) the user has chosen to suppress from the bar render.
    /// Exposed read-only; mutate via `setSuppressed`.
    public private(set) var suppressedFromBar: Set<String>

    /// Explicit bar-order index per owner identity (lower sorts further left/earlier). Sparse:
    /// items without an entry keep their positional order, AFTER any explicitly-ordered ones.
    public private(set) var barOrder: [String: Int]

    public init(suppressedFromBar: Set<String> = [], barOrder: [String: Int] = [:]) {
        self.suppressedFromBar = suppressedFromBar
        self.barOrder = barOrder
    }

    // MARK: - Key derivation

    /// The stable identity controls are keyed on, or `nil` if the item can't be controlled.
    /// Same rule as `ItemAliasStore.key(for:)`: the non-empty owner bundle id, else nil.
    public static func key(for snapshot: MenuBarItemSnapshot) -> String? {
        guard let bundleID = snapshot.ownerBundleID, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    // MARK: - Suppression (snapshot-keyed)

    /// Whether `snapshot` is suppressed from the bar render (still searchable/activatable).
    /// An item with no derivable key is never suppressed.
    public func isSuppressed(_ snapshot: MenuBarItemSnapshot) -> Bool {
        guard let key = Self.key(for: snapshot) else { return false }
        return isSuppressed(forKey: key)
    }

    /// Suppresses (or un-suppresses) `snapshot` from the bar. No-op for a keyless item.
    public mutating func setSuppressed(_ on: Bool, for snapshot: MenuBarItemSnapshot) {
        guard let key = Self.key(for: snapshot) else { return }
        setSuppressed(on, forKey: key)
    }

    // MARK: - Order (snapshot-keyed)

    /// The explicit bar-order index for `snapshot`, or `nil` if it has none (keeps positional
    /// order). Keyless items always return `nil`.
    public func orderIndex(for snapshot: MenuBarItemSnapshot) -> Int? {
        guard let key = Self.key(for: snapshot) else { return nil }
        return barOrder[key]
    }

    /// Sets or clears (`nil`) the explicit bar-order index for `snapshot`. No-op for a keyless item.
    public mutating func setOrderIndex(_ index: Int?, for snapshot: MenuBarItemSnapshot) {
        guard let key = Self.key(for: snapshot) else { return }
        setOrderIndex(index, forKey: key)
    }

    // MARK: - Direct-key access (for a settings UI editing by owner identity)

    public func isSuppressed(forKey key: String) -> Bool {
        suppressedFromBar.contains(key)
    }

    public mutating func setSuppressed(_ on: Bool, forKey key: String) {
        if on { suppressedFromBar.insert(key) } else { suppressedFromBar.remove(key) }
    }

    public mutating func setOrderIndex(_ index: Int?, forKey key: String) {
        if let index { barOrder[key] = index } else { barOrder[key] = nil }
    }

    // MARK: - Pure bar-presentation logic

    /// Filters and orders the positionally-hidden items into the list the FLOATING BAR should
    /// render: suppressed items are dropped, then explicitly-ordered items sort first by their
    /// index (ascending), and the rest keep their incoming (positional, left-to-right) order
    /// after them.
    ///
    /// This is the load-bearing honesty/correctness boundary: it operates ONLY on what the bar
    /// draws. Search and `currentItems()` must use the UNfiltered list so a suppressed item stays
    /// findable — that's why this lives here as a pure function rather than inside the shared
    /// cache builder. Stable: items with equal ordering keep their input order (Swift's
    /// `sorted(by:)` is not guaranteed stable, so we sort on a composite key that preserves the
    /// original index for ties).
    public static func visibleBarItems(
        from positionalOrder: [MenuBarItemSnapshot],
        controls: ItemControlStore
    ) -> [MenuBarItemSnapshot] {
        let kept = positionalOrder.enumerated().filter { !controls.isSuppressed($0.element) }
        return kept.sorted { lhs, rhs in
            let lo = controls.orderIndex(for: lhs.element)
            let ro = controls.orderIndex(for: rhs.element)
            switch (lo, ro) {
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.offset < rhs.offset          // equal explicit index → input order
            case (.some, .none):
                return true                              // pinned items sort before unpinned
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset           // both unpinned → positional order
            }
        }.map(\.element)
    }
}

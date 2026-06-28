import Foundation

/// Per-item controls for the menu bar and the floating bar, persisted as Codable JSON.
///
/// ## What this controls
///
/// The user picks, per item, whether it is **Hidden** or **Shown** in the real macOS menu bar.
/// "Hidden" means the app physically moves that item to the left of our anchor (via the private
/// window-server move — see `SystemWindowServer.move`), where the divider tucks it off-screen and
/// the floating bar mirrors it; "Shown" moves it back to the right of the anchor. That intent is
/// `hiddenInMenuBar`, and `HiddenLayoutPlanner` turns it into the concrete moves to apply.
///
/// On top of that menu-bar placement, this store also owns how OUR OWN floating bar presents the
/// items it mirrors:
///   - `suppressedFromBar` — a hidden item the user doesn't even want drawn in the floating bar
///     (still mirrored/activatable, just not rendered). A secondary, rarely-needed tier.
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

    /// Owner identities (see `key(for:)`) the user has chosen to HIDE in the real menu bar — the
    /// app moves these left of the anchor so the divider tucks them away. The primary control.
    /// Exposed read-only; mutate via `setHidden`.
    public private(set) var hiddenInMenuBar: Set<String>

    /// Owner identities the user has chosen to suppress from the bar render.
    /// Exposed read-only; mutate via `setSuppressed`.
    public private(set) var suppressedFromBar: Set<String>

    /// Explicit bar-order index per owner identity (lower sorts further left/earlier). Sparse:
    /// items without an entry keep their positional order, AFTER any explicitly-ordered ones.
    public private(set) var barOrder: [String: Int]

    public init(
        hiddenInMenuBar: Set<String> = [],
        suppressedFromBar: Set<String> = [],
        barOrder: [String: Int] = [:]
    ) {
        self.hiddenInMenuBar = hiddenInMenuBar
        self.suppressedFromBar = suppressedFromBar
        self.barOrder = barOrder
    }

    // Lenient decode so adding `hiddenInMenuBar` doesn't fail to load an older saved store.
    enum CodingKeys: String, CodingKey {
        case hiddenInMenuBar
        case suppressedFromBar
        case barOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenInMenuBar = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenInMenuBar) ?? []
        suppressedFromBar = try container.decodeIfPresent(Set<String>.self, forKey: .suppressedFromBar) ?? []
        barOrder = try container.decodeIfPresent([String: Int].self, forKey: .barOrder) ?? [:]
    }

    // MARK: - Key derivation

    /// The stable identity controls are keyed on, or `nil` if the item can't be controlled.
    /// Same rule as `ItemAliasStore.key(for:)`: the non-empty owner bundle id, else nil.
    public static func key(for snapshot: MenuBarItemSnapshot) -> String? {
        guard let bundleID = snapshot.ownerBundleID, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    // MARK: - Menu-bar hide intent (snapshot-keyed)

    /// Whether `snapshot` is marked Hidden in the real menu bar (moved left of the anchor).
    /// An item with no derivable key can't be controlled, so it's never hidden.
    public func isHidden(_ snapshot: MenuBarItemSnapshot) -> Bool {
        guard let key = Self.key(for: snapshot) else { return false }
        return isHidden(forKey: key)
    }

    /// Marks `snapshot` Hidden (or Shown) in the real menu bar. No-op for a keyless item.
    public mutating func setHidden(_ on: Bool, for snapshot: MenuBarItemSnapshot) {
        guard let key = Self.key(for: snapshot) else { return }
        setHidden(on, forKey: key)
    }

    // MARK: - Suppression (snapshot-keyed)

    /// Whether `snapshot` is suppressed from the bar render (still mirrored/activatable).
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

    public func isHidden(forKey key: String) -> Bool {
        hiddenInMenuBar.contains(key)
    }

    public mutating func setHidden(_ on: Bool, forKey key: String) {
        if on { hiddenInMenuBar.insert(key) } else { hiddenInMenuBar.remove(key) }
    }

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
    /// It operates ONLY on what the bar draws, leaving the full mirrored set intact upstream.
    /// Stable: items with equal ordering keep their input order (Swift's `sorted(by:)` is not
    /// guaranteed stable, so we sort on a composite key that preserves the original index for ties).
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

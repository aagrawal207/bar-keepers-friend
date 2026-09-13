import Foundation

/// Per-item controls for the menu bar and the floating bar, persisted as Codable JSON.
///
/// ## What this controls
///
/// The user picks, per item, Shown, Hidden, or Always Hidden in the real macOS menu bar; the three
/// placement sets hold that intent and `HiddenLayoutPlanner` turns it into physical moves.
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
    /// Exposed read-only; mutate via `setHidden`/`setPlacement`.
    public private(set) var hiddenInMenuBar: Set<String>

    /// Owner identities the user has EXPLICITLY chosen to keep Shown (right of the anchor). This is
    /// distinct from "not hidden": an item the user never touched is in NEITHER set, and the
    /// planner must leave it exactly where it is rather than yanking it to the shown side. We only
    /// ever move an item the user explicitly toggled — so hiding one item never rearranges the rest
    /// of the menu bar. Exposed read-only; mutate via `setHidden`/`setPlacement`.
    public private(set) var shownInMenuBar: Set<String>

    /// Owner identities the user has chosen to keep off-screen even while the hidden section is
    /// revealed (left of the always-hidden divider). Mutually exclusive with the two sets above.
    public private(set) var alwaysHiddenInMenuBar: Set<String>

    /// Owner identities the user has chosen to suppress from the bar render.
    /// Exposed read-only; mutate via `setSuppressed`.
    public private(set) var suppressedFromBar: Set<String>

    /// Explicit bar-order index per owner identity (lower sorts further left/earlier). Sparse:
    /// items without an entry keep their positional order, AFTER any explicitly-ordered ones.
    public private(set) var barOrder: [String: Int]

    public init(
        hiddenInMenuBar: Set<String> = [],
        shownInMenuBar: Set<String> = [],
        alwaysHiddenInMenuBar: Set<String> = [],
        suppressedFromBar: Set<String> = [],
        barOrder: [String: Int] = [:]
    ) {
        self.hiddenInMenuBar = hiddenInMenuBar
        self.shownInMenuBar = shownInMenuBar
        self.alwaysHiddenInMenuBar = alwaysHiddenInMenuBar
        self.suppressedFromBar = suppressedFromBar
        self.barOrder = barOrder
    }

    // Lenient decode so adding a field doesn't fail to load an older saved store.
    enum CodingKeys: String, CodingKey {
        case hiddenInMenuBar
        case shownInMenuBar
        case alwaysHiddenInMenuBar
        case suppressedFromBar
        case barOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenInMenuBar = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenInMenuBar) ?? []
        shownInMenuBar = try container.decodeIfPresent(Set<String>.self, forKey: .shownInMenuBar) ?? []
        alwaysHiddenInMenuBar = try container.decodeIfPresent(Set<String>.self, forKey: .alwaysHiddenInMenuBar) ?? []
        suppressedFromBar = try container.decodeIfPresent(Set<String>.self, forKey: .suppressedFromBar) ?? []
        barOrder = try container.decodeIfPresent([String: Int].self, forKey: .barOrder) ?? [:]
    }

    /// Encodes the sets as SORTED arrays so an export is byte-stable across runs.
    ///
    /// `Set`'s iteration order is seeded per-process, so the default Codable synthesis would emit
    /// each set's JSON array in a different order each launch — and `JSONEncoder.sortedKeys` sorts
    /// dictionary *keys*, not array *elements*, so it doesn't help. That made `LayoutConfig` exports
    /// produce spurious diffs (re-exporting an unchanged layout looked changed). Sorting here makes
    /// the same logical store always serialize identically. The on-disk shape is unchanged — still
    /// JSON arrays — so `init(from:)` (which decodes `Set<String>`) reads new and old files alike.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hiddenInMenuBar.sorted(), forKey: .hiddenInMenuBar)
        try container.encode(shownInMenuBar.sorted(), forKey: .shownInMenuBar)
        // Omitted while unused so a bar that never uses the tier exports byte-identical JSON.
        if !alwaysHiddenInMenuBar.isEmpty {
            try container.encode(alwaysHiddenInMenuBar.sorted(), forKey: .alwaysHiddenInMenuBar)
        }
        try container.encode(suppressedFromBar.sorted(), forKey: .suppressedFromBar)
        try container.encode(barOrder, forKey: .barOrder)
    }

    // MARK: - Key derivation

    /// The stable identity controls are keyed on, or `nil` if the item can't be controlled.
    /// Same rule as `ItemAliasStore.key(for:)`: the non-empty owner bundle id, else nil.
    public static func key(for snapshot: MenuBarItemSnapshot) -> String? {
        guard let bundleID = snapshot.ownerBundleID, !bundleID.isEmpty else { return nil }
        return bundleID
    }

    // MARK: - Menu-bar placement intent (snapshot-keyed)

    /// Whether `snapshot` is marked Hidden or Always Hidden in the real menu bar (left of the
    /// anchor). An item with no derivable key can't be controlled, so it's never hidden.
    public func isHidden(_ snapshot: MenuBarItemSnapshot) -> Bool {
        guard let key = Self.key(for: snapshot) else { return false }
        return isHidden(forKey: key)
    }

    /// Whether `snapshot` is marked Always Hidden (left of the always-hidden divider).
    public func isAlwaysHidden(_ snapshot: MenuBarItemSnapshot) -> Bool {
        guard let key = Self.key(for: snapshot) else { return false }
        return isAlwaysHidden(forKey: key)
    }

    /// The saved placement for `snapshot`, or `nil` when the user never chose one.
    public func placement(for snapshot: MenuBarItemSnapshot) -> ItemPlacement? {
        guard let key = Self.key(for: snapshot) else { return nil }
        return placement(forKey: key)
    }

    /// Marks `snapshot` Hidden (or Shown) in the real menu bar. No-op for a keyless item.
    public mutating func setHidden(_ on: Bool, for snapshot: MenuBarItemSnapshot) {
        guard let key = Self.key(for: snapshot) else { return }
        setHidden(on, forKey: key)
    }

    /// Records an explicit placement for `snapshot`. No-op for a keyless item.
    public mutating func setPlacement(_ placement: ItemPlacement, for snapshot: MenuBarItemSnapshot) {
        guard let key = Self.key(for: snapshot) else { return }
        setPlacement(placement, forKey: key)
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

    /// True for both off-screen tiers, so hidden-only callers keep treating the tier as hidden.
    public func isHidden(forKey key: String) -> Bool {
        hiddenInMenuBar.contains(key) || alwaysHiddenInMenuBar.contains(key)
    }

    public func isAlwaysHidden(forKey key: String) -> Bool {
        alwaysHiddenInMenuBar.contains(key)
    }

    /// The saved placement for `key`, or `nil` when the user never chose one. A key that a corrupt
    /// file left in several sets resolves to the most hidden tier, matching `isHidden`.
    public func placement(forKey key: String) -> ItemPlacement? {
        if alwaysHiddenInMenuBar.contains(key) { return .alwaysHidden }
        if hiddenInMenuBar.contains(key) { return .hidden }
        if shownInMenuBar.contains(key) { return .shown }
        return nil
    }

    /// Records an explicit Hidden/Shown intent for `key`. Setting one side clears the other, so an
    /// item is never in both sets. Flipping to Shown does NOT just remove the hidden flag — it
    /// records explicit Shown intent, which is what lets the planner move a just-un-hidden item back
    /// to the right WITHOUT also disturbing every never-configured item. Items the user never
    /// toggled stay in neither set and are left exactly where they are.
    public mutating func setHidden(_ on: Bool, forKey key: String) {
        setPlacement(ItemPlacement(hidden: on), forKey: key)
    }

    /// Records an explicit placement for `key`, keeping the three intent sets mutually exclusive.
    public mutating func setPlacement(_ placement: ItemPlacement, forKey key: String) {
        hiddenInMenuBar.remove(key)
        shownInMenuBar.remove(key)
        alwaysHiddenInMenuBar.remove(key)
        switch placement {
        case .shown: shownInMenuBar.insert(key)
        case .hidden: hiddenInMenuBar.insert(key)
        case .alwaysHidden: alwaysHiddenInMenuBar.insert(key)
        }
    }

    /// Whether the user has recorded ANY explicit placement intent for `key`.
    /// The planner only moves items with an intent; everything else is left where it sits.
    public func hasPlacementIntent(forKey key: String) -> Bool {
        placement(forKey: key) != nil
    }

    /// Whether the user has recorded any explicit placement intent for `snapshot`.
    public func hasPlacementIntent(_ snapshot: MenuBarItemSnapshot) -> Bool {
        guard let key = Self.key(for: snapshot) else { return false }
        return hasPlacementIntent(forKey: key)
    }

    /// Whether any owner carries placement intent, so callers can skip an empty reconcile.
    public var hasAnyPlacementIntent: Bool {
        !hiddenInMenuBar.isEmpty || !shownInMenuBar.isEmpty || !alwaysHiddenInMenuBar.isEmpty
    }

    /// Compares only the placement sets; presentation edits must never schedule physical moves.
    public func hasSamePlacementIntent(as other: ItemControlStore) -> Bool {
        hiddenInMenuBar == other.hiddenInMenuBar
            && shownInMenuBar == other.shownInMenuBar
            && alwaysHiddenInMenuBar == other.alwaysHiddenInMenuBar
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
        orderedBarItems(from: positionalOrder, controls: controls).filter { !controls.isSuppressed($0) }
    }

    /// The bar's display order without the suppression filter, so a Settings list can reorder a
    /// row the bar currently omits. Same stable composite-key sort as `visibleBarItems`.
    public static func orderedBarItems(
        from positionalOrder: [MenuBarItemSnapshot],
        controls: ItemControlStore
    ) -> [MenuBarItemSnapshot] {
        positionalOrder.enumerated().sorted { lhs, rhs in
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

    /// One step along the bar's display order; `.earlier` is left in a strip and up in a list.
    public enum BarOrderStep: Sendable {
        case earlier
        case later
    }

    /// Whether `moveInBar` would change anything: the owner must be in `sectionItems` and have a
    /// neighbor in the requested direction.
    public func canMoveInBar(
        _ snapshot: MenuBarItemSnapshot, _ step: BarOrderStep, among sectionItems: [MenuBarItemSnapshot]
    ) -> Bool {
        guard let key = Self.key(for: snapshot) else { return false }
        let owners = Self.ownerOrder(of: sectionItems, controls: self)
        guard let index = owners.firstIndex(of: key) else { return false }
        return owners.indices.contains(index + (step == .earlier ? -1 : 1))
    }

    /// Swaps the owner's slot with its neighbor and pins every owner in `sectionItems` to a dense
    /// explicit index, so one step is exactly one visible position. Returns false when nothing moved.
    @discardableResult
    public mutating func moveInBar(
        _ snapshot: MenuBarItemSnapshot, _ step: BarOrderStep, among sectionItems: [MenuBarItemSnapshot]
    ) -> Bool {
        guard let key = Self.key(for: snapshot) else { return false }
        var owners = Self.ownerOrder(of: sectionItems, controls: self)
        guard let index = owners.firstIndex(of: key) else { return false }
        let target = index + (step == .earlier ? -1 : 1)
        guard owners.indices.contains(target) else { return false }
        owners.swapAt(index, target)
        for (position, owner) in owners.enumerated() { barOrder[owner] = position }
        return true
    }

    /// Owner keys in bar display order, first appearance wins (siblings share one slot).
    private static func ownerOrder(of items: [MenuBarItemSnapshot], controls: ItemControlStore) -> [String] {
        var seen: Set<String> = []
        return orderedBarItems(from: items, controls: controls)
            .compactMap(key(for:))
            .filter { seen.insert($0).inserted }
    }

    /// Splits items into (hidden, shown) by the user's menu-bar hide intent, preserving each
    /// group's incoming order. Always Hidden counts as hidden here; `partitionByPlacement` keeps
    /// the tiers apart. Pure, so the grouping is unit-tested.
    public static func partitionByHidden(
        _ items: [MenuBarItemSnapshot],
        controls: ItemControlStore
    ) -> (hidden: [MenuBarItemSnapshot], shown: [MenuBarItemSnapshot]) {
        var hidden: [MenuBarItemSnapshot] = []
        var shown: [MenuBarItemSnapshot] = []
        for item in items {
            if controls.isHidden(item) { hidden.append(item) } else { shown.append(item) }
        }
        return (hidden, shown)
    }

    /// Splits items into the three placement tiers by saved intent (unconfigured counts as shown),
    /// preserving each group's incoming order. Backs the Settings Items list's three sections.
    public static func partitionByPlacement(
        _ items: [MenuBarItemSnapshot],
        controls: ItemControlStore
    ) -> (shown: [MenuBarItemSnapshot], hidden: [MenuBarItemSnapshot], alwaysHidden: [MenuBarItemSnapshot]) {
        var shown: [MenuBarItemSnapshot] = []
        var hidden: [MenuBarItemSnapshot] = []
        var alwaysHidden: [MenuBarItemSnapshot] = []
        for item in items {
            switch controls.placement(for: item) ?? .shown {
            case .shown: shown.append(item)
            case .hidden: hidden.append(item)
            case .alwaysHidden: alwaysHidden.append(item)
            }
        }
        return (shown, hidden, alwaysHidden)
    }
}

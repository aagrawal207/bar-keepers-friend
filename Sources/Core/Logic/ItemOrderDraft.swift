/// Session-only, owner-keyed order edits; the existing bar-order keys are written only on Apply.
public struct ItemOrderDraft: Equatable, Sendable {
    public private(set) var orders: [ItemPlacement: [String]] = [:]
    private var editedOwners: [ItemPlacement: Set<String>] = [:]

    public init() {}

    public var isEmpty: Bool { orders.isEmpty }
    public var ownerKeys: Set<String> { editedOwners.values.reduce(into: []) { $0.formUnion($1) } }

    public func ordered(_ items: [MenuBarItemSnapshot], in placement: ItemPlacement) -> [MenuBarItemSnapshot] {
        guard let order = orders[placement] else { return items }
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return items.enumerated().sorted {
            let left = ItemControlStore.key(for: $0.element).flatMap { ranks[$0] } ?? Int.max
            let right = ItemControlStore.key(for: $1.element).flatMap { ranks[$0] } ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    /// The before-owner is a local insertion reference, never a pasteboard value. Siblings move together.
    @discardableResult
    public mutating func move(
        _ owner: String, before nextOwner: String?, in placement: ItemPlacement,
        items: [MenuBarItemSnapshot], baseline: [MenuBarItemSnapshot], ensurePosition: Bool = false
    ) -> Bool {
        let current = Self.ownerOrder(items)
        guard current.contains(owner), nextOwner != owner,
              nextOwner.map({ current.contains($0) }) ?? true else { return false }
        var desired = current.filter { $0 != owner }
        let index = nextOwner.flatMap { desired.firstIndex(of: $0) } ?? desired.endIndex
        desired.insert(owner, at: index)
        guard desired != current || (ensurePosition && desired.count > 1) else { return false }
        if desired == Self.ownerOrder(baseline) && !ensurePosition {
            orders[placement] = nil
            editedOwners[placement] = nil
        } else {
            orders[placement] = desired
            editedOwners[placement, default: []].insert(owner)
        }
        return true
    }

    /// Placement edits can remove the last ordering difference without leaving a phantom draft.
    public mutating func reconcileMembership(in placement: ItemPlacement, baseline: [MenuBarItemSnapshot]) {
        guard let order = orders[placement] else { return }
        let members = Set(Self.ownerOrder(baseline))
        let retained = order.filter { members.contains($0) }
        if Self.ownerOrder(ordered(baseline, in: placement)) == Self.ownerOrder(baseline) {
            orders[placement] = nil
            editedOwners[placement] = nil
        } else {
            orders[placement] = retained
            editedOwners[placement]?.formIntersection(members)
        }
    }

    public func applying(to controls: ItemControlStore) -> ItemControlStore {
        var result = controls
        for placement in [ItemPlacement.hidden, .alwaysHidden] {
            for (index, owner) in (orders[placement] ?? []).enumerated() {
                result.setOrderIndex(index, forKey: owner)
            }
        }
        return result
    }

    public static func ownerOrder(_ items: [MenuBarItemSnapshot]) -> [String] {
        var seen: Set<String> = []
        return items.compactMap(ItemControlStore.key(for:)).filter { seen.insert($0).inserted }
    }
}

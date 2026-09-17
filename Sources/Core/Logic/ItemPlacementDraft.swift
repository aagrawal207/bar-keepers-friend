/// Session-only placement edits; persisted intent is untouched until the caller applies them.
public struct ItemPlacementDraft: Equatable, Sendable {
    private struct Change: Equatable, Sendable {
        let baseline: ItemPlacement?
        var placement: ItemPlacement
    }

    private var changes: [String: Change] = [:]

    public init() {}

    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }
    public var ownerKeys: Set<String> { Set(changes.keys) }

    public func placement(for snapshot: MenuBarItemSnapshot) -> ItemPlacement? {
        guard let key = ItemControlStore.key(for: snapshot) else { return nil }
        return changes[key]?.placement
    }

    /// Bool view of the staged tier for hidden-only callers; Always Hidden reads as hidden.
    public func hidden(for snapshot: MenuBarItemSnapshot) -> Bool? {
        placement(for: snapshot)?.isHidden
    }

    public mutating func setPlacement(
        _ placement: ItemPlacement,
        for items: [(snapshot: MenuBarItemSnapshot, observedPlacement: ItemPlacement?)],
        controls: ItemControlStore
    ) {
        let owners = Dictionary(grouping: items, by: { ItemControlStore.key(for: $0.snapshot) })
        for (key, siblings) in owners {
            guard let key, let first = siblings.first else { continue }
            let saved = controls.placement(forKey: key)
            let selection = first.observedPlacement ?? saved
            // Mixed or unknown selections have no shared baseline to revert to with one choice.
            let baseline = siblings.allSatisfy { ($0.observedPlacement ?? saved) == selection } ? selection : nil
            // Keep even an unknown first-edit baseline when later observations arrive.
            var change = changes[key] ?? Change(baseline: baseline, placement: placement)
            change.placement = placement
            // Returning to the observed tier must still replace an opposing saved placement.
            changes[key] = change.baseline == placement && (saved == nil || saved == placement) ? nil : change
        }
    }

    /// Two-tier entry point; observations map Hidden/Shown, never Always Hidden.
    public mutating func setHidden(
        _ hidden: Bool,
        for items: [(snapshot: MenuBarItemSnapshot, observedHidden: Bool?)],
        controls: ItemControlStore
    ) {
        setPlacement(
            ItemPlacement(hidden: hidden),
            for: items.map { ($0.snapshot, $0.observedHidden.map(ItemPlacement.init(hidden:))) },
            controls: controls
        )
    }

    public func applying(to controls: ItemControlStore) -> ItemControlStore {
        var merged = controls
        for (key, change) in changes {
            merged.setPlacement(change.placement, forKey: key)
        }
        return merged
    }
}

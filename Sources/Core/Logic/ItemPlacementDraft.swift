/// Session-only placement edits; persisted intent is untouched until the caller applies them.
public struct ItemPlacementDraft: Equatable, Sendable {
    private struct Change: Equatable, Sendable {
        let baseline: Bool?
        var hidden: Bool
    }

    private var changes: [String: Change] = [:]

    public init() {}

    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }

    public func hidden(for snapshot: MenuBarItemSnapshot) -> Bool? {
        guard let key = ItemControlStore.key(for: snapshot) else { return nil }
        return changes[key]?.hidden
    }

    public mutating func setHidden(
        _ hidden: Bool,
        for items: [(snapshot: MenuBarItemSnapshot, observedHidden: Bool?)],
        controls: ItemControlStore
    ) {
        let owners = Dictionary(grouping: items, by: { ItemControlStore.key(for: $0.snapshot) })
        for (key, siblings) in owners {
            guard let key, let first = siblings.first else { continue }
            let saved = controls.hasPlacementIntent(forKey: key) ? controls.isHidden(forKey: key) : nil
            let selection = first.observedHidden ?? saved
            // Mixed or unknown selections have no shared baseline to revert to with one choice.
            let baseline = siblings.allSatisfy { ($0.observedHidden ?? saved) == selection } ? selection : nil
            // Keep even an unknown first-edit baseline when later observations arrive.
            var change = changes[key] ?? Change(baseline: baseline, hidden: hidden)
            change.hidden = hidden
            // Returning to the observed side must still replace an opposing saved placement.
            changes[key] = change.baseline == hidden && (saved == nil || saved == hidden) ? nil : change
        }
    }

    public func applying(to controls: ItemControlStore) -> ItemControlStore {
        var merged = controls
        for (key, change) in changes {
            merged.setHidden(change.hidden, forKey: key)
        }
        return merged
    }
}

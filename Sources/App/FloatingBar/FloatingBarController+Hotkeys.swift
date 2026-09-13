import AppKit
import BarKeepersFriendCore

// MARK: - Item shortcuts

extension FloatingBarController {
    /// The window behind the item saved under `ownerKey` (`ItemControlStore.key`). Both cached
    /// tiers answer without touching the menu bar; only a miss enumerates and attributes live
    /// items. Nil when no manageable item currently belongs to that owner.
    func windowID(forOwnerKey ownerKey: String) async -> CGWindowID? {
        let cached = cachedHiddenItems() + cachedAlwaysHiddenItems()
        if let match = cached.first(where: { ItemControlStore.key(for: $0.snapshot) == ownerKey }) {
            return match.id
        }
        guard let items = try? await allManageableItems() else { return nil }
        return items.first { ItemControlStore.key(for: $0.snapshot) == ownerKey }?.id
    }
}

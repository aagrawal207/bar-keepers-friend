import Foundation

/// A named set of menu bar items reachable from one app-owned status item. Members are owner keys
/// (`ItemControlStore.key(for:)`), the identity aliases and intent use, so a group survives relaunch.
public struct ItemGroup: Identifiable, Hashable, Codable, Sendable {
    /// Stable across launches; the status item's autosave name is derived from it.
    public let id: UUID
    public var name: String
    /// Ordered and unique; mutate through `appendKey`/`removeKey`.
    public private(set) var ownerKeys: [String]

    public init(id: UUID = UUID(), name: String, ownerKeys: [String] = []) {
        self.id = id
        self.name = name
        self.ownerKeys = Self.uniqued(ownerKeys)
    }

    public func contains(key: String) -> Bool {
        ownerKeys.contains(key)
    }

    /// Appends `key` unless it is already a member, preserving the existing order.
    public mutating func appendKey(_ key: String) {
        guard !ownerKeys.contains(key) else { return }
        ownerKeys.append(key)
    }

    /// Returns whether `key` was a member.
    @discardableResult
    public mutating func removeKey(_ key: String) -> Bool {
        let before = ownerKeys.count
        ownerKeys.removeAll { $0 == key }
        return ownerKeys.count != before
    }

    // Explicit keys so renaming a Swift property never silently drops stored data.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerKeys
    }

    /// Missing fields fall back rather than fail: members are worth keeping even when the id or
    /// name is absent, and a fresh id only costs the status item its remembered slot.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let rawName = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let trimmed = ItemGroupLibrary.trimmedName(rawName)
        name = trimmed.isEmpty ? ItemGroupLibrary.fallbackName : trimmed
        ownerKeys = Self.uniqued(try container.decodeIfPresent([String].self, forKey: .ownerKeys) ?? [])
    }

    private static func uniqued(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }
}

/// Pure rules for editing groups and deriving the placement they imply. Groups never edit the saved
/// `ItemControlStore`; `effectiveControls` layers "grouped means Hidden" over the user's own intent.
public enum ItemGroupLibrary {

    public static let maxGroups = 20
    public static let maxNameLength = 40
    /// Display name for a decoded group whose stored name is blank or missing.
    public static let fallbackName = "Group"

    public enum ValidationError: Error, Equatable, Sendable {
        case emptyName
        case nameTooLong
        case duplicateName
        case tooManyGroups
        case unknownGroup

        /// User-facing text for inline validation.
        public var message: String {
            switch self {
            case .emptyName: return "Enter a group name."
            case .nameTooLong: return "Group names can have at most \(ItemGroupLibrary.maxNameLength) characters."
            case .duplicateName: return "A group with this name already exists."
            case .tooManyGroups: return "You can have at most \(ItemGroupLibrary.maxGroups) groups."
            case .unknownGroup: return "That group no longer exists."
            }
        }
    }

    // MARK: - Names

    public static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when `proposed` is usable. `excluding` lets a rename keep (or re-case) its own name.
    public static func nameProblem(
        _ proposed: String, in groups: [ItemGroup], excluding groupID: UUID? = nil
    ) -> ValidationError? {
        let trimmed = trimmedName(proposed)
        if trimmed.isEmpty { return .emptyName }
        if trimmed.count > maxNameLength { return .nameTooLong }
        let lowered = trimmed.lowercased()
        if groups.contains(where: { $0.id != groupID && $0.name.lowercased() == lowered }) {
            return .duplicateName
        }
        return nil
    }

    // MARK: - Editing

    /// Appends a new, empty group named `name`. Throws `ValidationError` for a bad name or a full list.
    public static func adding(name: String, to groups: [ItemGroup]) throws -> [ItemGroup] {
        guard groups.count < maxGroups else { throw ValidationError.tooManyGroups }
        if let problem = nameProblem(name, in: groups) { throw problem }
        return groups + [ItemGroup(name: trimmedName(name))]
    }

    /// Drops the group; its members simply stop being grouped (their saved intent is untouched).
    public static func removing(groupID: UUID, from groups: [ItemGroup]) -> [ItemGroup] {
        groups.filter { $0.id != groupID }
    }

    public static func renaming(groupID: UUID, to name: String, in groups: [ItemGroup]) throws -> [ItemGroup] {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            throw ValidationError.unknownGroup
        }
        if let problem = nameProblem(name, in: groups, excluding: groupID) { throw problem }
        var updated = groups
        updated[index].name = trimmedName(name)
        return updated
    }

    public static func group(containing key: String, in groups: [ItemGroup]) -> ItemGroup? {
        groups.first { $0.contains(key: key) }
    }

    /// A key belongs to at most one group, so it leaves every other group first. Unchanged when
    /// `groupID` is unknown.
    public static func assigning(key: String, to groupID: UUID, in groups: [ItemGroup]) -> [ItemGroup] {
        guard groups.contains(where: { $0.id == groupID }) else { return groups }
        return groups.map { group in
            var group = group
            if group.id == groupID {
                group.appendKey(key)
            } else {
                group.removeKey(key)
            }
            return group
        }
    }

    public static func unassigning(key: String, in groups: [ItemGroup]) -> [ItemGroup] {
        groups.map { group in
            var group = group
            group.removeKey(key)
            return group
        }
    }

    /// Repairs arbitrary (decoded) input: duplicate ids and cross-group keys keep their first
    /// occurrence, and groups beyond `maxGroups` are dropped.
    public static func normalized(_ groups: [ItemGroup]) -> [ItemGroup] {
        var seenIDs: Set<UUID> = []
        var seenKeys: Set<String> = []
        var result: [ItemGroup] = []
        for group in groups where seenIDs.insert(group.id).inserted {
            var kept = ItemGroup(id: group.id, name: group.name)
            for key in group.ownerKeys where seenKeys.insert(key).inserted {
                kept.appendKey(key)
            }
            result.append(kept)
            if result.count == maxGroups { break }
        }
        return result
    }

    // MARK: - Derived placement

    public static func groupedKeys(in groups: [ItemGroup]) -> Set<String> {
        Set(groups.flatMap(\.ownerKeys))
    }

    /// `base` with every grouped key marked Hidden, so the planner tucks grouped items behind the
    /// divider. Ungrouped keys keep their saved intent exactly, including an explicit Shown.
    public static func effectiveControls(groups: [ItemGroup], base: ItemControlStore) -> ItemControlStore {
        var controls = base
        for key in groupedKeys(in: groups) {
            controls.setHidden(true, forKey: key)
        }
        return controls
    }

    /// A keyless snapshot can never be grouped, mirroring `ItemControlStore`.
    public static func isGrouped(_ snapshot: MenuBarItemSnapshot, groups: [ItemGroup]) -> Bool {
        guard let key = ItemControlStore.key(for: snapshot) else { return false }
        return group(containing: key, in: groups) != nil
    }
}

import Foundation

/// A named snapshot of the Shown/Hidden arrangement. It stores owner keys (`ItemControlStore.key(for:)`),
/// the same identity the live store uses, so a preset survives relaunches and never depends on a window id.
public struct LayoutPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var itemControls: ItemControlStore

    public init(id: UUID = UUID(), name: String, itemControls: ItemControlStore) {
        self.id = id
        self.name = name
        self.itemControls = itemControls
    }

    // `ItemControlStore` is not Hashable. Hashing only the identity fields stays consistent with
    // the synthesized `==`, which still compares the arrangement.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
    }

    // Explicit keys so renaming a Swift property never silently drops stored data.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case itemControls
    }

    /// Missing fields fall back rather than fail: the arrangement is worth keeping without an id or
    /// name, and a fresh id costs nothing because no rule can reference an id that was never stored.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let trimmed = PresetLibrary.normalizedName(try container.decodeIfPresent(String.self, forKey: .name) ?? "")
        name = trimmed.isEmpty ? PresetLibrary.fallbackName : trimmed
        itemControls = try container.decodeIfPresent(ItemControlStore.self, forKey: .itemControls) ?? ItemControlStore()
    }
}

/// Pure rules for editing the preset list and for moving an arrangement between a preset and
/// `Preferences`. Every editing function returns a new array and leaves invalid input unchanged.
public enum PresetLibrary {

    public static let maxPresets = 50
    public static let maxNameLength = 60
    /// Display name for a decoded preset whose stored name is blank or missing.
    public static let fallbackName = "Preset"

    public enum ValidationProblem: Equatable, Sendable {
        case emptyName
        case nameTooLong
        case duplicateName
        case tooManyPresets

        /// User-facing text for inline validation.
        public var message: String {
            switch self {
            case .emptyName: return "Enter a preset name."
            case .nameTooLong: return "Preset names can have at most \(PresetLibrary.maxNameLength) characters."
            case .duplicateName: return "A preset with this name already exists."
            case .tooManyPresets: return "You can have at most \(PresetLibrary.maxPresets) presets."
            }
        }
    }

    // MARK: - Names

    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when `proposed` is usable. `excludingID` lets a rename keep (or re-case) its own name.
    public static func nameProblem(
        _ proposed: String, existing: [LayoutPreset], excludingID: UUID? = nil
    ) -> ValidationProblem? {
        let trimmed = normalizedName(proposed)
        if trimmed.isEmpty { return .emptyName }
        if trimmed.count > maxNameLength { return .nameTooLong }
        let lowered = trimmed.lowercased()
        if existing.contains(where: { $0.id != excludingID && $0.name.lowercased() == lowered }) {
            return .duplicateName
        }
        return nil
    }

    public static func isValidName(_ proposed: String, existing: [LayoutPreset], excludingID: UUID? = nil) -> Bool {
        nameProblem(proposed, existing: existing, excludingID: excludingID) == nil
    }

    /// Why saving is unavailable, or `nil` when a preset named `name` can be added. A full list
    /// is reported before any name problem so the user learns the real blocker first.
    public static func addProblem(name: String, to presets: [LayoutPreset]) -> ValidationProblem? {
        if presets.count >= maxPresets { return .tooManyPresets }
        return nameProblem(name, existing: presets)
    }

    // MARK: - Capture and apply

    /// A new preset holding the saved arrangement. Pending Items-tab edits are not part of
    /// `preferences` until applied, so they are deliberately not captured.
    public static func capturingCurrent(name: String, preferences: Preferences) -> LayoutPreset {
        LayoutPreset(name: normalizedName(name), itemControls: preferences.itemControls)
    }

    /// `preferences` with the arrangement replaced by the preset's. Aliases, the preset list, and
    /// every other setting are untouched; the engine derives placement from the changed intent.
    public static func applying(_ preset: LayoutPreset, to preferences: Preferences) -> Preferences {
        var applied = preferences
        applied.itemControls = preset.itemControls
        return applied
    }

    /// The first preset whose arrangement equals the saved one. This reflects saved intent, not
    /// observed placement, so a failed native move does not clear it.
    public static func activePreset(in preferences: Preferences) -> LayoutPreset? {
        preferences.presets.first { $0.itemControls == preferences.itemControls }
    }

    // MARK: - Editing

    /// Appends `preset` with a trimmed name. Unchanged for a full list, an invalid or duplicate
    /// name, or an id that is already present.
    public static func adding(_ preset: LayoutPreset, to presets: [LayoutPreset]) -> [LayoutPreset] {
        guard !presets.contains(where: { $0.id == preset.id }),
              addProblem(name: preset.name, to: presets) == nil else { return presets }
        var added = preset
        added.name = normalizedName(preset.name)
        return presets + [added]
    }

    public static func removing(id: UUID, from presets: [LayoutPreset]) -> [LayoutPreset] {
        presets.filter { $0.id != id }
    }

    /// Unchanged for an unknown id or a name that fails `nameProblem` against the other presets.
    public static func renaming(id: UUID, to name: String, in presets: [LayoutPreset]) -> [LayoutPreset] {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              nameProblem(name, existing: presets, excludingID: id) == nil else { return presets }
        var updated = presets
        updated[index].name = normalizedName(name)
        return updated
    }

    /// Refreshes one preset's arrangement from the saved one. Unchanged for an unknown id.
    public static func updating(id: UUID, from preferences: Preferences, in presets: [LayoutPreset]) -> [LayoutPreset] {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return presets }
        var updated = presets
        updated[index].itemControls = preferences.itemControls
        return updated
    }

    /// Repairs decoded input: duplicate ids keep their first occurrence and the list is capped.
    public static func normalized(_ presets: [LayoutPreset]) -> [LayoutPreset] {
        var seen: Set<UUID> = []
        return Array(presets.filter { seen.insert($0.id).inserted }.prefix(maxPresets))
    }
}

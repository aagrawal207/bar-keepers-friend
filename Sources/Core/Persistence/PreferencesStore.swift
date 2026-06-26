import Foundation

/// Abstracts where preferences are read from and written to, so the store can be tested
/// against an in-memory fake instead of the real `UserDefaults`.
public protocol PreferencesPersisting: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// `UserDefaults` already satisfies the shape; this makes the conformance explicit.
extension UserDefaults: PreferencesPersisting {
    public func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }
    public func set(_ data: Data?, forKey key: String) {
        set(data as Any?, forKey: key)
    }
}

/// Loads and saves `Preferences` as JSON. Decoding failures fall back to defaults rather
/// than throwing, so a corrupt or partial file can never prevent the app from launching.
public final class PreferencesStore: @unchecked Sendable {
    private static let storageKey = "com.agraabhi.BarKeepersFriend.preferences"

    private let backing: PreferencesPersisting
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(backing: PreferencesPersisting) {
        self.backing = backing
    }

    /// Reads the stored preferences, or `.default` if nothing valid is stored.
    public func load() -> Preferences {
        guard let data = backing.data(forKey: Self.storageKey) else {
            return .default
        }
        return (try? decoder.decode(Preferences.self, from: data)) ?? .default
    }

    /// Persists the given preferences. Returns whether the write was attempted with
    /// successfully encoded data.
    @discardableResult
    public func save(_ preferences: Preferences) -> Bool {
        guard let data = try? encoder.encode(preferences) else { return false }
        backing.set(data, forKey: Self.storageKey)
        return true
    }

    /// Exports preferences as pretty-printed JSON for the user to back up.
    public func exportJSON(_ preferences: Preferences) throws -> Data {
        let exporter = JSONEncoder()
        exporter.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try exporter.encode(preferences)
    }

    /// Imports preferences from previously exported JSON.
    public func importJSON(_ data: Data) throws -> Preferences {
        try decoder.decode(Preferences.self, from: data)
    }
}

import Foundation

/// A portable snapshot of the user's configuration, for JSON export/import. Lets a user back up
/// or move their setup between machines. Versioned so a future format change can migrate rather
/// than fail.
///
/// AGENT: implement `encoded()` / `decode(from:)` and any validation here. The shape below is
/// the contract the App-side `LayoutTransferService` and its tests depend on — extend it, but
/// keep `version` and `preferences` so old exports keep importing.
public struct LayoutConfig: Equatable, Sendable, Codable {
    /// Schema version of this export. Bump when the shape changes incompatibly.
    public static let currentVersion = 1

    public var version: Int
    /// The exported preferences (the user-facing settings + control-item positions).
    public var preferences: Preferences

    public init(version: Int = LayoutConfig.currentVersion, preferences: Preferences) {
        self.version = version
        self.preferences = preferences
    }

    /// Wraps the given preferences in a current-version config.
    public init(preferences: Preferences) {
        self.init(version: LayoutConfig.currentVersion, preferences: preferences)
    }

    /// Serializes to pretty-printed, stable-key JSON suitable for writing to a file the user can
    /// read and diff.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Parses a config from JSON, throwing `LayoutConfigError` on malformed data or an
    /// unsupported (newer) version.
    public static func decode(from data: Data) throws -> LayoutConfig {
        let config: LayoutConfig
        do {
            config = try JSONDecoder().decode(LayoutConfig.self, from: data)
        } catch {
            throw LayoutConfigError.malformed
        }
        // Reject both a newer version we can't read AND a nonsensical low one (0 / negative): a
        // hand-edited or corrupt file with `version: 0` would otherwise import silently as if it
        // were valid. A real export always stamps `currentVersion` (≥ 1).
        guard config.version >= 1, config.version <= currentVersion else {
            throw LayoutConfigError.unsupportedVersion(config.version)
        }
        return config
    }
}

public enum LayoutConfigError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion(Int)
}

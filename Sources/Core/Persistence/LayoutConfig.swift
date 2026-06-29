import Foundation

/// A portable snapshot of the user's configuration, for JSON export/import. Lets a user back up
/// or move their setup between machines. Versioned so a future format change can migrate rather
/// than fail.
///
/// `encoded()` / `decode(from:)` are the contract the App-side `LayoutTransferService` and its
/// tests depend on. Keep `version` and `preferences` so old exports keep importing; if the shape
/// changes incompatibly, bump `currentVersion` and migrate rather than reject.
public struct LayoutConfig: Equatable, Sendable, Codable {
    /// Schema version of this export. Bump when the shape changes incompatibly.
    public static let currentVersion = 1

    /// Hard upper bound (bytes) on an importable layout file. A real export is a few KB — a
    /// handful of bools, two control-item positions, and one entry per managed item/alias — so
    /// even a heavily-configured layout is far under this. 5 MB is ~1000× any plausible real file
    /// while still rejecting a file chosen to exhaust memory before it's read or parsed. The
    /// importer checks the file size against this *before* reading, and `decode` re-checks the
    /// in-memory data as a backstop for any other caller.
    public static let maxEncodedSize = 5 * 1024 * 1024

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
        // Reject an over-large blob before handing it to JSONDecoder, which would otherwise build
        // an in-memory object graph from the whole thing. A genuine export is a few KB.
        guard data.count <= maxEncodedSize else {
            throw LayoutConfigError.tooLarge(data.count)
        }
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
    /// The file/data exceeded `LayoutConfig.maxEncodedSize`; the associated value is the actual
    /// byte count, so a caller can report it.
    case tooLarge(Int)
}

import Foundation

// MARK: - Actions

/// Legacy action payloads retained solely for preferences and layout compatibility.
/// These values are inert; the app has no widget action runner.
public enum WidgetAction: Hashable, Codable, Sendable {
    case openURL(URL)
    case launchApp(bundleIdentifier: String)
    case runShortcut(name: String)
    case toggleBar

    /// Persisted discriminator. The raw values are on-disk keys; never rename them.
    public enum Kind: String, CaseIterable, Hashable, Codable, Sendable {
        case openURL
        case launchApp
        case runShortcut
        case toggleBar
    }

    public var kind: Kind {
        switch self {
        case .openURL: return .openURL
        case .launchApp: return .launchApp
        case .runShortcut: return .runShortcut
        case .toggleBar: return .toggleBar
        }
    }

    // MARK: Codable

    // On-disk key names; renaming a Swift label must not change these.
    enum CodingKeys: String, CodingKey {
        case type
        case url
        case bundleIdentifier
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: rawType) else {
            throw WidgetActionDecodingError.unknownType(rawType)
        }
        switch kind {
        case .openURL:
            let text = try container.decode(String.self, forKey: .url)
            guard let url = URL(string: text) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Unparsable URL")
            }
            self = .openURL(url)
        case .launchApp:
            self = .launchApp(bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
        case .runShortcut:
            self = .runShortcut(name: try container.decode(String.self, forKey: .name))
        case .toggleBar:
            self = .toggleBar
        }
    }

    /// The URL is stored as its string so the shape does not depend on an encoder's URL special-casing.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case let .openURL(url):
            try container.encode(url.absoluteString, forKey: .url)
        case let .launchApp(bundleIdentifier):
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        case let .runShortcut(name):
            try container.encode(name, forKey: .name)
        case .toggleBar:
            break
        }
    }
}

/// Thrown for a `type` this build does not know, so a lossy array decoder can drop just that widget
/// instead of failing the whole preferences file.
public enum WidgetActionDecodingError: Error, Equatable, Sendable {
    case unknownType(String)
}

// MARK: - Widget

/// Retains legacy widget identities and payloads through unrelated settings edits and exports.
/// Decoding a widget never creates a status item or runs its action.
public struct MenuBarWidget: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var symbolName: String
    public var action: WidgetAction

    public init(id: UUID = UUID(), name: String, symbolName: String, action: WidgetAction) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.action = action
    }

    // Explicit keys so renaming a Swift property never silently drops stored data.
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case symbolName
        case action
    }

    /// Preserve the legacy fallback rules while requiring a readable action payload.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let rawName = WidgetLibrary.trimmed(try container.decodeIfPresent(String.self, forKey: .name) ?? "")
        name = rawName.isEmpty ? WidgetLibrary.fallbackName : rawName
        let rawSymbol = WidgetLibrary.trimmed(try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "")
        symbolName = rawSymbol.isEmpty ? WidgetLibrary.fallbackSymbolName : rawSymbol
        action = try container.decode(WidgetAction.self, forKey: .action)
    }
}

// MARK: - Library

/// Legacy decoding normalization, kept stable so loading old settings does not alter their meaning.
public enum WidgetLibrary {

    public static let maxWidgets = 12
    /// Display name for a decoded widget whose stored name is blank or missing.
    public static let fallbackName = "Widget"
    /// Stored fallback for a decoded widget whose symbol name is blank or missing.
    public static let fallbackSymbolName = "questionmark.square.dashed"

    public static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Repairs decoded input: first occurrence per id, fallbacks for blank names/symbols, capped list.
    /// Readable actions are retained verbatim, including parameters the former editor would refuse.
    public static func normalized(_ widgets: [MenuBarWidget]) -> [MenuBarWidget] {
        var seen: Set<UUID> = []
        var result: [MenuBarWidget] = []
        for widget in widgets where seen.insert(widget.id).inserted {
            var kept = cleaned(widget)
            if kept.name.isEmpty { kept.name = fallbackName }
            if kept.symbolName.isEmpty { kept.symbolName = fallbackSymbolName }
            result.append(kept)
            if result.count == maxWidgets { break }
        }
        return result
    }

    private static func cleaned(_ widget: MenuBarWidget) -> MenuBarWidget {
        var cleaned = widget
        cleaned.name = trimmed(widget.name)
        cleaned.symbolName = trimmed(widget.symbolName)
        return cleaned
    }
}

import Foundation

// MARK: - Actions

/// What a widget does when clicked. The set is closed and parameterized by plain data only: no
/// scripts and no arbitrary executables, so an edited preferences file cannot become code execution.
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

        public var displayName: String {
            switch self {
            case .openURL: return "Open a link"
            case .launchApp: return "Launch an app"
            case .runShortcut: return "Run a Shortcut"
            case .toggleBar: return "Toggle the hidden bar"
            }
        }
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

/// A BKF-owned menu bar item the user defines. The status item's autosave name derives from `id`,
/// so the slot survives relaunches; BKF never hides, mirrors, or moves its own items.
public struct MenuBarWidget: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    /// An SF Symbol name; the app substitutes a placeholder glyph when the OS does not know it.
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

    /// Only the action must decode: a widget without an action has nothing to do, while a missing
    /// id or name costs only the remembered slot or a fallback title.
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

/// Pure rules for editing the widget list and validating actions. Every editing function returns a
/// new array; the status items and Settings both read the result, so nothing here touches AppKit.
public enum WidgetLibrary {

    public static let maxWidgets = 12
    public static let maxNameLength = 40
    /// Display name for a decoded widget whose stored name is blank or missing.
    public static let fallbackName = "Widget"
    /// Drawn for a blank symbol name and by the app for a name the OS does not recognize.
    public static let fallbackSymbolName = "questionmark.square.dashed"
    /// Prefilled for a new widget so the preview is never the placeholder by default.
    public static let defaultSymbolName = "star"
    /// Anything else (file, javascript, data, custom app schemes) is refused before and at run time.
    public static let allowedURLSchemes: Set<String> = ["http", "https", "mailto"]

    public enum ValidationProblem: Error, Equatable, Sendable {
        case emptyName
        case nameTooLong
        case duplicateName
        case tooManyWidgets
        case unknownWidget
        case emptySymbolName
        case emptyURL
        case invalidURL
        case unsupportedURLScheme
        case emptyBundleIdentifier
        case emptyShortcutName

        /// User-facing text for inline validation.
        public var message: String {
            switch self {
            case .emptyName: return "Enter a widget name."
            case .nameTooLong: return "Widget names can have at most \(WidgetLibrary.maxNameLength) characters."
            case .duplicateName: return "A widget with this name already exists."
            case .tooManyWidgets: return "You can have at most \(WidgetLibrary.maxWidgets) widgets."
            case .unknownWidget: return "That widget no longer exists."
            case .emptySymbolName: return "Enter an SF Symbol name."
            case .emptyURL: return "Enter a web address or email link."
            case .invalidURL: return "Enter a complete address, such as https://example.com or mailto:name@example.com."
            case .unsupportedURLScheme: return "Links must start with http://, https://, or mailto:."
            case .emptyBundleIdentifier: return "Choose an app or enter its bundle identifier."
            case .emptyShortcutName: return "Enter the name of a Shortcut."
            }
        }
    }

    // MARK: Names and symbols

    public static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when `proposed` is usable. `excluding` lets an edit keep (or re-case) its own name.
    public static func nameProblem(
        _ proposed: String, in widgets: [MenuBarWidget], excluding widgetID: UUID? = nil
    ) -> ValidationProblem? {
        let name = trimmed(proposed)
        if name.isEmpty { return .emptyName }
        if name.count > maxNameLength { return .nameTooLong }
        let lowered = name.lowercased()
        if widgets.contains(where: { $0.id != widgetID && $0.name.lowercased() == lowered }) {
            return .duplicateName
        }
        return nil
    }

    /// Core cannot know which symbols the OS ships; the app falls back for unknown names.
    public static func symbolProblem(_ symbolName: String) -> ValidationProblem? {
        trimmed(symbolName).isEmpty ? .emptySymbolName : nil
    }

    // MARK: Actions

    /// Parses user-typed text; `nil` only when Foundation cannot form a URL at all. Scheme and host
    /// checks belong to `validate`, which the runner repeats before acting.
    public static func url(fromText text: String) -> URL? {
        let candidate = trimmed(text)
        guard !candidate.isEmpty else { return nil }
        return URL(string: candidate)
    }

    /// Editor-facing check for the link field: distinguishes an untouched field from a broken link.
    public static func urlProblem(fromText text: String) -> ValidationProblem? {
        if trimmed(text).isEmpty { return .emptyURL }
        guard let url = url(fromText: text) else { return .invalidURL }
        return validate(.openURL(url))
    }

    /// `nil` when the action may run. Applied when saving and again right before running, so a
    /// preferences file edited outside the app gets the same scrutiny as the editor.
    public static func validate(_ action: WidgetAction) -> ValidationProblem? {
        switch action {
        case let .openURL(url):
            guard let scheme = url.scheme?.lowercased(), allowedURLSchemes.contains(scheme) else {
                return .unsupportedURLScheme
            }
            if scheme == "mailto" {
                return trimmed(url.path()).isEmpty ? .invalidURL : nil
            }
            guard let host = url.host(), !host.isEmpty else { return .invalidURL }
            return nil
        case let .launchApp(bundleIdentifier):
            return trimmed(bundleIdentifier).isEmpty ? .emptyBundleIdentifier : nil
        case let .runShortcut(name):
            return trimmed(name).isEmpty ? .emptyShortcutName : nil
        case .toggleBar:
            return nil
        }
    }

    /// Short human-readable summary for lists and tooltips. Bundle identifiers are shown raw;
    /// Core has no way to resolve app names.
    public static func displayText(for action: WidgetAction) -> String {
        switch action {
        case let .openURL(url):
            return "Open \(url.absoluteString)"
        case let .launchApp(bundleIdentifier):
            return "Launch \(bundleIdentifier)"
        case let .runShortcut(name):
            return "Run Shortcut \"\(name)\""
        case .toggleBar:
            return "Toggle the hidden bar"
        }
    }

    // MARK: Editing

    /// Why `widget` cannot join `widgets`, or `nil`. A full list is reported before any field
    /// problem so the user learns the real blocker first.
    public static func problem(adding widget: MenuBarWidget, to widgets: [MenuBarWidget]) -> ValidationProblem? {
        if widgets.count >= maxWidgets { return .tooManyWidgets }
        return fieldProblem(widget, in: widgets)
    }

    /// Why `widget` cannot replace the entry with its id, or `nil`.
    public static func problem(updating widget: MenuBarWidget, in widgets: [MenuBarWidget]) -> ValidationProblem? {
        guard widgets.contains(where: { $0.id == widget.id }) else { return .unknownWidget }
        return fieldProblem(widget, in: widgets)
    }

    private static func fieldProblem(_ widget: MenuBarWidget, in widgets: [MenuBarWidget]) -> ValidationProblem? {
        nameProblem(widget.name, in: widgets, excluding: widget.id)
            ?? symbolProblem(widget.symbolName)
            ?? validate(widget.action)
    }

    /// Appends `widget` with trimmed name and symbol. Throws `ValidationProblem` for a full list or
    /// an invalid widget. An id already in the list is replaced in place instead of duplicated.
    public static func adding(_ widget: MenuBarWidget, to widgets: [MenuBarWidget]) throws -> [MenuBarWidget] {
        if widgets.contains(where: { $0.id == widget.id }) { return try updating(widget, in: widgets) }
        if let problem = problem(adding: widget, to: widgets) { throw problem }
        return widgets + [cleaned(widget)]
    }

    /// Replaces the widget with the same id in place, keeping list order.
    public static func updating(_ widget: MenuBarWidget, in widgets: [MenuBarWidget]) throws -> [MenuBarWidget] {
        if let problem = problem(updating: widget, in: widgets) { throw problem }
        return widgets.map { $0.id == widget.id ? cleaned(widget) : $0 }
    }

    public static func removing(id: UUID, from widgets: [MenuBarWidget]) -> [MenuBarWidget] {
        widgets.filter { $0.id != id }
    }

    /// Repairs decoded input: first occurrence per id, fallbacks for blank names/symbols, capped list.
    /// Stored actions are kept so Settings can show the problem; the runner refuses them at run time.
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

// MARK: - Editor draft

/// Editor state for one widget. Every parameter field is kept while the kind changes, so switching
/// to another action and back loses nothing the user typed.
public struct WidgetDraft: Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var kind: WidgetAction.Kind
    public var urlText: String
    public var bundleIdentifier: String
    public var shortcutName: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        symbolName: String = WidgetLibrary.defaultSymbolName,
        kind: WidgetAction.Kind = .openURL,
        urlText: String = "",
        bundleIdentifier: String = "",
        shortcutName: String = ""
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.kind = kind
        self.urlText = urlText
        self.bundleIdentifier = bundleIdentifier
        self.shortcutName = shortcutName
    }

    public init(widget: MenuBarWidget) {
        self.init(id: widget.id, name: widget.name, symbolName: widget.symbolName, kind: widget.action.kind)
        switch widget.action {
        case let .openURL(url): urlText = url.absoluteString
        case let .launchApp(bundleIdentifier): self.bundleIdentifier = bundleIdentifier
        case let .runShortcut(name): shortcutName = name
        case .toggleBar: break
        }
    }

    /// The action the current fields describe, or `nil` when they cannot form one at all.
    public var action: WidgetAction? {
        switch kind {
        case .openURL: return WidgetLibrary.url(fromText: urlText).map(WidgetAction.openURL)
        case .launchApp: return .launchApp(bundleIdentifier: WidgetLibrary.trimmed(bundleIdentifier))
        case .runShortcut: return .runShortcut(name: WidgetLibrary.trimmed(shortcutName))
        case .toggleBar: return .toggleBar
        }
    }

    /// A draft whose id is absent from `existing` is a new widget and counts against the maximum.
    public func isNew(in existing: [MenuBarWidget]) -> Bool {
        !existing.contains { $0.id == id }
    }

    /// `nil` when the draft can be saved into `existing`.
    public func problem(in existing: [MenuBarWidget]) -> WidgetLibrary.ValidationProblem? {
        if isNew(in: existing), existing.count >= WidgetLibrary.maxWidgets { return .tooManyWidgets }
        if let problem = WidgetLibrary.nameProblem(name, in: existing, excluding: id) { return problem }
        if let problem = WidgetLibrary.symbolProblem(symbolName) { return problem }
        switch kind {
        case .openURL: return WidgetLibrary.urlProblem(fromText: urlText)
        case .launchApp: return WidgetLibrary.validate(.launchApp(bundleIdentifier: bundleIdentifier))
        case .runShortcut: return WidgetLibrary.validate(.runShortcut(name: shortcutName))
        case .toggleBar: return nil
        }
    }

    /// The widget to save, or `nil` while `problem(in:)` reports something.
    public func widget(in existing: [MenuBarWidget]) -> MenuBarWidget? {
        guard problem(in: existing) == nil, let action else { return nil }
        return MenuBarWidget(
            id: id, name: WidgetLibrary.trimmed(name), symbolName: WidgetLibrary.trimmed(symbolName), action: action
        )
    }
}

import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct MenuBarWidgetTests {

    private static let site = URL(string: "https://example.com/dashboard?tab=1")!

    private static func widget(
        _ name: String, symbol: String = "star", action: WidgetAction = .toggleBar, id: UUID = UUID()
    ) -> MenuBarWidget {
        MenuBarWidget(id: id, name: name, symbolName: symbol, action: action)
    }

    private static func json(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Codable

    @Test(arguments: [
        WidgetAction.openURL(site), .launchApp(bundleIdentifier: "com.apple.Safari"),
        .runShortcut(name: "Start Focus"), .toggleBar
    ])
    func actionsRoundTripThroughKeyedJSON(action: WidgetAction) throws {
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(WidgetAction.self, from: data) == action)
        let widget = Self.widget("Dashboard", symbol: "gauge", action: action)
        let decoded = try JSONDecoder().decode(MenuBarWidget.self, from: JSONEncoder().encode(widget))
        #expect(decoded == widget)
        #expect(decoded.id == widget.id)
        #expect(decoded.action.kind == action.kind)
    }

    @Test func actionsUseTypeDiscriminatorsAndPlainParameterKeys() throws {
        let open = try Self.json(WidgetAction.openURL(Self.site))
        #expect(open["type"] as? String == "openURL")
        #expect(open["url"] as? String == "https://example.com/dashboard?tab=1")
        #expect(open.count == 2)

        let launch = try Self.json(WidgetAction.launchApp(bundleIdentifier: "com.apple.Safari"))
        #expect(launch["type"] as? String == "launchApp")
        #expect(launch["bundleIdentifier"] as? String == "com.apple.Safari")

        let shortcut = try Self.json(WidgetAction.runShortcut(name: "Start Focus"))
        #expect(shortcut["type"] as? String == "runShortcut")
        #expect(shortcut["name"] as? String == "Start Focus")

        let toggle = try Self.json(WidgetAction.toggleBar)
        #expect(toggle["type"] as? String == "toggleBar")
        #expect(toggle.count == 1)

        // Kind raw values are the on-disk keys.
        #expect(WidgetAction.Kind.allCases.map(\.rawValue) == ["openURL", "launchApp", "runShortcut", "toggleBar"])
        let widget = try Self.json(Self.widget("Dashboard", symbol: "gauge", action: .toggleBar))
        #expect(Set(widget.keys) == ["id", "name", "symbolName", "action"])
    }

    @Test func unknownActionTypesAndBrokenParametersAreRejectedByADedicatedError() {
        #expect(throws: WidgetActionDecodingError.unknownType("runScript")) {
            try JSONDecoder().decode(WidgetAction.self, from: Data(#"{"type":"runScript","source":"rm -rf"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WidgetAction.self, from: Data(#"{"type":"openURL"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WidgetAction.self, from: Data(#"{"type":"openURL","url":"https://exa mple.com"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(WidgetAction.self, from: Data(#"{"url":"https://example.com"}"#.utf8))
        }
        // Missing action payloads remain malformed under the legacy schema.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MenuBarWidget.self, from: Data(#"{"name":"Ghost","symbolName":"star"}"#.utf8))
        }
    }

    @Test func missingIdentityFieldsFallBackInsteadOfFailing() throws {
        let decoded = try JSONDecoder().decode(
            MenuBarWidget.self, from: Data(#"{"name":"   ","symbolName":"","action":{"type":"toggleBar"}}"#.utf8)
        )
        #expect(decoded.name == WidgetLibrary.fallbackName)
        #expect(decoded.symbolName == WidgetLibrary.fallbackSymbolName)
        #expect(decoded.action == .toggleBar)

        let trimmed = try JSONDecoder().decode(
            MenuBarWidget.self, from: Data(#"{"name":"  Mail ","symbolName":" envelope ","action":{"type":"toggleBar"}}"#.utf8)
        )
        #expect(trimmed.name == "Mail")
        #expect(trimmed.symbolName == "envelope")
    }

    @Test func widgetsPersistInsidePreferencesAndAMalformedElementIsDropped() throws {
        var prefs = Preferences.default
        let first = Self.widget("Dashboard", symbol: "gauge", action: .openURL(Self.site))
        let second = Self.widget("Focus", symbol: "moon", action: .runShortcut(name: "Start Focus"))
        prefs.widgets = [first, second]
        let data = try JSONEncoder().encode(prefs)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["widgets"] as? [[String: Any]])?.count == 2)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.widgets == prefs.widgets)
        #expect(decoded == prefs)

        let store = PreferencesStore(backing: InMemoryPreferences())
        try #require(store.save(prefs))
        #expect(store.load() == prefs)
        #expect(try store.importJSON(store.exportJSON(prefs)) == prefs)

        #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).widgets.isEmpty)
        #expect(Preferences.default.widgets.isEmpty)

        // One element written by a newer build must cost that widget only, never the whole file.
        let mixed = Data("""
        {"autoRehide":false,"widgets":[\
        {"id":"\(first.id.uuidString)","name":"Dashboard","symbolName":"gauge",\
        "action":{"type":"openURL","url":"https://example.com/dashboard?tab=1"}},\
        {"id":"\(UUID().uuidString)","name":"Future","symbolName":"bolt","action":{"type":"runScript","source":"x"}},\
        {"id":"\(UUID().uuidString)","name":"Broken","symbolName":"bolt"},\
        "not even an object"]}
        """.utf8)
        let lenient = try JSONDecoder().decode(Preferences.self, from: mixed)
        #expect(!lenient.autoRehide)
        #expect(lenient.widgets.map(\.id) == [first.id])
        #expect(lenient.widgets.map(\.name) == ["Dashboard"])
        #expect(lenient.widgets.first?.action == .openURL(Self.site))

        // A widgets value that is not an array leaves an empty list rather than failing the file.
        let wrongShape = try JSONDecoder().decode(Preferences.self, from: Data(#"{"widgets":{"oops":1}}"#.utf8))
        #expect(wrongShape.widgets.isEmpty)
    }

    @Test func normalizedRepairsDuplicatesBlanksAndOverflow() {
        let shared = UUID()
        let first = Self.widget("First", id: shared)
        let duplicate = Self.widget("Duplicate", symbol: "bolt", id: shared)
        let blank = Self.widget("   ", symbol: "  ")
        let padded = Self.widget(" Padded ", symbol: " gear ")
        let fileLink = Self.widget("Files", action: .openURL(URL(string: "file:///tmp")!))
        let normalized = WidgetLibrary.normalized([first, duplicate, blank, padded, fileLink])
        #expect(normalized.map(\.id) == [shared, blank.id, padded.id, fileLink.id])
        #expect(normalized.map(\.name) == ["First", WidgetLibrary.fallbackName, "Padded", "Files"])
        #expect(normalized.map(\.symbolName) == ["star", WidgetLibrary.fallbackSymbolName, "gear", "star"])
        // Readable payloads outside the former action allowlist must also survive normalization.
        #expect(normalized[3].action == fileLink.action)

        let many = (0..<30).map { Self.widget("Widget \($0)") }
        #expect(WidgetLibrary.normalized(many) == Array(many.prefix(WidgetLibrary.maxWidgets)))
        #expect(WidgetLibrary.normalized([]).isEmpty)
        let valid = [Self.widget("A"), Self.widget("B")]
        #expect(WidgetLibrary.normalized(valid) == valid)
    }
}

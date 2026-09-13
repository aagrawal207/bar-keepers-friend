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
        // A widget without a readable action is unusable and must not decode.
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

    // MARK: - Validation

    @Test func nameValidationRejectsEmptyLongAndCaseInsensitiveDuplicates() {
        let mail = Self.widget("Mail")
        let widgets = [mail]
        #expect(WidgetLibrary.nameProblem("", in: widgets) == .emptyName)
        #expect(WidgetLibrary.nameProblem("  \n", in: widgets) == .emptyName)
        #expect(WidgetLibrary.nameProblem(String(repeating: "x", count: 41), in: widgets) == .nameTooLong)
        #expect(WidgetLibrary.nameProblem(String(repeating: "x", count: 40), in: widgets) == nil)
        #expect(WidgetLibrary.nameProblem(" mAIL ", in: widgets) == .duplicateName)
        #expect(WidgetLibrary.nameProblem("Calendar", in: widgets) == nil)
        // An edit may keep or re-case its own name.
        #expect(WidgetLibrary.nameProblem("MAIL", in: widgets, excluding: mail.id) == nil)
        #expect(WidgetLibrary.symbolProblem("  ") == .emptySymbolName)
        #expect(WidgetLibrary.symbolProblem("envelope") == nil)
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "ftp://files.example.com",
        "x-apple.systempreferences:com.apple.preference", "example.com", "shortcuts://run-shortcut?name=x"
    ])
    func linksOutsideTheAllowlistAreRefused(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(WidgetLibrary.validate(.openURL(url)) == .unsupportedURLScheme)
        #expect(WidgetLibrary.urlProblem(fromText: text) == .unsupportedURLScheme)
    }

    @Test func linkValidationAcceptsCompleteWebAndMailAddressesOnly() {
        #expect(WidgetLibrary.validate(.openURL(Self.site)) == nil)
        #expect(WidgetLibrary.validate(.openURL(URL(string: "HTTPS://Example.com")!)) == nil)
        #expect(WidgetLibrary.validate(.openURL(URL(string: "http://localhost:8080/x")!)) == nil)
        #expect(WidgetLibrary.validate(.openURL(URL(string: "mailto:name@example.com?subject=Hi")!)) == nil)
        #expect(WidgetLibrary.validate(.openURL(URL(string: "https://")!)) == .invalidURL)
        #expect(WidgetLibrary.validate(.openURL(URL(string: "https:///nohost")!)) == .invalidURL)
        #expect(WidgetLibrary.validate(.openURL(URL(string: "mailto:")!)) == .invalidURL)

        #expect(WidgetLibrary.urlProblem(fromText: "") == .emptyURL)
        #expect(WidgetLibrary.urlProblem(fromText: "   ") == .emptyURL)
        #expect(WidgetLibrary.urlProblem(fromText: "https://exa mple.com") == .invalidURL)
        #expect(WidgetLibrary.urlProblem(fromText: "  https://example.com  ") == nil)
        #expect(WidgetLibrary.url(fromText: "  https://example.com  ")?.absoluteString == "https://example.com")
        #expect(WidgetLibrary.url(fromText: " ") == nil)
        #expect(Set(WidgetLibrary.allowedURLSchemes) == ["http", "https", "mailto"])
    }

    @Test func otherActionsRequireTheirParameters() {
        #expect(WidgetLibrary.validate(.launchApp(bundleIdentifier: "")) == .emptyBundleIdentifier)
        #expect(WidgetLibrary.validate(.launchApp(bundleIdentifier: " \t")) == .emptyBundleIdentifier)
        #expect(WidgetLibrary.validate(.launchApp(bundleIdentifier: "com.apple.Safari")) == nil)
        #expect(WidgetLibrary.validate(.runShortcut(name: "")) == .emptyShortcutName)
        #expect(WidgetLibrary.validate(.runShortcut(name: "Start Focus")) == nil)
        #expect(WidgetLibrary.validate(.toggleBar) == nil)
    }

    @Test func displayTextSummarizesEachAction() {
        #expect(WidgetLibrary.displayText(for: .openURL(Self.site)) == "Open https://example.com/dashboard?tab=1")
        #expect(WidgetLibrary.displayText(for: .launchApp(bundleIdentifier: "com.apple.Safari")) == "Launch com.apple.Safari")
        #expect(WidgetLibrary.displayText(for: .runShortcut(name: "Start Focus")) == "Run Shortcut \"Start Focus\"")
        #expect(WidgetLibrary.displayText(for: .toggleBar) == "Toggle the hidden bar")
        #expect(WidgetAction.Kind.allCases.map(\.displayName) == [
            "Open a link", "Launch an app", "Run a Shortcut", "Toggle the hidden bar"
        ])
        for problem in [WidgetLibrary.ValidationProblem.emptyName, .nameTooLong, .duplicateName, .tooManyWidgets,
                        .unknownWidget, .emptySymbolName, .emptyURL, .invalidURL, .unsupportedURLScheme,
                        .emptyBundleIdentifier, .emptyShortcutName] {
            #expect(!problem.message.isEmpty)
        }
    }

    // MARK: - Editing

    @Test func addingTrimsValidatesAndAppends() throws {
        let widgets = try WidgetLibrary.adding(
            Self.widget("  Dashboard  ", symbol: " gauge ", action: .openURL(Self.site)), to: []
        )
        #expect(widgets.map(\.name) == ["Dashboard"])
        #expect(widgets.map(\.symbolName) == ["gauge"])
        let more = try WidgetLibrary.adding(Self.widget("Focus"), to: widgets)
        #expect(more.map(\.name) == ["Dashboard", "Focus"])
        #expect(more[0].id == widgets[0].id)

        #expect(throws: WidgetLibrary.ValidationProblem.duplicateName) {
            try WidgetLibrary.adding(Self.widget("dashboard"), to: widgets)
        }
        #expect(throws: WidgetLibrary.ValidationProblem.emptyName) {
            try WidgetLibrary.adding(Self.widget(" "), to: widgets)
        }
        #expect(throws: WidgetLibrary.ValidationProblem.emptySymbolName) {
            try WidgetLibrary.adding(Self.widget("Notes", symbol: ""), to: widgets)
        }
        #expect(throws: WidgetLibrary.ValidationProblem.unsupportedURLScheme) {
            try WidgetLibrary.adding(Self.widget("Files", action: .openURL(URL(string: "file:///tmp")!)), to: widgets)
        }
        #expect(throws: WidgetLibrary.ValidationProblem.emptyShortcutName) {
            try WidgetLibrary.adding(Self.widget("Run", action: .runShortcut(name: " ")), to: widgets)
        }

        // Re-adding an existing id updates in place rather than duplicating it.
        var renamed = widgets[0]
        renamed.name = "Board"
        let upserted = try WidgetLibrary.adding(renamed, to: more)
        #expect(upserted.map(\.name) == ["Board", "Focus"])
    }

    @Test func addingBeyondTheMaximumIsRejectedBeforeAnyOtherProblem() throws {
        var widgets: [MenuBarWidget] = []
        for index in 0..<WidgetLibrary.maxWidgets {
            widgets = try WidgetLibrary.adding(Self.widget("Widget \(index)"), to: widgets)
        }
        #expect(widgets.count == 12)
        #expect(WidgetLibrary.problem(adding: Self.widget("One more"), to: widgets) == .tooManyWidgets)
        #expect(WidgetLibrary.problem(adding: Self.widget(""), to: widgets) == .tooManyWidgets)
        #expect(throws: WidgetLibrary.ValidationProblem.tooManyWidgets) {
            try WidgetLibrary.adding(Self.widget("One more"), to: widgets)
        }
        // Editing an existing widget of a full list stays possible.
        var edited = widgets[3]
        edited.name = "Renamed"
        #expect(try WidgetLibrary.updating(edited, in: widgets).map(\.name)[3] == "Renamed")
    }

    @Test func updatingReplacesInPlaceAndRemovingDropsById() throws {
        let mail = Self.widget("Mail", action: .openURL(URL(string: "mailto:me@example.com")!))
        let focus = Self.widget("Focus", action: .runShortcut(name: "Start Focus"))
        let widgets = [mail, focus]
        var edited = focus
        edited.name = " Deep Focus "
        edited.symbolName = "moon.fill"
        edited.action = .launchApp(bundleIdentifier: "com.apple.Notes")
        let updated = try WidgetLibrary.updating(edited, in: widgets)
        #expect(updated.map(\.id) == [mail.id, focus.id])
        #expect(updated[1].name == "Deep Focus")
        #expect(updated[1].symbolName == "moon.fill")
        #expect(updated[1].action == .launchApp(bundleIdentifier: "com.apple.Notes"))
        #expect(updated[0] == mail)

        var recased = mail
        recased.name = "MAIL"
        #expect(try WidgetLibrary.updating(recased, in: widgets)[0].name == "MAIL")
        var clash = mail
        clash.name = "focus"
        #expect(throws: WidgetLibrary.ValidationProblem.duplicateName) { try WidgetLibrary.updating(clash, in: widgets) }
        #expect(WidgetLibrary.problem(updating: Self.widget("Ghost"), in: widgets) == .unknownWidget)
        #expect(throws: WidgetLibrary.ValidationProblem.unknownWidget) {
            try WidgetLibrary.updating(Self.widget("Ghost"), in: widgets)
        }
        var badLink = mail
        badLink.action = .launchApp(bundleIdentifier: "")
        #expect(throws: WidgetLibrary.ValidationProblem.emptyBundleIdentifier) {
            try WidgetLibrary.updating(badLink, in: widgets)
        }

        #expect(WidgetLibrary.removing(id: mail.id, from: widgets) == [focus])
        #expect(WidgetLibrary.removing(id: UUID(), from: widgets) == widgets)
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
        // Stored actions are kept for the user to fix; the runner refuses them at run time.
        #expect(normalized[3].action == fileLink.action)

        let many = (0..<30).map { Self.widget("Widget \($0)") }
        #expect(WidgetLibrary.normalized(many) == Array(many.prefix(WidgetLibrary.maxWidgets)))
        #expect(WidgetLibrary.normalized([]).isEmpty)
        let valid = [Self.widget("A"), Self.widget("B")]
        #expect(WidgetLibrary.normalized(valid) == valid)
    }

    // MARK: - Draft

    @Test func draftRoundTripsAWidgetAndKeepsTypedParametersAcrossKindChanges() throws {
        let widget = Self.widget("Dashboard", symbol: "gauge", action: .openURL(Self.site))
        var draft = WidgetDraft(widget: widget)
        #expect(draft.id == widget.id)
        #expect(draft.kind == .openURL)
        #expect(draft.urlText == Self.site.absoluteString)
        #expect(draft.action == widget.action)
        #expect(!draft.isNew(in: [widget]))
        #expect(draft.isNew(in: []))
        #expect(draft.problem(in: [widget]) == nil)
        #expect(draft.widget(in: [widget]) == widget)

        draft.kind = .runShortcut
        #expect(draft.problem(in: [widget]) == .emptyShortcutName)
        #expect(draft.widget(in: [widget]) == nil)
        draft.shortcutName = " Start Focus "
        #expect(draft.action == .runShortcut(name: "Start Focus"))
        #expect(draft.widget(in: [widget])?.action == .runShortcut(name: "Start Focus"))

        draft.kind = .launchApp
        #expect(draft.problem(in: [widget]) == .emptyBundleIdentifier)
        draft.bundleIdentifier = "com.apple.Safari"
        #expect(draft.widget(in: [widget])?.action == .launchApp(bundleIdentifier: "com.apple.Safari"))

        draft.kind = .toggleBar
        #expect(draft.action == .toggleBar)
        #expect(draft.problem(in: [widget]) == nil)

        // Switching back finds the link exactly as typed.
        draft.kind = .openURL
        #expect(draft.urlText == Self.site.absoluteString)
        #expect(draft.widget(in: [widget]) == widget)

        #expect(WidgetDraft(widget: Self.widget("Notes", action: .launchApp(bundleIdentifier: "com.apple.Notes"))).bundleIdentifier == "com.apple.Notes")
        #expect(WidgetDraft(widget: Self.widget("Run", action: .runShortcut(name: "Go"))).shortcutName == "Go")
        #expect(WidgetDraft(widget: Self.widget("Bar")).kind == .toggleBar)
    }

    @Test func newDraftsStartUsableExceptForTheirEmptyFieldsAndRespectTheMaximum() {
        var draft = WidgetDraft()
        #expect(draft.kind == .openURL)
        #expect(draft.symbolName == WidgetLibrary.defaultSymbolName)
        #expect(draft.problem(in: []) == .emptyName)
        draft.name = "Mail"
        #expect(draft.problem(in: []) == .emptyURL)
        draft.urlText = "example.com"
        #expect(draft.problem(in: []) == .unsupportedURLScheme)
        draft.urlText = "https://"
        #expect(draft.problem(in: []) == .invalidURL)
        draft.urlText = "mailto:me@example.com"
        #expect(draft.problem(in: []) == nil)
        #expect(draft.widget(in: [])?.action == .openURL(URL(string: "mailto:me@example.com")!))
        draft.symbolName = ""
        #expect(draft.problem(in: []) == .emptySymbolName)
        draft.symbolName = "envelope"
        #expect(draft.problem(in: [Self.widget("MAIL")]) == .duplicateName)

        let full = (0..<WidgetLibrary.maxWidgets).map { Self.widget("Widget \($0)") }
        #expect(draft.problem(in: full) == .tooManyWidgets)
        #expect(draft.widget(in: full) == nil)
        // Editing a member of a full list is not an addition.
        #expect(WidgetDraft(widget: full[0]).problem(in: full) == nil)
    }
}

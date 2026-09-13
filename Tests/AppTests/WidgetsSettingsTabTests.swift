import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WidgetsSettingsTabTests {
    private static let site = URL(string: "https://example.com")!
    private static let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    /// Records every `onChange` so a test can count writes and inspect what each one carried.
    @MainActor
    final class Recorder {
        var writes: [Preferences] = []
    }

    private static func makeModel(widgets: [MenuBarWidget] = []) -> (SettingsModel, Recorder) {
        var preferences = Preferences.default
        preferences.widgets = widgets
        let recorder = Recorder()
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [] },
            onChange: { recorder.writes.append($0) }
        )
        return (model, recorder)
    }

    /// Sized like the real Settings tab area; the chooser never presents a panel.
    private static func host(_ model: SettingsModel, chooseApp: @escaping @MainActor () -> URL? = { nil }) -> SettingsTestHostingController {
        settingsTestHost(WidgetsSettingsTab(model: model, chooseApp: chooseApp).content.frame(width: 640, height: 600))
    }

    // MARK: - Empty state and identifiers

    @Test func emptyStateExplainsWidgetsAndOnlyOffersAdding() throws {
        let (model, recorder) = Self.makeModel()
        let hosting = Self.host(model)
        let elements = settingsTestAccessibility(hosting.view)
        let identifiers = elements.compactMap { $0.accessibilityIdentifier() }
        for identifier in [
            "settings-widget-content", "settings-widget-header", "settings-widget-empty",
            "settings-widget-footer", "settings-widget-add"
        ] {
            #expect(identifiers.contains(identifier), "\(identifier) must be present")
        }
        #expect(!identifiers.contains("settings-widget-list"))
        #expect(!identifiers.contains("settings-widget-editor"))
        #expect(!identifiers.contains("settings-widget-add-hint"))
        let text = elements.map { settingsTestAccessibilityText($0) }.joined(separator: " ")
        #expect(text.contains("Widgets"))
        #expect(text.contains("No widgets yet."))
        #expect(text.contains("never hides them"))
        #expect(text.contains("Command key"))
        #expect(text.contains("need no Apply Changes"))
        #expect(try element("settings-widget-add", in: hosting.view).isAccessibilityEnabled())
        #expect(recorder.writes.isEmpty)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func listRowsShowSymbolNameActionAndFlagStoredRefusedActions() throws {
        let dashboard = MenuBarWidget(name: "Dashboard", symbolName: "gauge", action: .openURL(Self.site))
        let calculator = MenuBarWidget(name: "Calc", symbolName: "plus.forwardslash.minus", action: .launchApp(bundleIdentifier: "com.apple.calculator"))
        // Only a hand-edited preferences file can store this; the editor refuses it.
        let files = MenuBarWidget(name: "Files", symbolName: "folder", action: .openURL(URL(string: "file:///tmp")!))
        let odd = MenuBarWidget(name: "Odd", symbolName: "definitely.not.a.symbol.name", action: .toggleBar)
        let (model, recorder) = Self.makeModel(widgets: [dashboard, calculator, files, odd])
        let hosting = Self.host(model)
        let elements = settingsTestAccessibility(hosting.view)
        let identifiers = elements.compactMap { $0.accessibilityIdentifier() }
        #expect(identifiers.contains("settings-widget-list"))
        #expect(!identifiers.contains("settings-widget-empty"))
        for widget in [dashboard, calculator, files, odd] {
            for prefix in ["settings-widget-row-", "settings-widget-symbol-", "settings-widget-name-",
                           "settings-widget-action-", "settings-widget-edit-", "settings-widget-delete-"] {
                #expect(identifiers.contains("\(prefix)\(widget.id)"), "\(prefix)\(widget.id) must be present")
            }
            #expect(!identifiers.contains("settings-widget-confirm-delete-\(widget.id)"))
        }
        #expect(settingsTestAccessibilityText(try element("settings-widget-name-\(dashboard.id)", in: hosting.view)) == "Dashboard")
        #expect(settingsTestAccessibilityText(try element("settings-widget-action-\(dashboard.id)", in: hosting.view)) == "Open https://example.com")
        let calcAction = settingsTestAccessibilityText(try element("settings-widget-action-\(calculator.id)", in: hosting.view))
        #expect(calcAction.hasPrefix("Launch "))
        #expect(calcAction.contains("com.apple.calculator"))
        #expect(settingsTestAccessibilityText(try element("settings-widget-action-\(odd.id)", in: hosting.view)) == "Toggle the hidden bar")

        #expect(try element("settings-widget-symbol-\(dashboard.id)", in: hosting.view).accessibilityLabel() == "Symbol gauge")
        #expect(try element("settings-widget-symbol-\(odd.id)", in: hosting.view).accessibilityLabel() == "Placeholder symbol")

        let problem = try element("settings-widget-problem-\(files.id)", in: hosting.view)
        #expect(settingsTestAccessibilityText(problem).contains(WidgetLibrary.ValidationProblem.unsupportedURLScheme.message))
        #expect(!identifiers.contains("settings-widget-problem-\(dashboard.id)"))
        #expect(!identifiers.contains("settings-widget-problem-\(calculator.id)"))
        #expect(recorder.writes.isEmpty)
        #expect(!hosting.testWindow.isVisible)
    }

    // MARK: - Add

    @Test func addingAWidgetValidatesLiveAndWritesPreferencesOnce() async throws {
        let (model, recorder) = Self.makeModel()
        let hosting = Self.host(model)
        let window = hosting.testWindow!
        #expect(try element("settings-widget-add", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-name", in: hosting.view) != nil })
        let identifiers = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        for identifier in [
            "settings-widget-editor", "settings-widget-editor-name", "settings-widget-editor-symbol",
            "settings-widget-editor-symbol-preview", "settings-widget-editor-kind", "settings-widget-editor-url",
            "settings-widget-editor-cancel", "settings-widget-editor-save"
        ] {
            #expect(identifiers.contains(identifier), "\(identifier) must be present")
        }
        #expect(!identifiers.contains("settings-widget-list"))
        #expect(!identifiers.contains("settings-widget-footer"))
        #expect(!identifiers.contains("settings-widget-editor-bundle"))
        #expect(!identifiers.contains("settings-widget-editor-shortcut"))
        // An untouched form shows no error yet; the disabled button is the only hint.
        #expect(!identifiers.contains("settings-widget-editor-error"))
        #expect(!identifiers.contains("settings-widget-editor-symbol-hint"))
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())
        #expect(try element("settings-widget-editor-save", in: hosting.view).accessibilityLabel() == "Add Widget")
        #expect(try element("settings-widget-editor-symbol-preview", in: hosting.view).accessibilityLabel() == "Symbol star")
        #expect(radio("Open a link", in: hosting.view)?.accessibilityValue() as? Int == 1)

        // A name alone is not enough: the link is still missing, but an empty link is not shown as an error.
        var editor = try type("  Dashboard ", into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { field(labelled: "Widget name", in: hosting.view)?.stringValue == "  Dashboard " })
        #expect(find("settings-widget-editor-error", in: hosting.view) == nil)
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())
        #expect(window.makeFirstResponder(nil))

        // A link without an allowed scheme is refused live with the reason.
        editor = try type("example.com", into: requireField(labelled: "Link", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-error", in: hosting.view) != nil })
        #expect(settingsTestAccessibilityText(try element("settings-widget-editor-error", in: hosting.view))
                == WidgetLibrary.ValidationProblem.unsupportedURLScheme.message)
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())
        editor.insertNewline(nil)
        hosting.render()
        #expect(recorder.writes.isEmpty)
        #expect(model.preferences.widgets.isEmpty)

        editor = try type("https://example.com", into: requireField(labelled: "Link", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) {
            find("settings-widget-editor-error", in: hosting.view) == nil
                && find("settings-widget-editor-save", in: hosting.view)?.isAccessibilityEnabled() == true
        })
        #expect(recorder.writes.isEmpty)
        #expect(window.makeFirstResponder(nil))

        #expect(try element("settings-widget-editor-save", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { recorder.writes.count == 1 && model.preferences.widgets.count == 1 })
        let widget = try #require(model.preferences.widgets.first)
        #expect(widget.name == "Dashboard")
        #expect(widget.symbolName == WidgetLibrary.defaultSymbolName)
        #expect(widget.action == .openURL(Self.site))
        #expect(recorder.writes.first?.widgets == [widget])
        #expect(recorder.writes.first?.itemControls == ItemControlStore())

        // The editor closes and the saved widget renders as a row.
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-name-\(widget.id)", in: hosting.view) != nil })
        #expect(find("settings-widget-editor", in: hosting.view) == nil)
        #expect(settingsTestAccessibilityText(try element("settings-widget-action-\(widget.id)", in: hosting.view)) == "Open https://example.com")
        #expect(recorder.writes.count == 1)
        #expect(!window.isVisible)
    }

    @Test func switchingActionKindsShowsTheirFieldsAndKeepsTypedValues() async throws {
        var chooserCalls = 0
        var chooserResult: URL? = Self.calculator
        let (model, recorder) = Self.makeModel()
        let hosting = Self.host(model, chooseApp: { chooserCalls += 1; return chooserResult })
        let window = hosting.testWindow!
        #expect(try element("settings-widget-add", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-name", in: hosting.view) != nil })
        _ = try type("Calc", into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { field(labelled: "Widget name", in: hosting.view)?.stringValue == "Calc" })
        #expect(window.makeFirstResponder(nil))

        // Launch an app: the link field leaves, the app field and chooser arrive.
        #expect(try #require(radio("Launch an app", in: hosting.view)).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            find("settings-widget-editor-bundle", in: hosting.view) != nil && find("settings-widget-editor-url", in: hosting.view) == nil
        })
        #expect(radio("Launch an app", in: hosting.view)?.accessibilityValue() as? Int == 1)
        #expect(find("settings-widget-editor-error", in: hosting.view) == nil)
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())

        // Cancelling the panel changes nothing; choosing an app fills in its bundle identifier.
        chooserResult = nil
        #expect(try element("settings-widget-editor-choose-app", in: hosting.view).accessibilityPerformPress())
        hosting.render()
        #expect(chooserCalls == 1)
        #expect(field(labelled: "App bundle identifier", in: hosting.view)?.stringValue == "")
        chooserResult = URL(fileURLWithPath: "/System/Library")
        #expect(try element("settings-widget-editor-choose-app", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-choose-app-error", in: hosting.view) != nil })
        #expect(chooserCalls == 2)
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())
        chooserResult = Self.calculator
        #expect(try element("settings-widget-editor-choose-app", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            field(labelled: "App bundle identifier", in: hosting.view)?.stringValue == "com.apple.calculator"
                && find("settings-widget-editor-save", in: hosting.view)?.isAccessibilityEnabled() == true
        })
        #expect(chooserCalls == 3)
        #expect(find("settings-widget-editor-choose-app-error", in: hosting.view) == nil)
        #expect(settingsTestAccessibilityText(try element("settings-widget-editor-app-name", in: hosting.view)).contains("Calculator"))
        #expect(recorder.writes.isEmpty)

        // Run a Shortcut: its own field, empty and untouched, disables Save without shouting.
        #expect(try #require(radio("Run a Shortcut", in: hosting.view)).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-shortcut", in: hosting.view) != nil })
        #expect(find("settings-widget-editor-bundle", in: hosting.view) == nil)
        #expect(find("settings-widget-editor-error", in: hosting.view) == nil)
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())
        _ = try type("Start Focus", into: requireField(labelled: "Shortcut name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-save", in: hosting.view)?.isAccessibilityEnabled() == true })
        #expect(window.makeFirstResponder(nil))

        // Toggle the hidden bar needs nothing else.
        #expect(try #require(radio("Toggle the hidden bar", in: hosting.view)).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-toggle-note", in: hosting.view) != nil })
        #expect(find("settings-widget-editor-shortcut", in: hosting.view) == nil)
        #expect(try element("settings-widget-editor-save", in: hosting.view).isAccessibilityEnabled())

        // Returning to an earlier kind finds the value typed for it.
        #expect(try #require(radio("Launch an app", in: hosting.view)).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            field(labelled: "App bundle identifier", in: hosting.view)?.stringValue == "com.apple.calculator"
        })
        #expect(recorder.writes.isEmpty)
        #expect(try element("settings-widget-editor-save", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { recorder.writes.count == 1 })
        #expect(model.preferences.widgets.map(\.name) == ["Calc"])
        #expect(model.preferences.widgets.first?.action == .launchApp(bundleIdentifier: "com.apple.calculator"))
        #expect(chooserCalls == 3)
        #expect(!window.isVisible)
    }

    @Test func invalidNamesAndSymbolsDisableSaveWithAReasonAndAFullListBlocksAdding() async throws {
        let mail = MenuBarWidget(name: "Mail", symbolName: "envelope", action: .openURL(URL(string: "mailto:me@example.com")!))
        let (model, recorder) = Self.makeModel(widgets: [mail])
        let hosting = Self.host(model)
        let window = hosting.testWindow!
        #expect(try element("settings-widget-add", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-name", in: hosting.view) != nil })
        _ = try type("https://example.com", into: requireField(labelled: "Link", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { field(labelled: "Link", in: hosting.view)?.stringValue == "https://example.com" })
        #expect(window.makeFirstResponder(nil))

        // A case-insensitive duplicate name.
        _ = try type("mail", into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-error", in: hosting.view) != nil })
        #expect(settingsTestAccessibilityText(try element("settings-widget-editor-error", in: hosting.view))
                == WidgetLibrary.ValidationProblem.duplicateName.message)
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())

        // Too long.
        _ = try type(String(repeating: "n", count: 41), into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { errorText(in: hosting.view) == WidgetLibrary.ValidationProblem.nameTooLong.message })
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())

        // A valid name clears the error and enables Save.
        _ = try type("Site", into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) {
            find("settings-widget-editor-error", in: hosting.view) == nil
                && find("settings-widget-editor-save", in: hosting.view)?.isAccessibilityEnabled() == true
        })
        #expect(window.makeFirstResponder(nil))

        // A blank symbol is refused; an unknown one is allowed but previews the placeholder with a hint.
        _ = try type("", into: requireField(labelled: "SF Symbol name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-error", in: hosting.view) != nil })
        #expect(settingsTestAccessibilityText(try element("settings-widget-editor-error", in: hosting.view))
                == WidgetLibrary.ValidationProblem.emptySymbolName.message)
        #expect(find("settings-widget-editor-symbol-hint", in: hosting.view) != nil)
        #expect(try element("settings-widget-editor-symbol-preview", in: hosting.view).accessibilityLabel() == "Placeholder symbol")
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())
        _ = try type("definitely.not.a.symbol.name", into: requireField(labelled: "SF Symbol name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) {
            find("settings-widget-editor-error", in: hosting.view) == nil
                && find("settings-widget-editor-save", in: hosting.view)?.isAccessibilityEnabled() == true
        })
        let hint = try element("settings-widget-editor-symbol-hint", in: hosting.view)
        #expect(settingsTestAccessibilityText(hint).contains("placeholder"))
        #expect(try element("settings-widget-editor-symbol-preview", in: hosting.view).accessibilityLabel() == "Placeholder symbol")
        _ = try type("safari", into: requireField(labelled: "SF Symbol name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-symbol-hint", in: hosting.view) == nil })
        #expect(try element("settings-widget-editor-symbol-preview", in: hosting.view).accessibilityLabel() == "Symbol safari")
        #expect(window.makeFirstResponder(nil))

        // Cancel discards everything without a write.
        #expect(try element("settings-widget-editor-cancel", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor", in: hosting.view) == nil })
        #expect(recorder.writes.isEmpty)
        #expect(model.preferences.widgets == [mail])

        // A full list disables Add with the reason and offers no editor.
        let full = (0..<WidgetLibrary.maxWidgets).map { MenuBarWidget(name: "Widget \($0)", symbolName: "star", action: .toggleBar) }
        model.preferences.widgets = full
        #expect(recorder.writes.count == 1)
        let fullHosting = Self.host(model)
        let add = try element("settings-widget-add", in: fullHosting.view)
        #expect(!add.isAccessibilityEnabled())
        #expect(!add.accessibilityPerformPress())
        #expect(settingsTestAccessibilityText(try element("settings-widget-add-hint", in: fullHosting.view))
                == WidgetLibrary.ValidationProblem.tooManyWidgets.message)
        fullHosting.render()
        #expect(find("settings-widget-editor", in: fullHosting.view) == nil)
        #expect(try element("settings-widget-edit-\(full[11].id)", in: fullHosting.view).isAccessibilityEnabled())
        #expect(recorder.writes.count == 1)
        #expect(!fullHosting.testWindow.isVisible)
    }

    // MARK: - Edit and delete

    @Test func editingAWidgetPrefillsTheEditorAndWritesOnceKeepingItsIdentity() async throws {
        let dashboard = MenuBarWidget(name: "Dashboard", symbolName: "gauge", action: .openURL(Self.site))
        let focus = MenuBarWidget(name: "Focus", symbolName: "moon", action: .runShortcut(name: "Start Focus"))
        let (model, recorder) = Self.makeModel(widgets: [dashboard, focus])
        let hosting = Self.host(model)
        let window = hosting.testWindow!
        #expect(try element("settings-widget-edit-\(focus.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-shortcut", in: hosting.view) != nil })
        #expect(field(labelled: "Widget name", in: hosting.view)?.stringValue == "Focus")
        #expect(field(labelled: "SF Symbol name", in: hosting.view)?.stringValue == "moon")
        #expect(field(labelled: "Shortcut name", in: hosting.view)?.stringValue == "Start Focus")
        #expect(radio("Run a Shortcut", in: hosting.view)?.accessibilityValue() as? Int == 1)
        #expect(radio("Open a link", in: hosting.view)?.accessibilityValue() as? Int == 0)
        let save = try element("settings-widget-editor-save", in: hosting.view)
        #expect(save.accessibilityLabel() == "Save")
        #expect(save.isAccessibilityEnabled())
        #expect(find("settings-widget-editor-error", in: hosting.view) == nil)

        // Keeping its own name (re-cased) is allowed; taking the other widget's name is not.
        _ = try type("dashboard", into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-error", in: hosting.view) != nil })
        #expect(!(try element("settings-widget-editor-save", in: hosting.view)).isAccessibilityEnabled())
        _ = try type("FOCUS", into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) {
            find("settings-widget-editor-error", in: hosting.view) == nil
                && find("settings-widget-editor-save", in: hosting.view)?.isAccessibilityEnabled() == true
        })
        _ = try type("Deep Focus", into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { field(labelled: "Widget name", in: hosting.view)?.stringValue == "Deep Focus" })
        #expect(window.makeFirstResponder(nil))
        _ = try type("Deep Work", into: requireField(labelled: "Shortcut name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { field(labelled: "Shortcut name", in: hosting.view)?.stringValue == "Deep Work" })
        #expect(window.makeFirstResponder(nil))
        #expect(recorder.writes.isEmpty)

        #expect(try element("settings-widget-editor-save", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { recorder.writes.count == 1 })
        #expect(model.preferences.widgets.map(\.id) == [dashboard.id, focus.id])
        #expect(model.preferences.widgets[0] == dashboard)
        #expect(model.preferences.widgets[1].name == "Deep Focus")
        #expect(model.preferences.widgets[1].symbolName == "moon")
        #expect(model.preferences.widgets[1].action == .runShortcut(name: "Deep Work"))
        #expect(await waitForUpdate(hosting.view) {
            find("settings-widget-name-\(focus.id)", in: hosting.view).map(settingsTestAccessibilityText) == "Deep Focus"
        })
        #expect(find("settings-widget-editor", in: hosting.view) == nil)

        // Cancelling an edit writes nothing.
        #expect(try element("settings-widget-edit-\(dashboard.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-editor-url", in: hosting.view) != nil })
        #expect(field(labelled: "Link", in: hosting.view)?.stringValue == "https://example.com")
        _ = try type("Renamed", into: requireField(labelled: "Widget name", in: hosting.view), in: window)
        #expect(await waitForUpdate(hosting.view) { field(labelled: "Widget name", in: hosting.view)?.stringValue == "Renamed" })
        #expect(window.makeFirstResponder(nil))
        #expect(try element("settings-widget-editor-cancel", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-name-\(dashboard.id)", in: hosting.view) != nil })
        #expect(recorder.writes.count == 1)
        #expect(model.preferences.widgets[0] == dashboard)
        #expect(!window.isVisible)
    }

    @Test func deletingAWidgetNeedsConfirmationAndWritesOnce() async throws {
        let keep = MenuBarWidget(name: "Keep", symbolName: "star", action: .toggleBar)
        let doomed = MenuBarWidget(name: "Doomed", symbolName: "trash", action: .toggleBar)
        let (model, recorder) = Self.makeModel(widgets: [keep, doomed])
        let hosting = Self.host(model)
        #expect(find("settings-widget-confirm-delete-\(doomed.id)", in: hosting.view) == nil)

        #expect(try element("settings-widget-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-confirm-delete-\(doomed.id)", in: hosting.view) != nil })
        let prompt = try element("settings-widget-delete-prompt-\(doomed.id)", in: hosting.view)
        #expect(settingsTestAccessibilityText(prompt).contains("Delete \"Doomed\"?"))
        #expect(find("settings-widget-confirm-delete-\(keep.id)", in: hosting.view) == nil)
        #expect(find("settings-widget-edit-\(doomed.id)", in: hosting.view) == nil)
        #expect(recorder.writes.isEmpty)

        // Cancel restores the plain buttons without touching preferences.
        #expect(try element("settings-widget-cancel-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            find("settings-widget-confirm-delete-\(doomed.id)", in: hosting.view) == nil
                && find("settings-widget-delete-\(doomed.id)", in: hosting.view) != nil
        })
        #expect(model.preferences.widgets == [keep, doomed])
        #expect(recorder.writes.isEmpty)

        #expect(try element("settings-widget-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { find("settings-widget-confirm-delete-\(doomed.id)", in: hosting.view) != nil })
        #expect(try element("settings-widget-confirm-delete-\(doomed.id)", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            model.preferences.widgets == [keep] && find("settings-widget-row-\(doomed.id)", in: hosting.view) == nil
        })
        #expect(recorder.writes.count == 1)
        #expect(recorder.writes.first?.widgets == [keep])
        #expect(find("settings-widget-row-\(keep.id)", in: hosting.view) != nil)
        #expect(!hosting.testWindow.isVisible)
    }

    // MARK: - Layout

    @Test(arguments: WidgetAction.Kind.allCases)
    func editorFitsTheSettingsTabWithoutScrolling(kind: WidgetAction.Kind) throws {
        var draft = WidgetDraft(name: "A long widget name to exercise the row", kind: kind)
        draft.urlText = "https://example.com/a/rather/long/path?with=query&and=more"
        draft.bundleIdentifier = "com.apple.calculator"
        draft.shortcutName = "Start Focus"
        let hosting = settingsTestHost(WidgetEditor(
            draft: draft, existing: [], chooseApp: { nil }, onSave: { _ in }, onCancel: {}
        ).frame(width: 640, height: 600))
        let identifiers = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        #expect(identifiers.contains("settings-widget-editor-save"))
        #expect(identifiers.contains("settings-widget-editor-cancel"))
        #expect(identifiers.contains("settings-widget-editor-kind"))
        let parameter: String
        switch kind {
        case .openURL: parameter = "settings-widget-editor-url"
        case .launchApp: parameter = "settings-widget-editor-bundle"
        case .runShortcut: parameter = "settings-widget-editor-shortcut"
        case .toggleBar: parameter = "settings-widget-editor-toggle-note"
        }
        #expect(identifiers.contains(parameter))
        // The form's document is shorter than its viewport, so nothing needs scrolling to be reached.
        let scroll = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height <= scroll.contentView.bounds.height)
        #expect(document.frame.height > 200)
        #expect(hosting.view.fittingSize == CGSize(width: 640, height: 600))
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func appChooserReadsBundleIdentifiersAndNames() {
        #expect(WidgetAppChooser.bundleIdentifier(at: Self.calculator) == "com.apple.calculator")
        #expect(WidgetAppChooser.bundleIdentifier(at: URL(fileURLWithPath: "/System/Library")) == nil)
        #expect(WidgetAppChooser.bundleIdentifier(at: URL(fileURLWithPath: "/nonexistent/Nope.app")) == nil)
        #expect(WidgetAppChooser.displayName(forBundleIdentifier: "com.apple.calculator")?.isEmpty == false)
        #expect(WidgetAppChooser.displayName(forBundleIdentifier: "com.apple.calculator")?.hasSuffix(".app") == false)
        #expect(WidgetAppChooser.displayName(forBundleIdentifier: "com.example.definitely.missing") == nil)
        #expect(WidgetAppChooser.displayName(forBundleIdentifier: "  ") == nil)
        #expect(WidgetActionText.settingsText(for: .launchApp(bundleIdentifier: "com.example.definitely.missing"))
                == "Launch com.example.definitely.missing")
        #expect(WidgetActionText.settingsText(for: .toggleBar) == "Toggle the hidden bar")
    }

    // MARK: - Helpers

    private func find(_ identifier: String, in view: NSView) -> SettingsTestAXElement? {
        settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier }
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(find(identifier, in: view), "missing accessibility identifier \(identifier)")
    }

    /// The radio buttons carry no identifiers of their own; their option title is the stable handle.
    private func radio(_ title: String, in view: NSView) -> SettingsTestAXElement? {
        settingsTestAccessibility(view).first { $0.accessibilityRole() == .radioButton && $0.accessibilityLabel() == title }
    }

    /// Editable fields are told apart by the accessibility label the view assigns to each.
    private func field(labelled label: String, in view: NSView) -> NSTextField? {
        settingsTestSubviews(view).compactMap { $0 as? NSTextField }.first {
            $0.isEditable && ($0.accessibilityLabel() ?? "").contains(label)
        }
    }

    private func requireField(labelled label: String, in view: NSView) throws -> NSTextField {
        try #require(field(labelled: label, in: view), "missing editable field \(label)")
    }

    private func errorText(in view: NSView) -> String? {
        find("settings-widget-editor-error", in: view).map(settingsTestAccessibilityText)
    }

    /// The off-screen field editor drives the real SwiftUI bindings without posting keyboard events.
    private func type(_ text: String, into field: NSTextField, in window: NSWindow) throws -> NSTextView {
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.isFieldEditor)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        return editor
    }

    private func waitForUpdate(_ view: NSView, until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            (view as? NSHostingView<AnyView>)?._renderForTest(interval: 1.0 / 60)
            view.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while !Task.isCancelled && clock.now < deadline
        return false
    }
}

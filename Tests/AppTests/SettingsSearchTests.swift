import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SettingsSearchTests {
    private static let pages: [SettingsView.Tab] = [.general, .items, .style, .presets, .triggers, .groups, .widgets]

    @Test(arguments: [ColorScheme.light, .dark])
    func nativeSearchAndStyleRowFitInsideTheSidebar(scheme: ColorScheme) async throws {
        let test = Harness(scheme: scheme)
        let field = try await test.requireSearchField()
        try #require(await test.waitForUpdate { test.rows == Self.pages })
        let sidebar = try test.element("settings-sidebar").accessibilityFrame()
        let fieldFrame = test.window.convertToScreen(field.convert(field.bounds, to: nil))

        #expect(field.window === test.window)
        #expect(field.isEnabled)
        #expect(field.isEditable)
        #expect(!field.isHiddenOrHasHiddenAncestor)
        #expect(field.alphaValue > 0)
        #expect(!fieldFrame.isEmpty)
        #expect(field.visibleRect.contains(field.bounds))
        #expect(sidebar.contains(fieldFrame))
        #expect(test.window.frame.contains(fieldFrame))
        #expect(field.stringValue.isEmpty)
        #expect(field.maximumRecents == 0)
        for tab in Self.pages {
            let row = try test.element("settings-sidebar-\(tab.rawValue)")
            #expect(!row.accessibilityFrame().isEmpty)
            #expect(sidebar.contains(row.accessibilityFrame()))
            #expect(row.accessibilityLabel() == tab.title)
        }
        let items = try test.element("settings-sidebar-items").accessibilityFrame()
        let style = try test.element("settings-sidebar-style").accessibilityFrame()
        #expect(style.maxY <= items.minY)
        #expect(test.rows == Self.pages, "Row order must come from rendered geometry, not enum iteration.")
        test.expectUnchanged()
    }

    @Test(arguments: [("hover", SettingsView.Tab.general), ("opacity", .style)], [false, true])
    func typingOnlyFiltersUntilAResultIsSelected(match: (String, SettingsView.Tab), throughTable: Bool) async throws {
        let (query, target) = match
        var preferences = Preferences.default
        preferences.autoRehide = false
        preferences.itemControls.setHidden(true, forKey: "Saved item")
        preferences.itemAliases.setAlias("Saved alias", forKey: "Saved item")
        let test = Harness(preferences: preferences)
        try await test.type(query)
        try #require(await test.waitForUpdate { test.rows == [target] })

        #expect(test.searchField?.stringValue == query)
        #expect(test.title == "Presets")
        #expect(test.find("settings-preset-content") != nil)
        #expect(test.find("settings-layout-mode-picker") == nil)
        #expect(test.find("settings-style-enabled") == nil)
        #expect(test.find("settings-search-empty") == nil)
        test.expectUnchanged()

        let identifier = "settings-sidebar-\(target.rawValue)"
        if throughTable {
            let table = try #require(settingsTestSubviews(test.hosting.view).compactMap { $0 as? NSTableView }.first {
                settingsTestAccessibility($0).contains { $0.accessibilityIdentifier() == identifier }
            }, "The filtered sidebar must expose its native List table.")
            try #require(table.numberOfRows == 1)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            #expect(try test.element(identifier).accessibilityPerformPress())
        }
        try #require(await test.waitForUpdate {
            test.title == target.title && test.queryIsEmpty && test.rows == Self.pages
                && test.find("settings-preset-content") == nil
        })
        let marker = target == .general ? "settings-layout-mode-picker" : "settings-style-enabled"
        #expect(test.find(marker) != nil)
        if target == .general {
            // General's existing shortcut section loads Items once, but only after navigation.
            try #require(await test.waitForUpdate { !test.model.itemsLoading })
        }
        test.expectUnchanged(reads: target == .general ? 1 : 0)
    }

    @Test func returnSelectsTheFirstRankedResultAndClearsTheField() async throws {
        let test = Harness()
        let editor = try await test.type("style")
        try #require(await test.waitForUpdate { test.rows == [.style, .general] })
        #expect(test.title == "Presets")
        test.expectUnchanged()

        // Dispatch through the field editor's delegate, as keyboard commands do.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try #require(await test.waitForUpdate {
            test.title == "Style" && test.queryIsEmpty && test.rows == Self.pages
        })
        #expect(test.find("settings-style-enabled") != nil)
        #expect(test.find("settings-preset-content") == nil)
        #expect(test.find("settings-layout-mode-picker") == nil)
        test.expectUnchanged()
    }

    @Test func activatingTheCurrentPaneResultClearsSearchWithoutReloadingIt() async throws {
        let test = Harness(initialTab: .general)
        try #require(await test.waitForUpdate { !test.model.itemsLoading })
        try await test.type("hover")
        try #require(await test.waitForUpdate { test.rows == [.general] })
        let result = try test.element("settings-sidebar-general")
        #expect(result.accessibilityRole() == .button)
        #expect(test.title == "General")

        #expect(result.accessibilityPerformPress())

        try #require(await test.waitForUpdate { test.queryIsEmpty && test.rows == Self.pages })
        #expect(test.title == "General")
        test.expectUnchanged(reads: 1)
    }

    @Test func returnUsesTheLatestEditWithoutWaitingForSwiftUIToRender() async throws {
        let test = Harness()
        let editor = try await test.type("hover")
        try #require(await test.waitForUpdate { test.rows == [.general] })

        editor.insertText("opacity", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        try #require(await test.waitForUpdate {
            test.title == "Style" && test.queryIsEmpty && test.rows == Self.pages
        })
        test.expectUnchanged()
    }

    @Test func renderingPreservesMarkedTextAndCommandsBelongToTheInputMethod() async throws {
        let test = Harness()
        let editor = try await test.type("")
        let field = try await test.requireSearchField()
        editor.setMarkedText("opacity", selectedRange: NSRange(location: 7, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        try #require(editor.hasMarkedText())
        test.hosting.render()
        await Task.yield()
        test.hosting.render()
        #expect(editor.hasMarkedText())
        #expect(editor.string == "opacity")
        for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(field.delegate?.control?(field, textView: editor, doCommandBy: command) == false)
            #expect(editor.hasMarkedText())
            #expect(test.title == "Presets")
        }

        editor.insertText("opacity", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try #require(await test.waitForUpdate { test.rows == [.style] })
        #expect(!editor.hasMarkedText())
        #expect(test.title == "Presets")
        test.expectUnchanged()
    }

    @Test(arguments: ["", "no-such-setting"])
    func emptyOrUnmatchedReturnDoesNotNavigateAndClearingRestoresAllPages(query: String) async throws {
        let test = Harness()
        let editor = try await test.type(query)
        let expectedRows = query.isEmpty ? Self.pages : []
        try #require(await test.waitForUpdate {
            test.rows == expectedRows && (test.find("settings-search-empty") != nil) == !query.isEmpty
        })
        if !query.isEmpty {
            let empty = try test.element("settings-search-empty")
            #expect(settingsTestAccessibilityText(empty).contains("No matching settings"))
            #expect(!empty.accessibilityFrame().isEmpty)
            #expect(try test.element("settings-sidebar").accessibilityFrame().contains(empty.accessibilityFrame()))
        }

        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try #require(await test.waitForUpdate {
            test.title == "Presets" && test.rows == expectedRows && test.searchField?.stringValue == query
        }, "Return without a query or a matching page must not navigate.")
        #expect(test.find("settings-preset-content") != nil)
        #expect((test.find("settings-search-empty") != nil) == !query.isEmpty)
        test.expectUnchanged()

        try await test.type("")
        try #require(await test.waitForUpdate {
            test.queryIsEmpty && test.rows == Self.pages && test.find("settings-search-empty") == nil
        })
        #expect(test.title == "Presets")
        #expect(test.find("settings-preset-content") != nil)
        test.expectUnchanged()
    }

    @Test(arguments: [SettingsView.Tab.presets, .style])
    func externalTabRequestsClearSearchEvenForTheCurrentPane(target: SettingsView.Tab) async throws {
        let test = Harness()
        try await test.type("hover")
        try #require(await test.waitForUpdate { test.rows == [.general] })
        #expect(test.title == "Presets")
        test.expectUnchanged()

        test.model.requestedTab = target
        try #require(await test.waitForUpdate {
            test.model.requestedTab == nil && test.title == target.title
                && test.queryIsEmpty && test.rows == Self.pages
        })
        #expect(test.find(target == .presets ? "settings-preset-content" : "settings-style-enabled") != nil)
        #expect(test.find("settings-search-empty") == nil)
        test.expectUnchanged()
    }

    @Test func everySearchEditKeepsItemsMountedWithoutReloadingOrChangingTheDraft() async throws {
        let items = [
            settingsTestItem(1, alias: "Clipboard", observedHidden: false),
            settingsTestItem(2, alias: "Calendar", observedHidden: true)
        ]
        var preferences = Preferences.default
        preferences.itemControls.setHidden(true, for: items[1].snapshot)
        for item in items { preferences.itemAliases.setAlias(item.displayName, for: item.snapshot) }
        let test = Harness(initialTab: .items, preferences: preferences, items: items)
        try #require(await test.waitForUpdate {
            !test.model.itemsLoading && test.model.loadedItems.count == 2 && test.find("settings-items-list") != nil
        })
        test.model.setPlacement(.hidden, for: items[0])
        test.model.setPlacement(.shown, for: items[1])
        try #require(await test.waitForUpdate {
            test.find("settings-item-pending-1") != nil && test.find("settings-item-pending-2") != nil
        })
        test.expectUnchanged(reads: 1)

        for query in [
            "h", "ho", "hov", "hove", "hover", "", "o", "op", "opa", "opac", "opaci", "opacit", "opacity", "no-such-setting", ""
        ] {
            try await test.type(query)
            try #require(await test.waitForUpdate {
                test.searchField?.stringValue == query && test.rows == SettingsView.Tab.matching(query)
            }, "The native search binding must update for \(query.debugDescription).")
            #expect(test.title == "Items")
            #expect(test.find("settings-items-content") != nil)
            #expect(test.find("settings-items-list") != nil)
            #expect(!test.model.itemsLoading)
            #expect(test.model.itemsLoadError == nil)
            #expect(test.model.loadedItems.map(\.snapshot) == items.map(\.snapshot))
            #expect(test.model.loadedItems.map(\.alias) == items.map(\.alias))
            #expect(test.model.loadedItems.map(\.observedPlacement) == items.map(\.observedPlacement))
            #expect(test.model.loadedItems.map(\.isDisabled) == items.map(\.isDisabled))
            #expect(zip(test.model.loadedItems, items).allSatisfy { $0.0.image === $0.1.image })
            #expect(test.model.pendingChangeCount == 2)
            #expect(test.model.hasPendingChange(for: items[0]))
            #expect(test.model.hasPendingChange(for: items[1]))
            #expect(test.model.placement(of: items[0]) == .hidden)
            #expect(test.model.placement(of: items[1]) == .shown)
            #expect(try test.element("settings-placement-apply").isAccessibilityEnabled())
            #expect(settingsTestAccessibilityText(try test.element("settings-preview-phase")).contains("After Apply"))
            #expect(!test.model.placementInProgress)
            test.expectUnchanged(reads: 1)
        }
    }

    @Test(arguments: [false, true])
    func nativeCancelButtonOrEscapeClearsSearchWithoutNavigating(useEscape: Bool) async throws {
        let test = Harness()
        let editor = try await test.type("opacity")
        try #require(await test.waitForUpdate { test.rows == [.style] })
        let field = try await test.requireSearchField()
        let cancel = try #require((field.cell as? NSSearchFieldCell)?.cancelButtonCell,
                                 "The native search field must expose its clear/cancel cell.")
        #expect(!field.cancelButtonBounds.isEmpty)
        #expect(cancel.isEnabled)
        if useEscape {
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        } else {
            cancel.performClick(field)
        }

        try #require(await test.waitForUpdate { test.queryIsEmpty && test.rows == Self.pages })
        #expect(test.title == "Presets")
        #expect(test.find("settings-preset-content") != nil)
        #expect(test.find("settings-search-empty") == nil)
        test.expectUnchanged()
    }

    @MainActor
    private final class Activity {
        var reads = 0
        var writes: [Preferences] = []
        var retries = 0
    }

    @MainActor
    private struct Harness {
        let model: SettingsModel
        let hosting: SettingsTestHostingController
        let activity: Activity
        let loginItem: SettingsTestLoginItem
        let initialPreferences: Preferences
        var window: NSWindow { hosting.testWindow }

        // Presets has an editable field but no Items load, exposing an incorrect search-field
        // lookup or eager pane mounting without installing any native placement dependencies.
        init(
            initialTab: SettingsView.Tab = .presets, preferences: Preferences = .default,
            items: [FloatingBarItem] = [], scheme: ColorScheme = .light
        ) {
            let activity = Activity()
            let loginItem = SettingsTestLoginItem()
            let model = SettingsModel(
                preferences: preferences, loginItem: loginItem,
                itemsProvider: { activity.reads += 1; return items },
                onRetryPlacement: { activity.retries += 1 }, onChange: { activity.writes.append($0) }
            )
            self.activity = activity
            self.loginItem = loginItem
            self.initialPreferences = preferences
            self.model = model
            self.hosting = settingsTestHost(SettingsView(model: model, initialTab: initialTab).environment(\.colorScheme, scheme))
            hosting.view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            hosting.testWindow.appearance = hosting.view.appearance
            hosting.render()
        }

        var searchField: NSSearchField? {
            // Sidebar search can be hosted outside the SwiftUI root, in the window's chrome.
            let root = window.contentView?.superview ?? hosting.view
            return settingsTestSubviews(root).compactMap { $0 as? NSSearchField }.first {
                $0.placeholderString == "Search Settings" || $0.placeholderAttributedString?.string == "Search Settings"
            }
        }

        var queryIsEmpty: Bool {
            guard let field = searchField else { return false }
            return field.stringValue.isEmpty && (field.currentEditor()?.string.isEmpty ?? true)
        }

        var title: String? { find("settings-detail-title")?.accessibilityLabel() }

        var rows: [SettingsView.Tab] {
            let elements = settingsTestAccessibility(hosting.view)
            return SettingsView.Tab.allCases.compactMap { tab -> (SettingsView.Tab, CGRect)? in
                guard let row = elements.first(where: { $0.accessibilityIdentifier() == "settings-sidebar-\(tab.rawValue)" }) else {
                    return nil
                }
                return (tab, row.accessibilityFrame())
            }.sorted { $0.1.midY > $1.1.midY }.map { $0.0 }
        }

        func find(_ identifier: String) -> SettingsTestAXElement? {
            settingsTestAccessibility(hosting.view).first { $0.accessibilityIdentifier() == identifier }
        }

        func element(_ identifier: String) throws -> SettingsTestAXElement {
            try #require(find(identifier), "Missing Settings accessibility identifier \(identifier).")
        }

        func requireSearchField() async throws -> NSSearchField {
            try #require(await waitForUpdate { searchField != nil },
                         "Missing NSSearchField with prompt 'Search Settings' in the off-screen hosting view or window hierarchy.")
            return try #require(searchField)
        }

        @discardableResult
        func type(_ text: String) async throws -> NSTextView {
            let field = try await requireSearchField()
            try #require(window.makeFirstResponder(field), "The off-screen search field must accept focus.")
            let editor = try #require(field.currentEditor() as? NSTextView, "The native search field must provide a field editor.")
            #expect(editor.isFieldEditor)
            // The field editor exercises SwiftUI's real binding without posting keyboard events.
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            return editor
        }

        func waitForUpdate(until condition: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            repeat {
                hosting.render()
                // Yield before assertions so a mistakenly remounted pane's task can be observed.
                try? await Task.sleep(for: .milliseconds(10))
                hosting.render()
                if condition() { return true }
            } while !Task.isCancelled && clock.now < deadline
            return false
        }

        func expectUnchanged(reads: Int = 0) {
            #expect(model.preferences == initialPreferences)
            #expect(activity.writes.isEmpty)
            #expect(activity.retries == 0)
            #expect(activity.reads == reads)
            #expect(loginItem.setEnabledCalls.isEmpty)
            #expect(loginItem.openSystemSettingsCalls == 0)
            #expect(!window.isVisible)
            #expect(!window.isKeyWindow)
        }
    }
}

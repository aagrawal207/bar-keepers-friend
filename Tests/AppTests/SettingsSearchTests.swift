import Accessibility
import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SettingsSearchTests {
    private static let pages: [SettingsView.Tab] = SettingsView.Tab.allCases

    @Test(arguments: [ColorScheme.light, .dark])
    func nativeSearchAndStyleRowFitInsideTheSidebar(scheme: ColorScheme) async throws {
        let test = try Harness(scheme: scheme)
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

    @Test(arguments: [("hover", SettingsView.Tab.behavior), ("opacity", .style)], [false, true])
    func typingOnlyFiltersUntilAResultIsSelected(match: (String, SettingsView.Tab), throughTable: Bool) async throws {
        let (query, target) = match
        var preferences = Preferences.default
        preferences.autoRehide = false
        preferences.itemControls.setHidden(true, forKey: "Saved item")
        preferences.itemAliases.setAlias("Saved alias", forKey: "Saved item")
        let test = try Harness(preferences: preferences)
        try await test.type(query)
        try #require(await test.waitForUpdate { test.rows == [target] })

        #expect(test.searchField?.stringValue == query)
        #expect(test.title == "Presets")
        #expect(test.find("settings-preset-content") != nil)
        #expect(test.find("settings-behavior-content") == nil)
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
        let marker = target == .behavior ? "settings-behavior-content" : "settings-style-enabled"
        #expect(test.find(marker) != nil)
        #expect(test.isHighlighted(target == .behavior ? "settings-reveal-hover" : "settings-style-enabled"))
        // Filtering and visiting these panes must not request menu-bar items.
        test.expectUnchanged()
    }

    @Test func returnSelectsTheFirstRankedResultAndClearsTheField() async throws {
        let test = try Harness()
        let editor = try await test.type("style")
        try #require(await test.waitForUpdate { test.rows == [.style, .behavior] })
        #expect(test.title == "Presets")
        test.expectUnchanged()

        // Dispatch through the field editor's delegate, as keyboard commands do.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try #require(await test.waitForUpdate {
            test.title == "Style" && test.queryIsEmpty && test.rows == Self.pages
        })
        #expect(test.find("settings-style-enabled") != nil)
        #expect(test.find("settings-preset-content") == nil)
        #expect(test.find("settings-behavior-content") == nil)
        #expect(test.isHighlighted("settings-detail-title"))
        test.expectUnchanged()
    }

    @Test func activatingTheCurrentPaneResultClearsSearchWithoutReloadingIt() async throws {
        let test = try Harness(initialTab: .shortcuts)
        try #require(await test.waitForUpdate { !test.model.itemsLoading })
        try await test.type("hotkey")
        try #require(await test.waitForUpdate { test.rows == [.shortcuts] })
        let result = try test.element("settings-sidebar-shortcuts")
        #expect(result.accessibilityRole() == .button)
        #expect(test.title == "Shortcuts")

        #expect(result.accessibilityPerformPress())

        try #require(await test.waitForUpdate { test.queryIsEmpty && test.rows == Self.pages })
        #expect(test.title == "Shortcuts")
        // Re-activating the mounted pane must not remount it and read the menu bar a second time.
        #expect(test.isHighlighted("settings-shortcut-toggle-enabled"))
        test.expectUnchanged(reads: 1)
    }

    @Test func returnUsesTheLatestEditWithoutWaitingForSwiftUIToRender() async throws {
        let test = try Harness()
        let editor = try await test.type("hover")
        try #require(await test.waitForUpdate { test.rows == [.behavior] })

        editor.insertText("opacity", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

        try #require(await test.waitForUpdate {
            test.title == "Style" && test.queryIsEmpty && test.rows == Self.pages
        })
        #expect(test.isHighlighted("settings-style-enabled"))
        test.expectUnchanged()
    }

    @Test func renderingPreservesMarkedTextAndCommandsBelongToTheInputMethod() async throws {
        let test = try Harness()
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
        #expect(!test.hasHighlights)
        test.expectUnchanged()
    }

    @Test(arguments: ["", "no-such-setting"])
    func emptyOrUnmatchedReturnDoesNotNavigateAndClearingRestoresAllPages(query: String) async throws {
        let test = try Harness()
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
        let test = try Harness()
        try await test.type("hover")
        try #require(await test.waitForUpdate { test.rows == [.behavior] })
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
        let test = try Harness(initialTab: .items, preferences: preferences, items: items)
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
        let test = try Harness()
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

    @Test func searchResultsHighlightTheirDestinationsAcrossEveryPaneWithoutApplyingAnything() async throws {
        var preferences = Preferences.default
        preferences.menuBarStyle = MenuBarStyle(isEnabled: true, borderWidth: 2, shape: .rounded)
        let item = settingsTestItem(1, alias: "Clipboard", observedHidden: false)
        preferences.itemAliases.setAlias("Clipboard", for: item.snapshot)
        let test = try Harness(preferences: preferences, items: [item])
        test.model.setPlacement(.hidden, for: item)
        let destinations: [(String, SettingsView.Tab, [String])] = [
            ("launch at login", .general, ["settings-launch-at-login"]),
            ("accessibility", .general, ["settings-permission-accessibility"]),
            ("screen recording", .general, ["settings-permission-screenRecording"]),
            ("spacing", .general, ["settings-spacing-enabled"]),
            ("export", .general, ["settings-backup-row"]),
            ("aliases", .items, ["settings-items-list-header"]),
            ("after apply", .items, ["settings-placement-preview"]),
            ("hide all", .items, ["settings-placement-bulk"]),
            ("apply changes", .items, ["settings-placement-actions"]),
            ("sunset", .style, ["settings-icons-row"]),
            ("styles", .style, ["settings-style-enabled"]),
            ("tint", .style, ["settings-style-tint"]),
            ("gradient", .style, ["settings-style-gradient-enabled"]),
            ("  Style OPÁCITY\n border\t", .style, ["settings-style-opacity-row", "settings-style-border-row"]),
            ("shape", .style, ["settings-style-shape"]),
            ("corner radius", .style, ["settings-style-corner-radius"]),
            ("shadow", .style, ["settings-style-shadow"]),
            ("reset style", .style, ["settings-style-reset"]),
            ("style preview", .style, ["settings-style-preview"]),
            ("style", .style, ["settings-detail-title"]),
            ("floating bar", .behavior, ["settings-floating-bar-enabled"]),
            ("horizontal strip", .behavior, ["settings-floating-bar-style"]),
            ("dismiss", .behavior, ["settings-dismiss-on-exit"]),
            ("re-hide after", .behavior, ["settings-auto-rehide"]),
            ("HóVeR", .behavior, ["settings-reveal-hover"]),
            ("scroll", .behavior, ["settings-reveal-scroll"]),
            ("notch", .behavior, ["settings-notch-picker"]),
            ("keyboard shortcut", .shortcuts, ["settings-shortcut-toggle-enabled"]),
            ("item shortcuts", .shortcuts, ["settings-shortcut-items-hint"]),
            ("profiles", .presets, ["settings-preset-header"]),
            ("save layout", .presets, ["settings-preset-save-row"]),
            ("low power", .triggers, ["settings-trigger-header"]),
            ("membership", .groups, ["settings-group-header"]),
            ("email", .widgets, ["settings-widget-header"])
        ]
        var reads = 0
        for (index, destination) in destinations.enumerated() {
            let (query, tab, identifiers) = destination
            let previousTitle = test.title
            let editor = try await test.type(query)
            try #require(await test.waitForUpdate { test.rows.contains(tab) && !test.hasHighlights })
            #expect(test.title == previousTitle, "Typing must keep the existing pane mounted.")
            if index.isMultiple(of: 2) {
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                #expect(try test.element("settings-sidebar-\(tab.rawValue)").accessibilityPerformPress())
            }
            if previousTitle != tab.title, [.items, .shortcuts, .groups].contains(tab) { reads += 1 }
            try #require(await test.waitForUpdate {
                test.title == tab.title && test.queryIsEmpty && identifiers.allSatisfy(test.isHighlighted)
                    && test.activity.reads == reads
            }, "Search \(query.debugDescription) must highlight \(identifiers). \(test.highlightDescription)")
            let detail = try test.element("settings-detail").accessibilityFrame()
            for id in identifiers {
                let frame = try test.element(id).accessibilityFrame()
                #expect(!frame.isEmpty && detail.contains(frame), "\(id) must be visible at the search destination.")
            }
            #expect(test.model.pendingChangeCount == 1)
            test.expectUnchanged(reads: reads)
        }
    }

    @Test func hiddenAndDisabledSearchControlsPointToReachableDestinations() async throws {
        var preferences = Preferences.default
        preferences.useFloatingBar = false
        preferences.autoRehide = false
        preferences.enableGlobalHotkey = false
        let test = try Harness(preferences: preferences)
        let destinations: [(String, String)] = [
            ("opacity", "settings-style-enabled"),
            ("horizontal strip", "settings-floating-bar-enabled"),
            ("hover", "settings-reveal-hover"),
            ("re-hide after", "settings-auto-rehide"),
            ("selection padding", "settings-spacing-enabled"),
            ("keyboard shortcut", "settings-shortcut-toggle-enabled")
        ]
        for (query, id) in destinations {
            try await test.submit(query)
            try #require(await test.waitForUpdate { test.queryIsEmpty && test.isHighlighted(id) })
            if query == "hover" {
                #expect(try !test.element(id).isAccessibilityEnabled())
                #expect(try !test.element(id).accessibilityPerformPress())
            }
            test.expectUnchanged(reads: query == "keyboard shortcut" ? 1 : 0)
        }

        // An explicit click may reveal the searched control; search itself must never enable it.
        try await test.submit("opacity")
        try #require(await test.waitForUpdate { test.isHighlighted("settings-style-enabled") })
        _ = try test.element("settings-style-enabled").accessibilityPerformPress()
        try #require(await test.waitForUpdate { test.isHighlighted("settings-style-opacity-row") })
        #expect(!test.isHighlighted("settings-style-enabled"))
        preferences.menuBarStyle.isEnabled = true
        #expect(test.store.load() == preferences)
        #expect(test.activity.writes == [preferences])
        #expect(test.activity.captures == 0)
        #expect(test.server.moveRequests.isEmpty)
    }

    @Test func repeatedHighlightsExpireIndependentlyAndNavigationClearsThemWithoutLosingDrafts() async throws {
        let item = settingsTestItem(1, observedHidden: false)
        let test = try Harness(initialTab: .items, items: [item])
        try #require(await test.waitForUpdate { !test.model.itemsLoading })
        test.model.setPlacement(.hidden, for: item)
        try await test.submit("apply changes")
        try #require(await test.waitForUpdate { test.isHighlighted("settings-placement-actions") }, "\(test.highlightDescription)")
        try await Task.sleep(for: .milliseconds(1600))
        try await test.submit("apply changes")
        try #require(await test.waitForUpdate { test.isHighlighted("settings-placement-actions") && test.queryIsEmpty })
        try await Task.sleep(for: .milliseconds(1600))
        test.hosting.render()
        #expect(test.isHighlighted("settings-placement-actions"), "The earlier highlight's timeout must not clear its replacement.")
        try #require(await test.waitForUpdate { !test.hasHighlights })
        test.expectUnchanged(reads: 1)

        try await test.submit("hover")
        try #require(await test.waitForUpdate { test.isHighlighted("settings-reveal-hover") })
        #expect(!test.isHighlighted("settings-reveal-scroll"))
        #expect(try test.element("settings-sidebar-style").accessibilityPerformPress())
        try #require(await test.waitForUpdate { test.title == "Style" && !test.hasHighlights })
        try await test.submit("opacity")
        try #require(await test.waitForUpdate { test.isHighlighted("settings-style-enabled") })
        test.model.requestedTab = .style
        try #require(await test.waitForUpdate { test.model.requestedTab == nil && !test.hasHighlights })
        try await test.submit("opacity")
        try #require(await test.waitForUpdate { test.isHighlighted("settings-style-enabled") })
        let editor = try await test.type("no-such-setting")
        try #require(await test.waitForUpdate { test.rows.isEmpty && !test.hasHighlights })
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        test.hosting.render()
        #expect(test.title == "Style")
        #expect(!test.hasHighlights)
        #expect(test.model.pendingChangeCount == 1)
        test.expectUnchanged(reads: 1)
    }

    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func highlightsPaintTheDestinationWithoutResizingOrDisablingIt(scheme: ColorScheme, reduceMotion: Bool) async throws {
        let test = try Harness(initialTab: .behavior, scheme: scheme, reduceMotion: reduceMotion)
        let editor = try await test.type("hover")
        try #require(await test.waitForUpdate { test.rows == [.behavior] && !test.hasHighlights })
        let frame = try test.element("settings-reveal-hover").accessibilityFrame()
        let baseline = try settingsTestBitmap(test.hosting.view)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try #require(await test.waitForUpdate { test.isHighlighted("settings-reveal-hover") && test.queryIsEmpty })
        try await Task.sleep(for: .milliseconds(250))
        test.hosting.render()
        let painted = try settingsTestBitmap(test.hosting.view)
        #expect(try test.element("settings-reveal-hover").accessibilityFrame() == frame)
        #expect(try changedPixels(baseline, painted, in: frame, test: test) > 30, "The search cue must paint pixels, not just accessibility metadata.")
        test.expectUnchanged()

        // Native checkboxes can return false after dispatch; the persisted value proves activation.
        _ = try test.element("settings-reveal-hover").accessibilityPerformPress()
        try #require(await test.waitForUpdate { test.model.preferences.revealOnHover })
        var expected = test.initialPreferences
        expected.revealOnHover = true
        #expect(test.store.load() == expected)
        #expect(test.activity.writes == [expected])
        #expect(test.activity.captures == 0)
        #expect(test.activity.dividerWrites.isEmpty)
        #expect(test.server.moveRequests.isEmpty)
    }

    private func changedPixels(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep, in screenRect: CGRect, test: Harness) throws -> Int {
        let view = test.hosting.view
        let rect = view.convert(test.window.convertFromScreen(screenRect), from: nil)
        let scale = CGFloat(after.pixelsWide) / view.bounds.width
        let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        let xs = max(0, Int(rect.minX * scale))..<min(after.pixelsWide, Int(rect.maxX * scale))
        let ys = max(0, Int(top * scale))..<min(after.pixelsHigh, Int((top + rect.height) * scale))
        var count = 0
        for y in ys {
            for x in xs {
                let a = try #require(before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try #require(after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let red = abs(a.redComponent - b.redComponent)
                let green = abs(a.greenComponent - b.greenComponent)
                let blue = abs(a.blueComponent - b.blueComponent)
                if red + green + blue > 0.15 { count += 1 }
            }
        }
        return count
    }

    @MainActor
    private final class Activity {
        var reads = 0
        var writes: [Preferences] = []
        var retries = 0
        var captures = 0
        var dividerWrites: [Bool] = []
    }

    @MainActor
    private final class Harness {
        let model: SettingsModel
        let hosting: SettingsTestHostingController
        let activity: Activity
        let loginItem: SettingsTestLoginItem
        let initialPreferences: Preferences
        let suite: String
        let defaults: UserDefaults
        let store: PreferencesStore
        let server: FakeWindowServer
        let engine: CosmeticHideEngine
        var window: NSWindow { hosting.testWindow }

        // Presets has an editable field but no Items load, exposing an incorrect search-field
        // lookup or eager pane mounting without installing any native placement dependencies.
        init(
            initialTab: SettingsView.Tab = .presets, preferences: Preferences = .default,
            items: [FloatingBarItem] = [], scheme: ColorScheme = .light, reduceMotion: Bool = false
        ) throws {
            let activity = Activity()
            let loginItem = SettingsTestLoginItem()
            suite = "SettingsSearchTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            let store = PreferencesStore(backing: defaults)
            store.save(preferences)
            let server = FakeWindowServer()
            let engine = CosmeticHideEngine(
                preferences: store.load(), controlWindowIDs: { (90, 91) },
                setDividerCollapsed: { activity.dividerWrites.append($0) }, onPreferencesChanged: { _ in }
            )
            engine.hiddenItemController = HiddenItemController(windowServer: server)
            engine.floatingBar = FloatingBarController(
                windowServer: server, captureIcons: { _ in activity.captures += 1; return [:] },
                preferences: preferences, attribute: { $0 }
            )
            let model = SettingsModel(
                preferences: store.load(), loginItem: loginItem,
                itemsProvider: { activity.reads += 1; return items },
                onRetryPlacement: { activity.retries += 1; engine.reconcileHiddenItems(userInitiated: true) },
                onChange: { updated in
                    activity.writes.append(updated)
                    store.save(updated)
                    engine.apply(preferences: updated)
                }
            )
            self.store = store
            self.server = server
            self.engine = engine
            self.activity = activity
            self.loginItem = loginItem
            self.initialPreferences = preferences
            self.model = model
            self.hosting = settingsTestHost(SettingsView(model: model, initialTab: initialTab)
                .environment(\.colorScheme, scheme).environment(\.settingsSearchReduceMotion, reduceMotion))
            hosting.view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            hosting.testWindow.appearance = hosting.view.appearance
            hosting.render()
        }

        isolated deinit {
            engine.uninstall()
            defaults.removePersistentDomain(forName: suite)
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

        func isHighlighted(_ identifier: String) -> Bool {
            guard let element = find(identifier) else { return false }
            return settingsTestAccessibility(element).contains(where: hasSearchMatch)
        }

        var hasHighlights: Bool {
            settingsTestAccessibility(hosting.view).contains(where: hasSearchMatch)
        }

        private func hasSearchMatch(_ element: SettingsTestAXElement) -> Bool {
            let content = element.property("accessibilityCustomContent") as? [AXCustomContent] ?? []
            return content.contains { $0.label == "Settings search" && $0.value == "Match" }
        }

        var highlightDescription: String {
            settingsTestAccessibility(hosting.view).compactMap { element in
                let id = element.accessibilityIdentifier() ?? element.accessibilityLabel() ?? "unnamed"
                guard id.hasPrefix("settings-") || element.accessibilityHelp() != nil else { return nil }
                return "\(id): \(element.accessibilityRole()?.rawValue ?? "nil") enabled=\(element.isAccessibilityEnabled()) matched=\(hasSearchMatch(element))"
            }.joined(separator: "\n")
        }

        func submit(_ query: String) async throws {
            let editor = try await type(query)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }

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
            #expect(store.load() == initialPreferences)
            #expect(activity.writes.isEmpty)
            #expect(activity.retries == 0)
            #expect(activity.reads == reads)
            #expect(activity.captures == 0)
            #expect(activity.dividerWrites.isEmpty)
            #expect(server.moveRequests.isEmpty)
            #expect(server.clickedWindowIDs.isEmpty)
            #expect(loginItem.setEnabledCalls.isEmpty)
            #expect(loginItem.openSystemSettingsCalls == 0)
            #expect(!window.isVisible)
            #expect(!window.isKeyWindow)
        }
    }
}

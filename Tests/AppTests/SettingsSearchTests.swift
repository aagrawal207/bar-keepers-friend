import Accessibility
import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SettingsSearchTests {
    private static let sidebarTabs = SettingsView.Tab.sidebarTabs

    @Test(arguments: [ColorScheme.light, .dark])
    func nativeSearchAndStyleRowFitInsideTheSidebar(scheme: ColorScheme) async throws {
        let test = try Harness(scheme: scheme)
        let field = try await test.requireSearchField()
        try #require(await test.waitForUpdate { test.rows == Self.sidebarTabs && test.selectedSidebarTabs == [.advanced] })
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
        for tab in Self.sidebarTabs {
            let row = try test.element("settings-sidebar-\(tab.rawValue)")
            #expect(!row.accessibilityFrame().isEmpty)
            #expect(sidebar.contains(row.accessibilityFrame()))
            #expect(row.accessibilityLabel() == tab.title)
        }
        let items = try test.element("settings-sidebar-items").accessibilityFrame()
        let style = try test.element("settings-sidebar-style").accessibilityFrame()
        #expect(style.maxY <= items.minY)
        #expect(test.rows == Self.sidebarTabs, "Row order must come from rendered geometry, not enum iteration.")
        for tab in SettingsView.Tab.advancedTabs {
            #expect(test.find("settings-sidebar-\(tab.rawValue)") == nil)
        }
        test.expectOnlyPane(.presets)
        test.expectUnchanged()
    }

    @Test(arguments: [false, true])
    func typingOnlyFiltersUntilAResultIsSelected(throughTable: Bool) async throws {
        var preferences = Preferences.default
        preferences.autoRehide = false
        preferences.itemControls.setHidden(true, forKey: "Saved item")
        preferences.itemAliases.setAlias("Saved alias", forKey: "Saved item")
        let destinations: [(String, SettingsView.Tab, String)] = [
            ("hover", .behavior, "settings-reveal-hover"),
            ("opacity", .style, "settings-style-enabled"),
            ("Advanced profiles", .presets, "settings-preset-header"),
            ("Advanced Wi-Fi", .triggers, "settings-trigger-header"),
            ("Advanced membership", .groups, "settings-group-header")
        ]
        for (query, target, highlight) in destinations {
            // Each child starts in General, so finding it cannot depend on mounting Advanced first.
            let initialTab: SettingsView.Tab = target.sidebarTab == .advanced ? .general : .presets
            let test = try Harness(initialTab: initialTab, preferences: preferences)
            try await test.type(query)
            try #require(await test.waitForUpdate { test.rows == [target] })

            #expect(test.searchField?.stringValue == query)
            test.expectOnlyPane(initialTab)
            #expect(test.find("settings-search-empty") == nil)
            #expect(!test.hasHighlights)
            test.expectUnchanged()

            if throughTable {
                let table = try #require(test.sidebarTable, "The filtered sidebar must expose its native List table.")
                try #require(table.numberOfRows == 1)
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            } else {
                #expect(try test.element("settings-sidebar-\(target.rawValue)").accessibilityPerformPress())
            }
            // Groups loads available members on entry; merely finding it in search must not read them.
            let reads = target == .groups ? 1 : 0
            try #require(await test.waitForUpdate {
                test.title == target.title && test.queryIsEmpty && test.rows == Self.sidebarTabs
                    && test.selectedSidebarTabs == [target.sidebarTab] && test.isHighlighted(highlight)
                    && test.activity.reads == reads && (target != .groups || !test.model.itemsLoading)
            })
            test.expectOnlyPane(target)
            test.expectUnchanged(reads: reads)
        }
    }

    @Test func returnSelectsTheFirstRankedResultAndClearsTheField() async throws {
        let destinations: [(String, [SettingsView.Tab], String)] = [
            ("style", [.style, .behavior], "settings-detail-title"),
            ("Advanced Triggers Wi-Fi", [.triggers], "settings-trigger-header")
        ]
        for (query, results, highlight) in destinations {
            let test = try Harness()
            let editor = try await test.type(query)
            try #require(await test.waitForUpdate { test.rows == results })
            test.expectOnlyPane(.presets)
            test.expectUnchanged()

            // Dispatch through the field editor's delegate, as keyboard commands do.
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            let target = try #require(results.first)
            try #require(await test.waitForUpdate {
                test.title == target.title && test.queryIsEmpty && test.rows == Self.sidebarTabs
                    && test.selectedSidebarTabs == [target.sidebarTab] && test.isHighlighted(highlight)
            })
            test.expectOnlyPane(target)
            test.expectUnchanged()
        }
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

        try #require(await test.waitForUpdate { test.queryIsEmpty && test.rows == Self.sidebarTabs })
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
            test.title == "Style" && test.queryIsEmpty && test.rows == Self.sidebarTabs
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
    func emptyOrUnmatchedReturnDoesNotNavigateAndClearingRestoresTheSidebar(query: String) async throws {
        let test = try Harness()
        let editor = try await test.type(query)
        let expectedRows = query.isEmpty ? Self.sidebarTabs : []
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
            test.queryIsEmpty && test.rows == Self.sidebarTabs && test.find("settings-search-empty") == nil
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
                && test.queryIsEmpty && test.rows == Self.sidebarTabs
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

        let removedWidgetQueries = [
            "widget", "widgets", "Open URL", "Launch app", "Run Shortcut", "Choose App",
            "email", "mailto", "https", "SF Symbol name"
        ]
        for query in [
            "h", "ho", "hov", "hove", "hover", "", "o", "op", "opa", "opac", "opaci", "opacit", "opacity", "no-such-setting", ""
        ] + removedWidgetQueries + [""] {
            let editor = try await test.type(query)
            try #require(await test.waitForUpdate {
                test.searchField?.stringValue == query && test.rows == SettingsView.Tab.matching(query)
            }, "The native search binding must update for \(query.debugDescription).")
            if removedWidgetQueries.contains(query) {
                #expect(test.rows.isEmpty, "Removed widget actions must not leave searchable destinations for \(query).")
                #expect(test.find("settings-search-empty") != nil)
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                try #require(await test.waitForUpdate { test.title == "Items" && test.searchField?.stringValue == query })
                #expect(!test.hasHighlights)
            }
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
        #expect(SettingsView.Tab.matching("Toggle bar") == [.shortcuts], "The supported toggle shortcut remains searchable.")
    }

    @Test(arguments: [false, true])
    func quickStartAdvancedToolsSearchAndAboutPreserveAnUnappliedDraft(hasSavedTools: Bool) async throws {
        let items = [
            settingsTestItem(1, alias: "Clipboard", observedHidden: false),
            settingsTestItem(2, alias: "Calendar", observedHidden: true)
        ]
        var preferences = Preferences.default
        preferences.itemControls.setHidden(false, for: items[0].snapshot)
        preferences.itemControls.setHidden(true, for: items[1].snapshot)
        for item in items { preferences.itemAliases.setAlias(item.displayName, for: item.snapshot) }
        preferences.appIcon = AppIconChoice(menuBarSymbol: .sparkle, appTheme: .forest)
        let preset = LayoutPreset(name: "Work", itemControls: preferences.itemControls)
        let rule = TriggerRule(name: "Battery work", conditions: [.onBattery], presetID: preset.id)
        let groupedOwner = try #require(ItemControlStore.key(for: items[1].snapshot))
        let group = ItemGroup(name: "Calendar tools", ownerKeys: [groupedOwner])
        if hasSavedTools {
            preferences.presets = [preset]
            preferences.triggers = [rule]
            preferences.itemGroups = [group]
        }
        let test = try Harness(initialTab: .general, preferences: preferences, items: items)
        try #require(await test.waitForUpdate { test.title == "General" && test.rows == Self.sidebarTabs })
        test.expectOnlyPane(.general)
        let arrange = try test.element("settings-open-items")
        #expect(arrange.accessibilityLabel() == "Arrange Items…")
        #expect(arrange.isAccessibilityEnabled())
        #expect(test.find("settings-spacing-enabled") == nil)
        #expect(test.find("settings-notch-picker") == nil)
        #expect(test.find("settings-backup-export") == nil)
        // Let the real permission/login polling task run; probing is not an item load or an edit.
        try await Task.sleep(for: .milliseconds(2100))
        test.hosting.render()
        test.expectUnchanged()

        #expect(try test.element("settings-open-items").accessibilityPerformPress())
        try #require(await test.waitForUpdate {
            test.title == "Items" && !test.model.itemsLoading && test.find("settings-items-list") != nil
        })
        test.expectOnlyPane(.items)
        test.expectUnchanged(reads: 1)
        #expect(try test.element("settings-placement-hide-all").accessibilityPerformPress())
        try #require(await test.waitForUpdate {
            test.model.pendingChangeCount == 1 && test.find("settings-item-pending-1") != nil
                && test.find("settings-placement-apply")?.isAccessibilityEnabled() == true
        })
        #expect(test.model.placement(of: items[0]) == .hidden)
        #expect(settingsTestAccessibilityText(try test.element("settings-preview-phase")).contains("After Apply"))
        test.expectUnchanged(reads: 1)

        #expect(try test.element("settings-sidebar-advanced").accessibilityPerformPress())
        try #require(await test.waitForUpdate {
            test.title == "Advanced" && test.selectedSidebarTabs == [.advanced]
                && test.find("settings-advanced-tools") != nil
        })
        test.expectOnlyPane(.advanced)
        for identifier in ["settings-spacing-enabled", "settings-notch-picker", "settings-backup-export"] {
            #expect(test.find(identifier) != nil)
        }
        try await Task.sleep(for: .milliseconds(2100))
        test.hosting.render()
        test.expectUnchanged(reads: 1)

        let children: [(SettingsView.Tab, String)] = [(.presets, "preset"), (.triggers, "trigger"), (.groups, "group")]
        var reads = 1
        for (child, prefix) in children {
            #expect(try test.element("settings-advanced-\(child.rawValue)").accessibilityPerformPress())
            // Even an empty Groups library needs a fresh list of available members.
            if child == .groups { reads += 1 }
            try #require(await test.waitForUpdate {
                test.title == child.title && test.selectedSidebarTabs == [.advanced]
                    && test.find("settings-\(prefix)-\(hasSavedTools ? "list" : "empty")") != nil
                    && test.activity.reads == reads && !test.model.itemsLoading
            })
            test.expectOnlyPane(child)
            #expect(!test.hasHighlights)
            #expect((test.find("settings-\(prefix)-empty") != nil) == !hasSavedTools)
            #expect((test.find("settings-\(prefix)-list") != nil) == hasSavedTools)
            let footer = try test.element("settings-\(prefix)-footer").accessibilityFrame()
            #expect(!footer.isEmpty)
            #expect(try test.element("settings-detail").accessibilityFrame().contains(footer))
            if hasSavedTools {
                switch child {
                case .presets:
                    #expect(test.find("settings-preset-active-\(preset.id)") != nil)
                case .triggers:
                    #expect(test.find("settings-trigger-enabled-\(rule.id)") != nil)
                    #expect(test.find("settings-trigger-editor") == nil)
                case .groups:
                    #expect(settingsTestAccessibilityText(try test.element("settings-group-count-\(group.id)")).contains("1 item"))
                    #expect(test.find("settings-group-member-\(group.id)-\(groupedOwner)") != nil)
                default:
                    Issue.record("Unexpected Advanced child \(child).")
                }
            }
            #expect(test.model.pendingChangeCount == 1)
            #expect(test.model.hasPendingChange(for: items[0]))
            test.expectUnchanged(reads: reads)

            let back = try test.element("settings-back-to-advanced")
            #expect(back.accessibilityLabel() == "Advanced")
            #expect(back.accessibilityPerformPress())
            try #require(await test.waitForUpdate { test.title == "Advanced" && test.find("settings-advanced-tools") != nil })
            test.expectOnlyPane(.advanced)
            test.expectUnchanged(reads: reads)
        }

        try await test.type("Advanced Wi-Fi")
        try #require(await test.waitForUpdate { test.rows == [.triggers] })
        test.expectOnlyPane(.advanced)
        #expect(!test.hasHighlights)
        #expect(try test.element("settings-sidebar-triggers").accessibilityPerformPress())
        try #require(await test.waitForUpdate {
            test.queryIsEmpty && test.isHighlighted("settings-trigger-header") && test.selectedSidebarTabs == [.advanced]
        })
        test.expectOnlyPane(.triggers)
        #expect(test.find("settings-trigger-editor") == nil)
        #expect(try test.element("settings-back-to-advanced").accessibilityPerformPress())
        try #require(await test.waitForUpdate { test.title == "Advanced" && !test.hasHighlights })
        test.expectOnlyPane(.advanced)

        try await test.submit("Advanced save layout")
        try #require(await test.waitForUpdate {
            test.queryIsEmpty && test.isHighlighted("settings-preset-save-row") && test.selectedSidebarTabs == [.advanced]
        })
        test.expectOnlyPane(.presets)
        #expect(try test.element("settings-sidebar-advanced").accessibilityPerformPress())
        try #require(await test.waitForUpdate { test.title == "Advanced" && !test.hasHighlights })
        test.expectOnlyPane(.advanced)
        #expect(test.model.pendingChangeCount == 1)
        test.expectUnchanged(reads: reads)

        try await test.submit("support")
        try #require(await test.waitForUpdate {
            test.queryIsEmpty && test.isHighlighted("settings-about-issues") && test.selectedSidebarTabs == [.about]
        })
        test.expectOnlyPane(.about)
        #expect(try test.element("settings-about-icon").accessibilityLabel() == "App icon, Forest theme")
        let version = AppInfo.displayVersion(
            short: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        #expect(settingsTestAccessibilityText(try test.element("settings-about-version")).contains("Version \(version)"))
        #expect(test.model.pendingChangeCount == 1)
        test.expectUnchanged(reads: reads)

        let links = [
            ("project", "settings-about-project", "https://github.com/aagrawal207/bar-keepers-friend"),
            ("support", "settings-about-issues", "https://github.com/aagrawal207/bar-keepers-friend/issues"),
            ("license", "settings-about-license", "https://github.com/aagrawal207/bar-keepers-friend/blob/main/LICENSE")
        ]
        var openedURLs: [String] = []
        for (query, identifier, url) in links {
            try await test.submit(query)
            try #require(await test.waitForUpdate { test.queryIsEmpty && test.isHighlighted(identifier) })
            test.expectOnlyPane(.about)
            // Searching for a link highlights it; only an explicit link press may request a URL.
            test.expectUnchanged(reads: reads, openedURLs: openedURLs)
            let link = try test.element(identifier)
            #expect(link.isAccessibilityEnabled())
            #expect(!link.accessibilityFrame().isEmpty)
            #expect(try test.element("settings-detail").accessibilityFrame().contains(link.accessibilityFrame()))
            #expect(link.accessibilityPerformPress())
            openedURLs.append(url)
            try #require(await test.waitForUpdate { test.activity.openedURLs.map(\.absoluteString) == openedURLs })
            #expect(test.model.pendingChangeCount == 1)
            #expect(test.model.hasPendingChange(for: items[0]))
            #expect(test.model.placement(of: items[0]) == .hidden)
            #expect(test.model.draftDiscardedNotice == nil)
            test.expectOnlyPane(.about)
            test.expectUnchanged(reads: reads, openedURLs: openedURLs)
        }

        #expect(try test.element("settings-sidebar-items").accessibilityPerformPress())
        reads += 1
        try #require(await test.waitForUpdate {
            test.title == "Items" && !test.model.itemsLoading && test.find("settings-item-pending-1") != nil
                && test.activity.reads == reads
        })
        #expect(!test.hasHighlights)
        #expect(try test.element("settings-placement-apply").isAccessibilityEnabled())
        #expect(test.model.pendingChangeCount == 1)
        #expect(test.model.placement(of: items[0]) == .hidden)
        #expect(test.model.loadedItems.map(\.snapshot) == items.map(\.snapshot))
        #expect(test.model.loadedItems.map(\.alias) == items.map(\.alias))
        test.expectUnchanged(reads: reads, openedURLs: openedURLs)
        #expect(try test.element("settings-sidebar-about").accessibilityPerformPress())
        try #require(await test.waitForUpdate { test.title == "About" && test.selectedSidebarTabs == [.about] })
        test.expectOnlyPane(.about)
        #expect(test.model.hasPendingChange(for: items[0]))
        #expect(test.model.draftDiscardedNotice == nil)
        test.expectUnchanged(reads: reads, openedURLs: openedURLs)
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

        try #require(await test.waitForUpdate { test.queryIsEmpty && test.rows == Self.sidebarTabs })
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
            ("get started", .general, ["settings-open-items"]),
            ("launch at login", .general, ["settings-launch-at-login"]),
            ("accessibility", .general, ["settings-permission-accessibility"]),
            ("screen recording", .general, ["settings-permission-screenRecording"]),
            ("advanced tools", .advanced, ["settings-advanced-tools"]),
            ("spacing", .advanced, ["settings-spacing-enabled"]),
            ("export", .advanced, ["settings-backup-row"]),
            ("notch", .advanced, ["settings-notch-picker"]),
            ("advanced", .advanced, ["settings-detail-title"]),
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
            ("keyboard shortcut", .shortcuts, ["settings-shortcut-toggle-enabled"]),
            ("item shortcuts", .shortcuts, ["settings-shortcut-items-hint"]),
            ("profiles", .presets, ["settings-preset-header"]),
            ("save layout", .presets, ["settings-preset-save-row"]),
            ("low power", .triggers, ["settings-trigger-header"]),
            ("membership", .groups, ["settings-group-header"]),
            ("version", .about, ["settings-about-version"]),
            ("project", .about, ["settings-about-project"]),
            ("support", .about, ["settings-about-issues"]),
            ("license", .about, ["settings-about-license"]),
            ("about", .about, ["settings-detail-title"])
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
            // Groups needs current members, just as Items and Shortcuts need current item choices.
            let loadsItems = [.items, .shortcuts, .groups].contains(tab)
            if previousTitle != tab.title, loadsItems { reads += 1 }
            try #require(await test.waitForUpdate {
                test.title == tab.title && test.queryIsEmpty && identifiers.allSatisfy(test.isHighlighted)
                    && test.activity.reads == reads && test.rows == Self.sidebarTabs
                    && test.selectedSidebarTabs == [tab.sidebarTab]
                    && (!loadsItems || !test.model.itemsLoading)
            }, "Search \(query.debugDescription) must highlight \(identifiers). \(test.highlightDescription)")
            test.expectOnlyPane(tab)
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
        var anchorImageWrites = 0
        var openedURLs: [URL] = []
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
        let initialEngineState: HideShowStateMachine
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
                setDividerCollapsed: { activity.dividerWrites.append($0) },
                setAnchorImage: { _ in activity.anchorImageWrites += 1 }, onPreferencesChanged: { _ in }
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
            model.onAccessibilityGranted = { engine.resumePendingPlacement() }
            self.store = store
            self.server = server
            self.engine = engine
            self.initialEngineState = engine.stateMachine
            self.activity = activity
            self.loginItem = loginItem
            self.initialPreferences = preferences
            self.model = model
            self.hosting = settingsTestHost(SettingsView(model: model, initialTab: initialTab)
                .environment(\.colorScheme, scheme).environment(\.settingsSearchReduceMotion, reduceMotion)
                .environment(\.openURL, OpenURLAction { url in
                    activity.openedURLs.append(url)
                    return .handled
                }))
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

        func expectOnlyPane(_ tab: SettingsView.Tab) {
            #expect(title == tab.title)
            for (candidate, marker) in SettingsSidebarTests.paneMarkers {
                #expect((find(marker) != nil) == (candidate == tab), "Only \(tab) should mount; checking \(candidate).")
            }
            let back = find("settings-back-to-advanced")
            if SettingsView.Tab.advancedTabs.contains(tab) {
                #expect(back?.accessibilityLabel() == "Advanced")
                #expect(back?.isAccessibilityEnabled() == true)
            } else {
                #expect(back == nil)
            }
            if queryIsEmpty {
                #expect(rows == SettingsView.Tab.sidebarTabs)
                #expect(selectedSidebarTabs == [tab.sidebarTab])
            }
        }

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

        var sidebarTable: NSTableView? {
            settingsTestSubviews(hosting.view).compactMap { $0 as? NSTableView }.first {
                settingsTestAccessibility($0).contains { $0.accessibilityIdentifier()?.hasPrefix("settings-sidebar-") == true }
            }
        }

        var selectedSidebarTabs: [SettingsView.Tab] {
            guard let table = sidebarTable else { return [] }
            let renderedRows = rows
            return table.selectedRowIndexes.compactMap { index in
                renderedRows.indices.contains(index) ? renderedRows[index] : nil
            }
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

        func expectUnchanged(reads: Int = 0, openedURLs: [String] = []) {
            #expect(model.preferences == initialPreferences)
            #expect(store.load() == initialPreferences)
            #expect(activity.writes.isEmpty)
            #expect(activity.retries == 0)
            #expect(activity.reads == reads)
            #expect(activity.captures == 0)
            #expect(activity.dividerWrites.isEmpty)
            #expect(activity.anchorImageWrites == 0)
            #expect(activity.openedURLs.map(\.absoluteString) == openedURLs)
            #expect(server.moveRequests.isEmpty)
            #expect(server.clickedWindowIDs.isEmpty)
            #expect(engine.stateMachine == initialEngineState)
            #expect(engine.anchorSymbol == initialPreferences.appIcon.menuBarSymbol)
            #expect(!engine.placementInProgress)
            #expect(!engine.placementPending)
            #expect(!engine.placementFailed)
            #expect(engine.floatingBar?.preferences == initialPreferences)
            #expect(engine.floatingBar?.isVisible == false)
            #expect(loginItem.setEnabledCalls.isEmpty)
            #expect(loginItem.openSystemSettingsCalls == 0)
            #expect(!window.isVisible)
            #expect(!window.isKeyWindow)
        }
    }
}

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
            ("Advanced Wi-Fi", .triggers, "settings-trigger-add"),
            ("Advanced membership", .groups, "settings-group-create-row")
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
            try test.expectHighlights([highlight])
            test.expectUnchanged(reads: reads)
        }
    }

    @Test func returnSelectsTheFirstRankedResultAndClearsTheField() async throws {
        let destinations: [(String, [SettingsView.Tab], String)] = [
            ("style", [.style, .behavior], "settings-detail-title"),
            ("Advanced Triggers Wi-Fi", [.triggers], "settings-trigger-add")
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
            try test.expectHighlights([highlight])
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
            let searches: [(String, [String])]
            switch child {
            case .presets:
                searches = [
                    ("Advanced Presets", ["settings-detail-title"]),
                    ("Presets Rename", [hasSavedTools ? "settings-preset-name-\(preset.id)" : "settings-preset-save-row"]),
                    ("Presets Preset name", [hasSavedTools ? "settings-preset-name-\(preset.id)" : "settings-preset-save-row"]),
                    ("Presets Apply", [hasSavedTools ? "settings-preset-apply-\(preset.id)" : "settings-preset-save-row"]),
                    ("Presets Update from Current", [hasSavedTools ? "settings-preset-update-\(preset.id)" : "settings-preset-save-row"]),
                    ("Presets Delete", [hasSavedTools ? "settings-preset-delete-\(preset.id)" : "settings-preset-save-row"])
                ]
            case .triggers:
                searches = [
                    ("Advanced Triggers", ["settings-detail-title"]),
                    ("Triggers Add Rule", ["settings-trigger-add"]),
                    ("Triggers Edit rule", [hasSavedTools ? "settings-trigger-edit-\(rule.id)" : "settings-trigger-add"]),
                    ("Triggers Delete", [hasSavedTools ? "settings-trigger-delete-\(rule.id)" : "settings-trigger-add"]),
                    ("Advanced Wi-Fi", ["settings-trigger-add"])
                ]
            case .groups:
                let members = try items.map { item in
                    "settings-group-member-\(group.id)-\(try #require(ItemControlStore.key(for: item.snapshot)))"
                }
                searches = [
                    ("Advanced Groups", ["settings-detail-title"]),
                    ("Groups Create Group", ["settings-group-create-row"]),
                    ("Groups Rename", [hasSavedTools ? "settings-group-name-\(group.id)" : "settings-group-create-row"]),
                    ("Groups Group name", [hasSavedTools ? "settings-group-name-\(group.id)" : "settings-group-create-row"]),
                    ("Groups Delete", [hasSavedTools ? "settings-group-delete-\(group.id)" : "settings-group-create-row"]),
                    ("Advanced membership", hasSavedTools ? members : ["settings-group-create-row"])
                ]
            default:
                searches = []
            }
            for (query, identifiers) in searches {
                try await test.submit(query)
                try #require(await test.waitForUpdate {
                    test.queryIsEmpty && test.highlightsMatch(identifiers)
                }, "\(query) must reach its actual controls. \(test.highlightDescription)")
                try test.expectHighlights(identifiers)
                test.expectOnlyPane(child)
                #expect(test.model.pendingChangeCount == 1)
                test.expectUnchanged(reads: reads)
            }
            if hasSavedTools {
                let id = child == .presets ? preset.id : (child == .triggers ? rule.id : group.id)
                let delete = "settings-\(prefix)-delete-\(id)"
                let confirm = "settings-\(prefix)-confirm-delete-\(id)"
                #expect(try test.element(delete).accessibilityPerformPress())
                try #require(await test.waitForUpdate { test.find(confirm) != nil && test.find(delete) == nil })
                try await test.submit("\(child.title) Delete")
                try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch([confirm]) })
                try test.expectHighlights([confirm])
                #expect(!test.isHighlighted("settings-\(prefix)-cancel-delete-\(id)"))
                #expect(test.model.pendingChangeCount == 1)
                test.expectUnchanged(reads: reads)
                #expect(try test.element("settings-\(prefix)-cancel-delete-\(id)").accessibilityPerformPress())
                try #require(await test.waitForUpdate { test.find(confirm) == nil && test.highlightsMatch([delete]) })
                try test.expectHighlights([delete])
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
            test.queryIsEmpty && test.isHighlighted("settings-trigger-add") && test.selectedSidebarTabs == [.advanced]
        })
        try test.expectHighlights(["settings-trigger-add"])
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
        if hasSavedTools { try await emptyGroupMembershipSearchPreservesHeaderEdits() }
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
        preferences.menuBarStyle.gradientEnd = MenuBarStyle.defaultGradientEnd
        preferences.menuBarSpacing = MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4)
        let item = settingsTestItem(1, alias: "Clipboard", observedHidden: false)
        preferences.itemAliases.setAlias("Clipboard", for: item.snapshot)
        let test = try Harness(preferences: preferences, items: [item])
        test.model.setPlacement(.hidden, for: item)
        let destinations: [(String, SettingsView.Tab, [String])] = [
            ("get started", .general, ["settings-get-started-heading"]),
            ("Arrange Items", .general, ["settings-open-items"]),
            ("Startup", .general, ["settings-startup-heading"]),
            ("launch at login", .general, ["settings-launch-at-login"]),
            ("Permissions", .general, ["settings-permissions-heading"]),
            ("  GÉNERAL   Permíssions\n", .general, ["settings-permissions-heading"]),
            ("accessibility", .general, ["settings-permission-accessibility"]),
            ("Permissions Accessibility", .general, ["settings-permission-accessibility"]),
            ("screen recording", .general, ["settings-permission-screenRecording"]),
            ("General Permissions Screen Recording", .general, ["settings-permission-screenRecording"]),
            ("Optional tools", .advanced, ["settings-advanced-tools-heading"]),
            ("advanced tools", .advanced, ["settings-advanced-tools-heading"]),
            ("Menu bar spacing", .advanced, ["settings-spacing-heading"]),
            ("Reduce menu bar item spacing", .advanced, ["settings-spacing-enabled"]),
            ("spacing", .advanced, ["settings-spacing-value-row"]),
            ("Menu bar spacing Selection padding", .advanced, ["settings-spacing-padding-row"]),
            ("Advanced ad", .advanced, ["settings-spacing-padding-row"]),
            ("Reset to system default", .advanced, ["settings-spacing-reset"]),
            ("Backup", .advanced, ["settings-backup-heading"]),
            ("Layout file", .advanced, ["settings-backup-row"]),
            ("export", .advanced, ["settings-backup-export"]),
            ("Backup Import", .advanced, ["settings-backup-import"]),
            ("notch", .advanced, ["settings-notch-heading"]),
            ("Make room near the notch", .advanced, ["settings-notch-picker"]),
            ("advanced", .advanced, ["settings-detail-title"]),
            ("aliases", .items, ["settings-items-list-header"]),
            ("Items item", .items, ["settings-items-list-header"]),
            ("Placement Preview", .items, ["settings-preview-heading"]),
            ("after apply", .items, ["settings-preview-heading"]),
            ("Items Menu Bar", .items, ["settings-preview-menu-bar-heading"]),
            ("Hidden Bar", .items, ["settings-preview-hidden-heading"]),
            ("Always Hidden", .items, ["settings-preview-always-hidden-heading"]),
            ("hide all", .items, ["settings-placement-bulk"]),
            ("apply changes", .items, ["settings-placement-actions"]),
            ("Icons", .style, ["settings-icons-heading"]),
            ("Style Icons", .style, ["settings-icons-heading"]),
            ("Menu bar icon", .style, ["settings-icon-menu-bar"]),
            ("Icons sparkle", .style, ["settings-icon-menu-bar"]),
            ("App icon", .style, ["settings-icon-app-theme"]),
            ("sunset", .style, ["settings-icon-app-theme"]),
            ("Style Icons Sunset", .style, ["settings-icon-app-theme"]),
            ("Style Menu bar", .style, ["settings-style-menu-bar-heading"]),
            ("styles", .style, ["settings-style-enabled"]),
            ("Style the menu bar", .style, ["settings-style-enabled"]),
            ("tint", .style, ["settings-style-tint"]),
            ("gradient", .style, ["settings-style-gradient-enabled"]),
            ("Gradient end color", .style, ["settings-style-gradient-end"]),
            ("  Style OPÁCITY\n border\t", .style, ["settings-style-opacity-row", "settings-style-border-row"]),
            ("Border color", .style, ["settings-style-border-color"]),
            ("shape", .style, ["settings-style-shape"]),
            ("corner radius", .style, ["settings-style-corner-radius-row"]),
            ("shadow", .style, ["settings-style-shadow"]),
            ("reset style", .style, ["settings-style-reset"]),
            ("style preview", .style, ["settings-style-preview"]),
            ("style", .style, ["settings-detail-title"]),
            ("Hidden items", .behavior, ["settings-hidden-items-heading"]),
            ("Behavior Hidden items", .behavior, ["settings-hidden-items-heading"]),
            ("floating bar", .behavior, ["settings-floating-bar-enabled"]),
            ("Floating bar style", .behavior, ["settings-floating-bar-style"]),
            ("horizontal strip", .behavior, ["settings-floating-bar-style"]),
            ("Closing the bar", .behavior, ["settings-closing-bar-heading"]),
            ("Automatically re-hide", .behavior, ["settings-auto-rehide"]),
            ("dismiss", .behavior, ["settings-dismiss-on-exit"]),
            ("re-hide after", .behavior, ["settings-auto-rehide-delay-row"]),
            ("Closing the bar delay", .behavior, ["settings-auto-rehide-delay-row"]),
            ("Reveal gestures", .behavior, ["settings-reveal-gestures-heading"]),
            ("HóVeR", .behavior, ["settings-reveal-hover"]),
            ("Reveal gestures hover", .behavior, ["settings-reveal-hover"]),
            ("scroll", .behavior, ["settings-reveal-scroll"]),
            ("keyboard shortcut", .shortcuts, ["settings-shortcut-toggle-enabled"]),
            ("Toggle bar", .shortcuts, ["settings-shortcut-toggle-row"]),
            ("item shortcuts", .shortcuts, ["settings-item-shortcuts-heading"]),
            ("Shortcuts Item shortcuts", .shortcuts, ["settings-item-shortcuts-heading"]),
            ("profiles", .presets, ["settings-preset-header"]),
            ("save layout", .presets, ["settings-preset-save-row"]),
            ("low power", .triggers, ["settings-trigger-add"]),
            ("Add Rule", .triggers, ["settings-trigger-add"]),
            ("membership", .groups, ["settings-group-create-row"]),
            ("Create Group", .groups, ["settings-group-create-row"]),
            ("version", .about, ["settings-about-version"]),
            ("macOS Tahoe", .about, ["settings-about-compatibility"]),
            ("Project & help", .about, ["settings-about-links-heading"]),
            ("project", .about, ["settings-about-project"]),
            ("support", .about, ["settings-about-issues"]),
            ("license", .about, ["settings-about-license"]),
            ("about", .about, ["settings-detail-title"])
        ] + SettingsView.Tab.allCases.map { ($0.title, $0, ["settings-detail-title"]) }
        var reads = 0
        for (index, destination) in destinations.enumerated() {
            let (query, tab, identifiers) = destination
            let previousTitle = test.title
            let beforeSearch = query == "Groups" ? test.readinessDescription(tab: tab, highlights: identifiers, reads: reads) : nil
            let editor = try await test.type(query)
            let results = SettingsView.Tab.matching(query)
            try #require(await test.waitForUpdate { test.sidebarRowsFullyVisible(results) && !test.hasHighlights },
                         "Search results must be visible for \(query.debugDescription). \(test.readinessDescription(tab: tab, highlights: identifiers, reads: reads, expectedRows: results))")
            #expect(test.title == previousTitle, "Typing must keep the existing pane mounted.")
            let filteredSearch = query == "Groups" ? test.readinessDescription(tab: tab, highlights: identifiers, reads: reads, expectedRows: results) : nil
            if index.isMultiple(of: 2) {
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            } else {
                #expect(try test.element("settings-sidebar-\(tab.rawValue)").accessibilityPerformPress())
            }
            // Groups needs current members, just as Items and Shortcuts need current item choices.
            let loadsItems = [.items, .shortcuts, .groups].contains(tab)
            if previousTitle != tab.title, loadsItems { reads += 1 }
            let ready = await test.waitForUpdate {
                test.title == tab.title && test.queryIsEmpty && test.highlightsMatch(identifiers)
                    && test.activity.reads == reads && test.sidebarRowsFullyVisible(Self.sidebarTabs)
                    && test.selectedSidebarTabs == [tab.sidebarTab]
                    && (!loadsItems || !test.model.itemsLoading)
            }
            if let beforeSearch, let filteredSearch {
                let afterSelection = test.readinessDescription(tab: tab, highlights: identifiers, reads: reads)
                Attachment.record(
                    "Before search:\n\(beforeSearch)\nFiltered:\n\(filteredSearch)\nAfter selection:\n\(afterSelection)",
                    named: "settings-groups-search-readiness.txt"
                )
            }
            try #require(ready, "Search \(query.debugDescription) must settle completely. \(test.readinessDescription(tab: tab, highlights: identifiers, reads: reads))")
            test.expectOnlyPane(tab)
            try test.expectHighlights(identifiers)
            try test.expectHeadingNeighborsUnmatched(identifiers)
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
        let destinations: [(String, SettingsView.Tab, String)] = [
            ("opacity", .style, "settings-style-enabled"),
            ("Gradient end color", .style, "settings-style-enabled"),
            ("Border color", .style, "settings-style-enabled"),
            ("horizontal strip", .behavior, "settings-floating-bar-enabled"),
            ("Dismiss", .behavior, "settings-floating-bar-enabled"),
            ("Hidden items", .behavior, "settings-hidden-items-heading"),
            ("hover", .behavior, "settings-reveal-hover"),
            ("re-hide after", .behavior, "settings-auto-rehide"),
            ("Closing the bar", .behavior, "settings-closing-bar-heading"),
            ("Menu bar spacing", .advanced, "settings-spacing-heading"),
            ("selection padding", .advanced, "settings-spacing-enabled"),
            ("Reset to system default", .advanced, "settings-spacing-enabled"),
            ("keyboard shortcut", .shortcuts, "settings-shortcut-toggle-enabled"),
            ("Toggle bar", .shortcuts, "settings-shortcut-toggle-enabled"),
            ("Item shortcuts", .shortcuts, "settings-item-shortcuts-heading")
        ]
        var reads = 0
        for (query, tab, id) in destinations {
            let previousTitle = test.title
            try await test.submit(query)
            if tab == .shortcuts, previousTitle != tab.title { reads += 1 }
            let started = ContinuousClock.now
            var transitionalMatches: String?
            try #require(await test.waitForUpdate {
                guard started.duration(to: .now) < .seconds(2) else { return false }
                let complete = test.highlightsMatch([id])
                if transitionalMatches == nil, test.queryIsEmpty, test.isHighlighted(id), !complete {
                    transitionalMatches = "At \(started.duration(to: .now)) after \(query.debugDescription):\n\(test.highlightDescription)"
                }
                return test.queryIsEmpty && test.title == tab.title && test.activity.reads == reads && complete
            }, "The complete highlighted-region set must settle before highlight expiry for \(query.debugDescription).\n\(test.highlightDescription)")
            if let transitionalMatches {
                Attachment.record(
                    transitionalMatches + "\nSettled at \(started.duration(to: .now)):\n\(test.highlightDescription)",
                    named: "settings-search-settlement-\(id).txt"
                )
            }
            try test.expectHighlights([id])
            if query == "hover" {
                #expect(try !test.element(id).isAccessibilityEnabled())
                #expect(try !test.element(id).accessibilityPerformPress())
            }
            test.expectUnchanged(reads: reads)
        }

        // An explicit click may reveal the searched control; search itself must never enable it.
        try await test.submit("opacity")
        try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch(["settings-style-enabled"]) })
        _ = try test.element("settings-style-enabled").accessibilityPerformPress()
        try #require(await test.waitForUpdate { test.highlightsMatch(["settings-style-opacity-row"]) })
        #expect(!test.isHighlighted("settings-style-enabled"))
        try test.expectHighlights(["settings-style-opacity-row"])
        preferences.menuBarStyle.isEnabled = true
        #expect(test.store.load() == preferences)
        #expect(test.activity.writes == [preferences])
        #expect(test.activity.captures == 0)
        #expect(test.server.moveRequests.isEmpty)

        for (query, id) in [
            ("Gradient end color", "settings-style-gradient-enabled"),
            ("Border color", "settings-style-border-row")
        ] {
            try await test.submit(query)
            try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch([id]) })
            try test.expectHighlights([id])
            #expect(test.store.load() == preferences)
            #expect(test.activity.writes == [preferences])
            #expect(test.activity.captures == 0)
            #expect(test.activity.dividerWrites.isEmpty)
            #expect(test.server.moveRequests.isEmpty)
        }
    }

    @Test func triggerEditorSearchTargetsVisibleHeadingsAndControlsWithoutEditingTheRule() async throws {
        var preferences = Preferences.default
        let preset = LayoutPreset(name: "Work", itemControls: preferences.itemControls)
        let rule = TriggerRule(name: "Battery work", conditions: [.onBattery], presetID: preset.id)
        preferences.presets = [preset]
        preferences.triggers = [rule]
        let item = settingsTestItem(1, observedHidden: false)
        let test = try Harness(initialTab: .triggers, preferences: preferences, items: [item])
        test.model.setPlacement(.hidden, for: item)
        try await test.submit("Advanced Wi-Fi")
        try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch(["settings-trigger-add"]) })
        try test.expectHighlights(["settings-trigger-add"])
        #expect(test.find("settings-trigger-editor") == nil)
        test.expectUnchanged()

        for isNew in [true, false] {
            let open = isNew ? "settings-trigger-add" : "settings-trigger-edit-\(rule.id)"
            #expect(try test.element(open).accessibilityPerformPress())
            try #require(await test.waitForUpdate { test.find("settings-trigger-editor") != nil })
            let section = isNew ? "New rule" : "Edit rule"
            let field = try test.editableField(showing: isNew ? "" : rule.name)
            let unsavedName = "Unsaved \(section) name"
            try test.type(unsavedName, into: field)
            try #require(await test.waitForUpdate {
                test.find("settings-trigger-editor-name")?.accessibilityValue() as? String == unsavedName
            })
            let originalConditions = test.identifiers(withPrefix: "settings-trigger-condition-remove-")
            try #require(originalConditions.count == 1)
            #expect(try test.element("settings-trigger-editor-add-condition").accessibilityPerformPress())
            try #require(await test.waitForUpdate {
                test.identifiers(withPrefix: "settings-trigger-condition-remove-").count == 2
            })
            let unsavedConditions = test.identifiers(withPrefix: "settings-trigger-condition-remove-")
            #expect(originalConditions.isSubset(of: unsavedConditions))
            let addDestination = isNew ? "settings-trigger-editor-save" : "settings-trigger-rule-heading"
            let queries: [(String, [String])] = [
                (section, ["settings-trigger-rule-heading"]),
                ("Triggers New rule", ["settings-trigger-rule-heading"]),
                ("Triggers Edit rule", ["settings-trigger-rule-heading"]),
                ("Triggers Add Rule", [addDestination]),
                ("Triggers Delete", ["settings-trigger-rule-heading"]),
                ("Rule name", ["settings-trigger-editor-name"]),
                ("\(section) Rule name", ["settings-trigger-editor-name"]),
                ("Apply preset", ["settings-trigger-editor-preset"]),
                ("\(section) Apply preset", ["settings-trigger-editor-preset"]),
                ("Conditions", ["settings-trigger-conditions-heading"]),
                ("Advanced Triggers Wi-Fi", ["settings-trigger-conditions-heading"]),
                ("Add Condition", ["settings-trigger-editor-add-condition"]),
                ("Triggers Remove Condition", unsavedConditions.sorted()),
                ("Save", ["settings-trigger-editor-save"])
            ]
            for (query, ids) in queries {
                try await test.submit(query)
                try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch(ids) }, "\(test.highlightDescription)")
                try test.expectHighlights(ids)
                #expect(settingsTestAccessibilityText(try test.element("settings-trigger-rule-heading")).contains(section))
                #expect(try test.element("settings-trigger-editor-name").accessibilityValue() as? String == unsavedName)
                #expect(test.identifiers(withPrefix: "settings-trigger-condition-remove-") == unsavedConditions)
                #expect(!test.isHighlighted("settings-trigger-header"))
                #expect(test.model.pendingChangeCount == 1)
                #expect(test.model.placement(of: item) == .hidden)
                test.expectUnchanged()
            }

            var remainingConditions = unsavedConditions
            for id in unsavedConditions.sorted() {
                #expect(try test.element(id).accessibilityPerformPress())
                remainingConditions.remove(id)
                try #require(await test.waitForUpdate {
                    test.identifiers(withPrefix: "settings-trigger-condition-remove-") == remainingConditions
                })
            }
            for (query, id) in [
                ("Triggers Remove Condition", "settings-trigger-editor-add-condition"),
                ("Triggers Add Condition", "settings-trigger-editor-add-condition"),
                ("Triggers New rule", "settings-trigger-rule-heading"),
                ("Triggers Edit rule", "settings-trigger-rule-heading"),
                ("Triggers Delete", "settings-trigger-rule-heading"),
                ("Triggers Add Rule", addDestination)
            ] {
                try await test.submit(query)
                try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch([id]) }, "\(test.highlightDescription)")
                try test.expectHighlights([id])
                #expect(test.identifiers(withPrefix: "settings-trigger-condition-remove-").isEmpty)
                #expect(try test.element("settings-trigger-editor-name").accessibilityValue() as? String == unsavedName)
                #expect(!(try test.element("settings-trigger-editor-save").isAccessibilityEnabled()))
                #expect(test.model.pendingChangeCount == 1)
                test.expectUnchanged()
            }
            #expect(try test.element("settings-trigger-editor-add-condition").accessibilityPerformPress())
            try #require(await test.waitForUpdate {
                test.identifiers(withPrefix: "settings-trigger-condition-remove-").count == 1
            })
            let restoredConditions = test.identifiers(withPrefix: "settings-trigger-condition-remove-")
            #expect(restoredConditions.isDisjoint(with: unsavedConditions))
            try await test.submit("Triggers Remove Condition")
            try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch(restoredConditions.sorted()) })
            try test.expectHighlights(restoredConditions.sorted())
            #expect(!test.isHighlighted("settings-trigger-editor-add-condition"))
            #expect(try test.element("settings-trigger-editor-name").accessibilityValue() as? String == unsavedName)
            test.expectUnchanged()
            #expect(try test.element("settings-trigger-editor-cancel").accessibilityPerformPress())
            try #require(await test.waitForUpdate { test.find("settings-trigger-editor") == nil })
            test.expectUnchanged()
        }
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
        let headings: [(SettingsView.Tab, String, String, [String])] = [
            (.general, "Permissions", "settings-permissions-heading", ["settings-permission-accessibility", "settings-permission-screenRecording"]),
            (.style, "Icons", "settings-icons-heading", ["settings-icons-row"])
        ]
        for (tab, query, id, neighbors) in headings {
            test.model.requestedTab = tab
            try #require(await test.waitForUpdate { test.title == tab.title && test.model.requestedTab == nil })
            let editor = try await test.type(query)
            try #require(await test.waitForUpdate { test.rows.contains(tab) && !test.hasHighlights })
            let frame = try test.element(id).accessibilityFrame()
            let baseline = try settingsTestBitmap(test.hosting.view)
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try #require(await test.waitForUpdate { test.queryIsEmpty && test.isHighlighted(id) })
            try await Task.sleep(for: .milliseconds(250))
            test.hosting.render()
            let painted = try settingsTestBitmap(test.hosting.view)
            try test.expectHighlights([id])
            #expect(try test.element(id).accessibilityFrame() == frame)
            #expect(try changedPixels(baseline, painted, in: frame, test: test) > 30)
            for neighbor in neighbors {
                let neighborFrame = try test.element(neighbor).accessibilityFrame()
                #expect(!test.isHighlighted(neighbor))
                #expect(try changedPixels(baseline, painted, in: neighborFrame, test: test) == 0,
                        "Searching \(query) must paint its heading, not \(neighbor).")
            }
            test.expectUnchanged()
        }
        test.model.requestedTab = .behavior
        try #require(await test.waitForUpdate { test.title == "Behavior" && test.model.requestedTab == nil })
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

    private func emptyGroupMembershipSearchPreservesHeaderEdits() async throws {
        let draftItem = settingsTestItem(1, alias: "Clipboard", observedHidden: false)
        let member = settingsTestItem(2, alias: "Calendar", observedHidden: true)
        let memberKey = try #require(ItemControlStore.key(for: member.snapshot))
        let group = ItemGroup(name: "Empty tools")
        var preferences = Preferences.default
        // Already-hidden membership changes keep the real engine's placement intent unchanged.
        preferences.itemControls.setHidden(true, for: member.snapshot)
        preferences.itemAliases.setAlias("Calendar", for: member.snapshot)
        preferences.itemGroups = [group]
        let test = try Harness(initialTab: .groups, preferences: preferences)
        test.model.setPlacement(.hidden, for: draftItem)
        let headerID = "settings-group-header-\(group.id)"
        let nameID = "settings-group-name-\(group.id)"
        let memberID = "settings-group-member-\(group.id)-\(memberKey)"
        let memberPrefix = "settings-group-member-\(group.id)-"
        try #require(await test.waitForUpdate { !test.model.itemsLoading && test.find(headerID) != nil })
        #expect(test.model.loadedItems.isEmpty)
        #expect(test.identifiers(withPrefix: memberPrefix).isEmpty)
        try await test.submit("Advanced membership")
        try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch([headerID]) })
        try test.expectHighlights([headerID])
        #expect(!test.isHighlighted("settings-group-create-row"))
        test.expectUnchanged(reads: 1)

        let field = try test.editableField(showing: group.name)
        let unsavedName = "Uncommitted group name"
        try test.type(unsavedName, into: field)
        try #require(await test.waitForUpdate { test.find(nameID)?.accessibilityValue() as? String == unsavedName })
        test.activity.providedItems = [draftItem, member]
        await test.model.reloadItems()
        try #require(await test.waitForUpdate { test.identifiers(withPrefix: memberPrefix).count == 2 })
        #expect(try test.element(nameID).accessibilityValue() as? String == unsavedName)
        #expect(test.model.pendingChangeCount == 1)
        test.expectUnchanged(reads: 2)
        try test.type(group.name, into: try test.editableField(showing: unsavedName))
        #expect(test.window.makeFirstResponder(nil))
        try await test.submit("Advanced membership")
        let members = test.identifiers(withPrefix: memberPrefix).sorted()
        try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch(members) })
        try test.expectHighlights(members)
        #expect(!test.isHighlighted(headerID))
        test.expectUnchanged(reads: 2)

        // Return validates the local draft without depending on focus-loss scheduling.
        let invalidField = try test.editableField(showing: group.name)
        let invalidEditor = try test.type(" ", into: invalidField)
        try #require(await test.waitForUpdate {
            test.window.firstResponder === invalidEditor && test.find(nameID)?.accessibilityValue() as? String == " "
        })
        invalidEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try #require(await test.waitForUpdate {
            test.find("settings-group-name-error-\(group.id)").map(settingsTestAccessibilityText)
                == ItemGroupLibrary.ValidationError.emptyName.message
        }, "Invalid name after Return: field=\(String(describing: test.find(nameID)?.accessibilityValue())) editor=\(invalidEditor.string.debugDescription) error=\(String(describing: test.find("settings-group-name-error-\(group.id)").map(settingsTestAccessibilityText))) focus=\(String(describing: test.window.firstResponder)) writes=\(test.activity.writes.count)\n\(test.highlightDescription)")
        #expect(test.window.makeFirstResponder(nil))
        test.expectUnchanged(reads: 2)
        #expect(try test.element(memberID).accessibilityPerformPress())
        var assigned = preferences
        assigned.itemGroups[0].appendKey(memberKey)
        try #require(await test.waitForUpdate { test.model.preferences == assigned })
        test.expectUnchanged(reads: 2, afterWrites: [assigned])

        test.activity.providedItems = []
        await test.model.reloadItems()
        try #require(await test.waitForUpdate {
            test.model.loadedItems.isEmpty && test.identifiers(withPrefix: memberPrefix) == [memberID]
        })
        #expect(try test.element(nameID).accessibilityValue() as? String == " ")
        #expect(try test.element(memberID).accessibilityLabel() == "Calendar (not running)")
        try await test.submit("Advanced membership")
        try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch([memberID]) })
        try test.expectHighlights([memberID])
        #expect(!test.isHighlighted(headerID))
        test.expectUnchanged(reads: 3, afterWrites: [assigned])

        #expect(try test.element(memberID).accessibilityPerformPress())
        try #require(await test.waitForUpdate {
            test.model.preferences == preferences && test.identifiers(withPrefix: memberPrefix).isEmpty
        })
        try await test.submit("Advanced membership")
        try #require(await test.waitForUpdate { test.queryIsEmpty && test.highlightsMatch([headerID]) })
        try test.expectHighlights([headerID])
        #expect(try test.element(nameID).accessibilityValue() as? String == " ")
        #expect(test.find("settings-group-name-error-\(group.id)") != nil)
        #expect(!test.isHighlighted("settings-group-create-row"))
        #expect(test.model.pendingChangeCount == 1)
        #expect(test.model.placement(of: draftItem) == .hidden)
        #expect(test.model.draftDiscardedNotice == nil)
        test.expectUnchanged(reads: 3, afterWrites: [assigned, preferences])
        try test.type(group.name, into: try test.editableField(showing: " "))
        #expect(test.window.makeFirstResponder(nil))
        try #require(await test.waitForUpdate { test.find("settings-group-name-error-\(group.id)") == nil })
        test.expectUnchanged(reads: 3, afterWrites: [assigned, preferences])
    }

    @MainActor
    private final class Activity {
        var providedItems: [FloatingBarItem] = []
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
            activity.providedItems = items
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
                itemsProvider: { activity.reads += 1; return activity.providedItems },
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
                }), configureWindow: SettingsWindowController.configureWindow)
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
            return hasSearchMatch(element)
        }

        // A new Form can coexist with retained native rows for another run-loop turn.
        // Readiness requires the same direct-region and exclusion checks as expectHighlights.
        func highlightsMatch(_ identifiers: [String]) -> Bool {
            guard !identifiers.isEmpty else { return false }
            let elements = settingsTestAccessibility(hosting.view)
            guard let detail = elements.first(where: { $0.accessibilityIdentifier() == "settings-detail" }) else { return false }
            let detailFrame = detail.accessibilityFrame()
            let regions = identifiers.compactMap { id -> CGRect? in
                guard let target = elements.first(where: { $0.accessibilityIdentifier() == id }), hasSearchMatch(target) else { return nil }
                let frame = target.accessibilityFrame()
                return !frame.isEmpty && detailFrame.contains(frame) ? frame : nil
            }
            guard regions.count == identifiers.count else { return false }
            return elements.filter(hasSearchMatch).allSatisfy { match in
                let frame = match.accessibilityFrame()
                return frame.isEmpty || regions.contains { $0.contains(frame) }
            }
        }

        func expectHighlights(_ identifiers: [String]) throws {
            let detail = try element("settings-detail").accessibilityFrame()
            let regions = try identifiers.map { id in
                let target = try element(id)
                #expect(hasSearchMatch(target), "\(id) itself must carry the match, not an arbitrary descendant.")
                let frame = target.accessibilityFrame()
                #expect(!frame.isEmpty && detail.contains(frame), "\(id) must be visible in the destination pane.")
                return frame
            }
            for match in settingsTestAccessibility(hosting.view).filter(hasSearchMatch) {
                let frame = match.accessibilityFrame()
                guard !frame.isEmpty else { continue }
                #expect(regions.contains { $0.contains(frame) },
                        "Unexpected match outside \(identifiers): \(match.accessibilityIdentifier() ?? match.accessibilityLabel() ?? "unnamed") at \(frame).")
            }
        }

        func expectHeadingNeighborsUnmatched(_ identifiers: [String]) throws {
            let headings: [String: (String, [String])] = [
                "settings-get-started-heading": ("Get started", ["settings-open-items"]),
                "settings-startup-heading": ("Startup", ["settings-launch-at-login"]),
                "settings-permissions-heading": ("Permissions", ["settings-permission-accessibility", "settings-permission-screenRecording"]),
                "settings-advanced-tools-heading": ("Optional tools", ["settings-advanced-presets", "settings-advanced-triggers", "settings-advanced-groups"]),
                "settings-spacing-heading": ("Menu bar spacing", ["settings-spacing-enabled", "settings-spacing-value-row", "settings-spacing-padding-row"]),
                "settings-backup-heading": ("Backup", ["settings-backup-row", "settings-backup-export", "settings-backup-import"]),
                "settings-notch-heading": ("Notch", ["settings-notch-picker"]),
                "settings-preview-heading": ("Placement Preview", ["settings-preview-phase", "settings-preview-menu-bar-heading", "settings-preview-hidden-heading", "settings-preview-always-hidden-heading"]),
                "settings-preview-menu-bar-heading": ("Menu Bar", ["settings-preview-hidden-heading", "settings-preview-always-hidden-heading"]),
                "settings-preview-hidden-heading": ("Hidden Bar", ["settings-preview-menu-bar-heading", "settings-preview-always-hidden-heading"]),
                "settings-preview-always-hidden-heading": ("Always Hidden", ["settings-preview-menu-bar-heading", "settings-preview-hidden-heading"]),
                "settings-icons-heading": ("Icons", ["settings-icon-menu-bar", "settings-icon-app-theme"]),
                "settings-style-menu-bar-heading": ("Menu bar", ["settings-style-enabled", "settings-style-preview"]),
                "settings-hidden-items-heading": ("Hidden items", ["settings-floating-bar-enabled", "settings-floating-bar-style"]),
                "settings-closing-bar-heading": ("Closing the bar", ["settings-auto-rehide", "settings-auto-rehide-delay-row", "settings-dismiss-on-exit"]),
                "settings-reveal-gestures-heading": ("Reveal gestures", ["settings-reveal-hover", "settings-reveal-scroll"]),
                "settings-item-shortcuts-heading": ("Item shortcuts", ["settings-shortcut-items-hint", "settings-shortcut-toggle-row"]),
                "settings-about-links-heading": ("Project & help", ["settings-about-project", "settings-about-issues", "settings-about-license"])
            ]
            for id in identifiers {
                guard let (label, neighbors) = headings[id] else { continue }
                let heading = try element(id)
                #expect(settingsTestAccessibilityText(heading).contains(label))
                #expect(heading.accessibilityFrame().height <= 30, "A heading query must not outline the form group below it.")
                for neighborID in neighbors {
                    let neighbor = try element(neighborID)
                    #expect(!hasSearchMatch(neighbor), "\(label) must not also mark \(neighborID).")
                    #expect(!heading.accessibilityFrame().intersects(neighbor.accessibilityFrame()))
                }
            }
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
                return "\(id): \(element.accessibilityRole()?.rawValue ?? "nil") type=\(Swift.type(of: element.object)) frame=\(element.accessibilityFrame()) enabled=\(element.isAccessibilityEnabled()) matched=\(hasSearchMatch(element))"
            }.joined(separator: "\n")
        }

        func readinessDescription(
            tab: SettingsView.Tab, highlights: [String], reads: Int, expectedRows: [SettingsView.Tab] = SettingsView.Tab.sidebarTabs
        ) -> String {
            let state = "title=\(title ?? "nil") expected=\(tab.title) query=\(searchField?.stringValue.debugDescription ?? "nil") editor=\(searchField?.currentEditor()?.string.debugDescription ?? "nil") queryEmpty=\(queryIsEmpty)\n"
                + "rows=\(rows.map(\.rawValue)) expected=\(expectedRows.map(\.rawValue)) fullyVisible=\(sidebarRowsFullyVisible(expectedRows)) selection=\(selectedSidebarTabs.map(\.rawValue)) expected=\(tab.sidebarTab.rawValue)\n"
                + "reads=\(activity.reads) expected=\(reads) itemsLoading=\(model.itemsLoading) directMatches=\(highlights.map { "\($0)=\(isHighlighted($0))" }) fullMatchSet=\(highlightsMatch(highlights))\n"
                + "window=\(window.frame) contentLayout=\(window.contentLayoutRect) host=\(hosting.view.frame)\n"
            guard let table = sidebarTable else { return state + "sidebar table missing\n" + highlightDescription }
            let scroll = table.enclosingScrollView
            let tableState = "table rows=\(table.numberOfRows) selected=\(Array(table.selectedRowIndexes)) frame=\(table.frame) bounds=\(table.bounds) visible=\(table.visibleRect) rowHeight=\(table.rowHeight)\n"
                + "scroll=\(String(describing: scroll?.frame)) clip=\(String(describing: scroll?.contentView.bounds)) documentVisible=\(String(describing: scroll?.documentVisibleRect)) insets=\(String(describing: scroll?.contentInsets))\n"
                + "constrainedClip=\(String(describing: scroll.map { $0.contentView.constrainBoundsRect($0.contentView.bounds) }))\n"
            let nativeRows = (0..<table.numberOfRows).map { index in
                let rect = table.rect(ofRow: index)
                let row = table.rowView(atRow: index, makeIfNecessary: false)
                let ids = row.map { settingsTestAccessibility($0).compactMap { $0.accessibilityIdentifier() }.filter { $0.hasPrefix("settings-sidebar-") } } ?? []
                return "row[\(index)] rect=\(rect) fullyVisible=\(table.visibleRect.contains(rect)) view=\(String(describing: row)) ids=\(ids)"
            }.joined(separator: "\n")
            return state + tableState + nativeRows + "\n" + highlightDescription
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
            return table.selectedRowIndexes.compactMap { sidebarTab(at: $0, in: table) }
        }

        func sidebarRowsFullyVisible(_ expected: [SettingsView.Tab]) -> Bool {
            guard rows == expected, let table = sidebarTable, table.numberOfRows == expected.count else { return false }
            return expected.indices.allSatisfy { index in
                let frame = table.rect(ofRow: index)
                return !frame.isEmpty && table.visibleRect.contains(frame) && sidebarTab(at: index, in: table) == expected[index]
            }
        }

        private func sidebarTab(at index: Int, in table: NSTableView) -> SettingsView.Tab? {
            guard let row = table.rowView(atRow: index, makeIfNecessary: false) else { return nil }
            let elements = settingsTestAccessibility(row)
            let tabs = SettingsView.Tab.allCases.filter { tab in
                elements.contains { $0.accessibilityIdentifier() == "settings-sidebar-\(tab.rawValue)" }
            }
            return tabs.count == 1 ? tabs.first : nil
        }

        func find(_ identifier: String) -> SettingsTestAXElement? {
            settingsTestAccessibility(hosting.view).first { $0.accessibilityIdentifier() == identifier }
        }

        func identifiers(withPrefix prefix: String) -> Set<String> {
            Set(settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }.filter { $0.hasPrefix(prefix) })
        }

        func element(_ identifier: String) throws -> SettingsTestAXElement {
            try #require(find(identifier), "Missing Settings accessibility identifier \(identifier).")
        }

        func editableField(showing text: String) throws -> NSTextField {
            try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTextField }.first {
                $0.isEditable && !($0 is NSSearchField) && $0.stringValue == text
            }, "Missing editable field showing \(text.debugDescription).")
        }

        func requireSearchField() async throws -> NSSearchField {
            try #require(await waitForUpdate { searchField != nil },
                         "Missing NSSearchField with prompt 'Search Settings' in the off-screen hosting view or window hierarchy.")
            return try #require(searchField)
        }

        @discardableResult
        func type(_ text: String) async throws -> NSTextView {
            let field = try await requireSearchField()
            return try type(text, into: field)
        }

        @discardableResult
        func type(_ text: String, into field: NSTextField) throws -> NSTextView {
            try #require(window.makeFirstResponder(field), "The off-screen field must accept focus.")
            let editor = try #require(field.currentEditor() as? NSTextView, "The native field must provide a field editor.")
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

        func expectUnchanged(reads: Int = 0, openedURLs: [String] = [], afterWrites: [Preferences] = []) {
            let expectedPreferences = afterWrites.last ?? initialPreferences
            #expect(model.preferences == expectedPreferences)
            #expect(store.load() == expectedPreferences)
            #expect(activity.writes == afterWrites)
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

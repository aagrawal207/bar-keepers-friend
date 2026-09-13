import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SettingsViewTests {
    enum AliasRegroup: Sendable {
        case hideAll, discard, placementCompletion
    }

    @Test func stagingAndRecreatingTheViewDoesNotApplyOrReload() async throws {
        let item = settingsTestItem(1, observedHidden: false)
        var reads = 0
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        let initial = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let initialApply = try #require(settingsTestAccessibility(initial.view).first {
            $0.accessibilityIdentifier() == "settings-placement-apply"
        })
        #expect(!initialApply.isAccessibilityEnabled())

        model.setHidden(true, for: item)
        for _ in 0..<2 {
            let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
            let elements = settingsTestAccessibility(hosting.view)
            let count = try #require(elements.first { $0.accessibilityIdentifier() == "settings-placement-count" })
            #expect(settingsTestAccessibilityText(count).contains("1 pending change"))
            #expect(elements.contains { $0.accessibilityIdentifier() == "settings-item-pending-1" })
            let apply = try #require(elements.first { $0.accessibilityIdentifier() == "settings-placement-apply" })
            let discard = try #require(elements.first { $0.accessibilityIdentifier() == "settings-placement-discard" })
            #expect(apply.isAccessibilityEnabled())
            #expect(discard.isAccessibilityEnabled())
            let hidden = try #require(elements.first { $0.accessibilityIdentifier() == "settings-preview-hidden" })
            #expect(settingsTestAccessibility(hidden).contains { $0.accessibilityIdentifier() == "settings-preview-item-1" })
        }
        #expect(reads == 1)
        #expect(writes == 0)
        #expect(retries == 0)
        #expect(model.preferences.itemControls.hiddenInMenuBar.isEmpty)

        model.setAlias("My renamed item", for: item)
        model.discardPlacementChanges()
        let discarded = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let discardedElements = settingsTestAccessibility(discarded.view)
        let previewItem = try #require(discardedElements.first { $0.accessibilityIdentifier() == "settings-preview-item-1" })
        #expect(previewItem.accessibilityLabel() == "My renamed item")
        #expect(previewItem.accessibilityValue() as? String == "Shown")
        let discardedApply = try #require(discardedElements.first { $0.accessibilityIdentifier() == "settings-placement-apply" })
        #expect(!discardedApply.isAccessibilityEnabled())
        #expect(writes == 1)
        #expect(reads == 1)
        #expect(retries == 0)
    }

    @Test func applyingDisablesOnlyPlacementControls() async throws {
        let items = [settingsTestItem(1, observedHidden: false), settingsTestItem(2, observedHidden: true)]
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { items }, onChange: { _ in }
        )
        await model.reloadItems()
        model.setHidden(true, for: items[0])
        model.placementInProgress = true
        model.placementMessage = "Applying placement..."
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let elements = settingsTestAccessibility(hosting.view)
        for identifier in [
            "settings-placement-apply", "settings-placement-discard", "settings-placement-hide-all",
            "settings-placement-show-all", "settings-item-placement-1"
        ] {
            let control = try #require(elements.first { $0.accessibilityIdentifier() == identifier })
            #expect(!control.isAccessibilityEnabled(), "\(identifier) must not accept placement edits while applying")
        }
        let alias = try #require(elements.first { $0.accessibilityIdentifier() == "settings-item-alias-1" })
        #expect(alias.isAccessibilityEnabled())
        let phase = try #require(elements.first { $0.accessibilityIdentifier() == "settings-preview-phase" })
        #expect(settingsTestAccessibilityText(phase).contains("Applying"))
        #expect(phase.isAccessibilityEnabled())
        let progress = try #require(elements.first { $0.accessibilityIdentifier() == "settings-placement-status" })
        #expect(settingsTestAccessibilityText(progress).contains("Applying placement..."))
    }

    @Test(arguments: [false, true], [false, true])
    func retryIsOfferedForSavedPlacementOnly(pending: Bool, hasDraft: Bool) async throws {
        let item = settingsTestItem(1, observedHidden: false)
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { [item] }, onChange: { _ in }
        )
        await model.reloadItems()
        model.placementPending = pending
        model.placementFailed = !pending
        model.placementMessage = pending ? "Placement is waiting." : "Could not move an item."
        if hasDraft { model.setHidden(true, for: item) }
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let elements = settingsTestAccessibility(hosting.view)
        #expect(elements.contains { $0.accessibilityIdentifier() == "settings-placement-retry" } == !hasDraft)
        let apply = try #require(elements.first { $0.accessibilityIdentifier() == "settings-placement-apply" })
        #expect(apply.isAccessibilityEnabled() == hasDraft)
        let message = try #require(elements.first { $0.accessibilityIdentifier() == "settings-placement-status" })
        #expect(settingsTestAccessibilityText(message).contains(pending ? "Placement is waiting." : "Could not move an item."))
    }

    @Test func cachedRowsRemainVisibleWhileReloadIsSuspended() async {
        let started = AsyncGate()
        let finish = AsyncGate()
        let item = settingsTestItem(1, observedHidden: false)
        var reads = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: {
                reads += 1
                if reads > 1 {
                    await started.open()
                    await finish.wait()
                }
                return [item]
            }, onChange: { _ in }
        )
        await model.reloadItems()
        let reload = Task { await model.reloadItems() }
        await started.wait()
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let identifiers = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() }
        #expect(identifiers.contains("settings-items-list"))
        #expect(identifiers.contains("settings-item-placement-1"))
        #expect(identifiers.contains("settings-items-refreshing"))
        #expect(!identifiers.contains("settings-items-loading"))
        #expect(reads == 2)
        await finish.open()
        await reload.value
    }

    @Test func firstLoadFailureAndSuccessfulRetryHaveDistinctContent() async throws {
        let item = settingsTestItem(1, observedHidden: false)
        var reads = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: {
                reads += 1
                if reads == 1 { throw WindowServerError.invalidServerResponse("test read failure") }
                return [item]
            }, onChange: { _ in }
        )
        let initial = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        #expect(settingsTestAccessibility(initial.view).contains { $0.accessibilityIdentifier() == "settings-items-loading" })
        #expect(reads == 0)
        await model.reloadItems()
        let failed = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let failedElements = settingsTestAccessibility(failed.view)
        #expect(failedElements.contains { $0.accessibilityIdentifier() == "settings-items-error" })
        let retry = try #require(failedElements.first { $0.accessibilityIdentifier() == "settings-items-retry-reading" })
        #expect(retry.isAccessibilityEnabled())

        await model.reloadItems()
        let recovered = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let recoveredIDs = settingsTestAccessibility(recovered.view).compactMap { $0.accessibilityIdentifier() }
        #expect(recoveredIDs.contains("settings-item-placement-1"))
        #expect(!recoveredIDs.contains("settings-items-error"))
        #expect(!recoveredIDs.contains("settings-items-retry-reading"))
        #expect(reads == 2)
    }

    @Test func unknownItemsOfferBothBulkChoicesAndOnlyApplyPersists() async throws {
        let items = [settingsTestItem(1), settingsTestItem(2)]
        var reads = 0
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return items },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let window = hosting.testWindow!
        let hide = try element("settings-placement-hide-all", in: hosting.view)
        let show = try element("settings-placement-show-all", in: hosting.view)
        #expect(hide.isAccessibilityEnabled())
        #expect(show.isAccessibilityEnabled())

        #expect(hide.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            model.pendingChangeCount == 2 && settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityIdentifier() == "settings-placement-apply" && $0.isAccessibilityEnabled()
            }
        })
        #expect(items.allSatisfy { model.isHidden($0) })
        #expect(writes == 0)
        #expect(retries == 0)
        #expect(reads == 1)

        #expect(try element("settings-placement-discard", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            !model.hasPendingChanges && settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityIdentifier() == "settings-placement-apply" && !$0.isAccessibilityEnabled()
            }
        })
        #expect(try element("settings-placement-hide-all", in: hosting.view).isAccessibilityEnabled())
        #expect(try element("settings-placement-show-all", in: hosting.view).isAccessibilityEnabled())
        #expect(try element("settings-placement-show-all", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            model.pendingChangeCount == 2 && settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityIdentifier() == "settings-placement-apply" && $0.isAccessibilityEnabled()
            }
        })
        #expect(items.allSatisfy { !model.isHidden($0) })
        #expect(model.preferences.itemControls.hiddenInMenuBar.isEmpty)
        #expect(model.preferences.itemControls.shownInMenuBar.isEmpty)
        #expect(writes == 0)

        #expect(try element("settings-placement-apply", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            writes == 1 && !model.hasPendingChanges && settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityIdentifier() == "settings-placement-apply" && !$0.isAccessibilityEnabled()
            }
        })
        for item in items {
            #expect(model.preferences.itemControls.hasPlacementIntent(item.snapshot))
            #expect(!model.preferences.itemControls.isHidden(item.snapshot))
        }
        #expect(reads == 1)
        #expect(retries == 0)
        #expect(!window.isVisible)
    }

    @Test(arguments: [false, true])
    func showAllCanReplaceASavedHiddenRequestEvenWhenAlreadyObservedShown(pending: Bool) async throws {
        let item = settingsTestItem(1, observedHidden: false)
        var preferences = Preferences.default
        preferences.itemControls.setHidden(true, for: item.snapshot)
        var writes = 0
        var retries = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { [item] },
            onRetryPlacement: { retries += 1 }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        model.placementPending = pending
        model.placementFailed = !pending
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let window = hosting.testWindow!

        let show = try element("settings-placement-show-all", in: hosting.view)
        #expect(show.isAccessibilityEnabled())
        #expect(show.accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            model.pendingChangeCount == 1 && settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityIdentifier() == "settings-placement-apply" && $0.isAccessibilityEnabled()
            }
        })
        #expect(model.preferences.itemControls.isHidden(item.snapshot))
        #expect(writes == 0)
        #expect(retries == 0)
        #expect(try element("settings-placement-apply", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            writes == 1 && !model.hasPendingChanges && settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityIdentifier() == "settings-placement-apply" && !$0.isAccessibilityEnabled()
            }
        })
        #expect(!model.preferences.itemControls.isHidden(item.snapshot))
        #expect(model.preferences.itemControls.hasPlacementIntent(item.snapshot))
        #expect(retries == 0)
        #expect(!window.isVisible)
    }

    @Test func mountedAliasFieldsUseCurrentNamesAndDoNotOverwriteANewerRename() async throws {
        let item = settingsTestItem(1, alias: "Stale cached alias", observedHidden: false)
        var preferences = Preferences.default
        preferences.itemAliases.setAlias("Original alias", for: item.snapshot)
        var reads = 0
        var writes = 0
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item] }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let window = hosting.testWindow!
        let field = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let labelsMatch: (String) -> Bool = { name in
            let elements = settingsTestAccessibility(hosting.view)
            let alias = elements.first { $0.accessibilityIdentifier() == "settings-item-alias-1" }
            let placement = elements.first { $0.accessibilityIdentifier() == "settings-item-placement-1" }
            return alias?.accessibilityLabel() == "Display name for \(name)"
                && placement?.accessibilityLabel() == "Placement for \(name)"
                && alias?.accessibilityHelp()?.contains(name) == true
                && placement?.accessibilityHelp()?.contains(name) == true
        }
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "Original alias" && labelsMatch("Original alias") })

        model.setAlias("External alias", for: item)
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "External alias" && labelsMatch("External alias") })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.isFieldEditor)
        // The off-screen field editor drives real bindings without posting keyboard events.
        editor.insertText("Local typing", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "Local typing" })
        #expect(model.alias(for: item) == "External alias")

        model.setAlias("Newer external alias", for: item)
        #expect(await waitForUpdate(hosting.view) { labelsMatch("Newer external alias") })
        #expect(field.stringValue == "Local typing")
        editor.insertNewline(nil)
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "Newer external alias" })
        #expect(window.makeFirstResponder(nil))
        #expect(model.alias(for: item) == "Newer external alias")
        #expect(writes == 2)

        #expect(window.makeFirstResponder(field))
        let nextEditor = try #require(field.currentEditor() as? NSTextView)
        nextEditor.insertText("User rename", replacementRange: NSRange(location: 0, length: nextEditor.string.utf16.count))
        nextEditor.insertNewline(nil)
        #expect(await waitForUpdate(hosting.view) { model.alias(for: item) == "User rename" && labelsMatch("User rename") })
        #expect(window.makeFirstResponder(nil))
        #expect(writes == 3)

        model.setAlias("", for: item)
        #expect(await waitForUpdate(hosting.view) { field.stringValue.isEmpty && labelsMatch("Item 1") })
        #expect(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTextField }.first { $0.isEditable } === field)
        #expect(reads == 1)
        #expect(writes == 4)
        #expect(!model.hasPendingChanges)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test(arguments: [
        (AliasRegroup.hideAll, false),
        (AliasRegroup.discard, false),
        (AliasRegroup.placementCompletion, false),
        (AliasRegroup.discard, true)
    ])
    func dirtyAliasSurvivesRowRegrouping(cause: AliasRegroup, newerExternalAlias: Bool) async throws {
        let item = settingsTestItem(1, observedHidden: false)
        var preferences = Preferences.default
        preferences.itemAliases.setAlias("Original alias", for: item.snapshot)
        var reads = 0
        var writes: [Preferences] = []
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: { reads += 1; return [item] }, onChange: { writes.append($0) }
        )
        await model.reloadItems()
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        let window = hosting.testWindow!
        if cause != .hideAll {
            #expect(try element("settings-placement-hide-all", in: hosting.view).accessibilityPerformPress())
            #expect(await waitForUpdate(hosting.view) { model.isHidden(item) && model.hasPendingChanges })
            if cause == .placementCompletion {
                #expect(try element("settings-placement-apply", in: hosting.view).accessibilityPerformPress())
                #expect(await waitForUpdate(hosting.view) {
                    model.preferences.itemControls.isHidden(item.snapshot) && !model.hasPendingChanges
                })
                model.placementInProgress = true
            }
            hosting.render()
        }
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityLabel() == (cause == .hideAll ? "Shown (1)" : "Hidden (1)")
            }
        })

        let field = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText("Typed alias", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(await waitForUpdate(hosting.view) { field.stringValue == "Typed alias" })
        #expect(model.alias(for: item) == "Original alias")
        if newerExternalAlias {
            model.setAlias("Newer external alias", for: item)
            hosting.render()
            #expect(field.stringValue == "Typed alias")
        }

        switch cause {
        case .hideAll:
            #expect(try element("settings-placement-hide-all", in: hosting.view).accessibilityPerformPress())
        case .discard:
            #expect(try element("settings-placement-discard", in: hosting.view).accessibilityPerformPress())
        case .placementCompletion:
            await model.reloadItems()
            model.placementInProgress = false
            model.placementFailed = true
        }

        let expectedAlias = newerExternalAlias ? "Newer external alias" : "Typed alias"
        let expectedHidden = cause == .hideAll
        #expect(await waitForUpdate(hosting.view) {
            model.alias(for: item) == expectedAlias && settingsTestAccessibility(hosting.view).contains {
                $0.accessibilityLabel() == (expectedHidden ? "Hidden (1)" : "Shown (1)")
            }
        })
        #expect(model.isHidden(model.loadedItems[0]) == expectedHidden)
        #expect(model.hasPendingChanges == expectedHidden)
        #expect(model.preferences.itemControls.isHidden(item.snapshot) == (cause == .placementCompletion))
        #expect(writes.filter { $0.itemAliases.alias(for: item.snapshot) == expectedAlias }.count == 1)
        #expect(try element("settings-item-alias-1", in: hosting.view).accessibilityValue() as? String == expectedAlias)
        #expect(reads == (cause == .placementCompletion ? 2 : 1))
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test(arguments: FloatingBarStyle.allCases, [ColorScheme.light, .dark])
    func crowdedContentFitsTheTabWithoutSacrificingTheList(style: FloatingBarStyle, scheme: ColorScheme) async throws {
        var preferences = Preferences.default
        preferences.floatingBarStyle = style
        preferences.useFloatingBar = false
        let alias = String(repeating: "Long alias ", count: 40)
        let items: [FloatingBarItem] = (0..<80).map { index in
            let observed: Bool? = index % 3 == 0 ? nil : (index % 3 == 1)
            return settingsTestItem(CGWindowID(index + 1), alias: alias, observedHidden: observed)
        }
        for item in items { preferences.itemAliases.setAlias(item.displayName, for: item.snapshot) }
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(), itemsProvider: { items }, onChange: { _ in }
        )
        await model.reloadItems()
        model.setHidden(false, for: items[1])
        model.placementFailed = true
        model.placementMessage = String(repeating: "An item could not be placed. ", count: 20)
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content
            .environment(\.colorScheme, scheme).frame(width: 640))
        #expect(hosting.view.fittingSize.height <= 590)
        let table = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        let listFrame = hosting.view.convert(scroll.bounds, from: scroll)
        #expect(listFrame.height >= 120)
        #expect(hosting.view.bounds.contains(listFrame))
        let elements = settingsTestAccessibility(hosting.view)
        #expect(elements.contains { $0.accessibilityIdentifier() == "settings-placement-footer" })
        #expect(elements.contains { $0.accessibilityIdentifier() == "settings-placement-apply" })
        #expect(elements.contains { $0.accessibilityIdentifier() == "settings-preview-unknown" })
    }

    @Test(arguments: FloatingBarStyle.allCases, [ColorScheme.light, .dark])
    func fullSettingsWindowKeepsListAndApplyInsideTheSelectedItemsTab(style: FloatingBarStyle, scheme: ColorScheme) async throws {
        var preferences = Preferences.default
        preferences.floatingBarStyle = style
        preferences.useFloatingBar = false
        let alias = String(repeating: "Long alias ", count: 40)
        let items: [FloatingBarItem] = (0..<80).map { index in
            let observed: Bool? = index % 3 == 0 ? nil : (index % 3 == 1)
            return settingsTestItem(CGWindowID(index + 1), alias: alias, observedHidden: observed)
        }
        for item in items { preferences.itemAliases.setAlias(item.displayName, for: item.snapshot) }
        var failRead = false
        let model = SettingsModel(
            preferences: preferences, loginItem: LoginItemService(),
            itemsProvider: {
                if failRead { throw WindowServerError.invalidServerResponse("test reload failure") }
                return items
            }, onChange: { _ in }
        )
        await model.reloadItems()
        model.setHidden(false, for: items[1])
        model.placementFailed = true
        model.placementMessage = String(repeating: "An item could not be placed. ", count: 20)
        let hosting = settingsTestHost(SettingsView(model: model, initialTab: .items).environment(\.colorScheme, scheme))
        let window = hosting.testWindow!
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        #expect(await waitForUpdate(hosting.view) {
            settingsTestAccessibility(hosting.view).first {
                $0.accessibilityIdentifier() == "settings-placement-apply"
            }?.accessibilityFrame().isEmpty == false
        })

        @MainActor
        func assertFit(withReadError: Bool = false) throws {
            #expect(hosting.view.bounds.size == SettingsView.windowSize)
            #expect(window.contentLayoutRect.size == SettingsView.windowSize)
            let rootFrame = window.convertToScreen(hosting.view.convert(hosting.view.bounds, to: nil))
            let sidebarFrame = try element("settings-sidebar", in: hosting.view).accessibilityFrame()
            let detailFrame = try element("settings-detail", in: hosting.view).accessibilityFrame()
            let headerFrame = try element("settings-identity-header", in: hosting.view).accessibilityFrame()
            let itemsFrame = try element("settings-items-content", in: hosting.view).accessibilityFrame()
            let footerFrame = try element("settings-placement-footer", in: hosting.view).accessibilityFrame()
            let apply = try element("settings-placement-apply", in: hosting.view)
            let applyFrame = apply.accessibilityFrame()
            #expect(headerFrame.height >= 48)
            #expect(!itemsFrame.isEmpty)
            #expect(!footerFrame.isEmpty)
            #expect(!applyFrame.isEmpty)
            #expect(rootFrame.contains(sidebarFrame))
            #expect(rootFrame.contains(headerFrame))
            #expect(rootFrame.contains(itemsFrame))
            // The identity lives in the sidebar column; the pane owns the full detail column.
            #expect(sidebarFrame.contains(headerFrame))
            #expect(headerFrame.maxX <= itemsFrame.minX)
            #expect(itemsFrame.minX >= sidebarFrame.maxX)
            #expect(itemsFrame.width >= 620)
            #expect(detailFrame.contains(itemsFrame))
            #expect(itemsFrame.contains(footerFrame))
            #expect(footerFrame.contains(applyFrame))
            #expect(apply.isAccessibilityEnabled())

            // The sidebar list is also table-backed; the Items list is the one right of the sidebar.
            let table = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTableView }.first { table in
                window.convertToScreen(table.convert(table.bounds, to: nil)).minX >= sidebarFrame.maxX
            })
            let scroll = try #require(table.enclosingScrollView)
            let listFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            let rowsFrame = window.convertToScreen(table.convert(table.bounds, to: nil))
            #expect(listFrame.height >= 120)
            // Tahoe lets the scroll chrome run beneath the floating sidebar; the rows must not.
            #expect(listFrame.maxY <= itemsFrame.maxY)
            #expect(listFrame.maxX <= itemsFrame.maxX)
            #expect(rowsFrame.minX >= itemsFrame.minX)
            #expect(rowsFrame.maxX <= itemsFrame.maxX)
            #expect(listFrame.minY >= footerFrame.maxY)
            #expect(try element("settings-preview-unknown", in: hosting.view).accessibilityFrame().isEmpty == false)
            #expect(!window.isVisible)
            #expect(!window.isKeyWindow)
            if withReadError {
                let retry = try element("settings-items-retry-reading", in: hosting.view)
                let retryFrame = retry.accessibilityFrame()
                #expect(!retryFrame.isEmpty)
                #expect(itemsFrame.contains(retryFrame))
                #expect(retryFrame.minY >= listFrame.maxY)
                #expect(retry.isAccessibilityEnabled())
            }
        }
        try assertFit()
        if style == .vertical && scheme == .dark {
            failRead = true
            await model.reloadItems()
            #expect(model.loadedItems.count == 80)
            #expect(model.itemsLoadError != nil)
            #expect(await waitForUpdate(hosting.view) {
                settingsTestAccessibility(hosting.view).contains {
                    $0.accessibilityIdentifier() == "settings-items-retry-reading"
                }
            })
            try assertFit(withReadError: true)
        }
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier })
    }

    // MARK: - Always Hidden tier

    @Test func rowsGroupIntoThreeTiersAndOnlyTuckedRowsOfferBarControls() async throws {
        let items = [
            settingsTestItem(1, observedPlacement: .hidden),
            settingsTestItem(2, observedPlacement: .hidden),
            settingsTestItem(3, observedPlacement: .alwaysHidden),
            settingsTestItem(4, observedPlacement: .shown)
        ]
        var writes: [Preferences] = []
        var retries = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { items },
            onRetryPlacement: { retries += 1 }, onChange: { writes.append($0) }
        )
        await model.reloadItems()
        // A tall host so the virtualized List realizes every section's rows.
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640, height: 900))
        let labels = settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityLabel() }
        #expect(labels.contains("Hidden (2)"))
        #expect(labels.contains("Always Hidden (1)"))
        #expect(labels.contains("Shown (1)"))
        let identifiers = Set(settingsTestAccessibility(hosting.view).compactMap { $0.accessibilityIdentifier() })
        for id in [1, 2, 3] {
            #expect(identifiers.contains("settings-item-bar-visible-\(id)"))
            #expect(identifiers.contains("settings-item-bar-earlier-\(id)"))
            #expect(identifiers.contains("settings-item-bar-later-\(id)"))
        }
        #expect(!identifiers.contains("settings-item-bar-visible-4"))
        #expect(!identifiers.contains("settings-item-bar-earlier-4"))
        #expect(!identifiers.contains("settings-item-bar-later-4"))
        #expect(identifiers.contains("settings-items-bar-controls-help"))
        let enabled: (String) throws -> Bool = { try element($0, in: hosting.view).isAccessibilityEnabled() }
        #expect(try !enabled("settings-item-bar-earlier-1"))
        #expect(try enabled("settings-item-bar-later-1"))
        #expect(try !enabled("settings-item-bar-later-2"))
        #expect(try !enabled("settings-item-bar-earlier-3"))
        #expect(try !enabled("settings-item-bar-later-3"))

        #expect(try element("settings-item-bar-later-1", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { writes.count == 1 })
        #expect(model.preferences.itemControls.barOrder == ["Item 2": 0, "Item 1": 1])
        #expect(!model.hasPendingChanges)
        #expect(await waitForUpdate(hosting.view) {
            (try? element("settings-item-bar-earlier-1", in: hosting.view).isAccessibilityEnabled()) == true
        })

        #expect(try element("settings-item-bar-visible-1", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { writes.count == 2 })
        #expect(model.preferences.itemControls.suppressedFromBar == ["Item 1"])
        #expect(!model.hasPendingChanges)
        #expect(model.preferences.itemControls.hiddenInMenuBar.isEmpty)
        #expect(model.preferences.itemControls.alwaysHiddenInMenuBar.isEmpty)
        #expect(retries == 0)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func choosingAlwaysHiddenStagesTheRowAndPreviewsTheThirdBox() async throws {
        let item = settingsTestItem(1, observedPlacement: .shown)
        var writes = 0
        let model = SettingsModel(
            preferences: .default, loginItem: LoginItemService(), itemsProvider: { [item] }, onChange: { _ in writes += 1 }
        )
        await model.reloadItems()
        let before = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640))
        #expect(!settingsTestAccessibility(before.view).contains { $0.accessibilityIdentifier() == "settings-preview-always-hidden" })
        #expect(!settingsTestAccessibility(before.view).contains { $0.accessibilityIdentifier() == "settings-item-bar-visible-1" })

        model.setPlacement(.alwaysHidden, for: item)
        let hosting = settingsTestHost(ItemsSettingsTab(model: model).content.frame(width: 640, height: 900))
        let elements = settingsTestAccessibility(hosting.view)
        #expect(elements.contains { $0.accessibilityLabel() == "Always Hidden (1)" })
        #expect(elements.contains { $0.accessibilityIdentifier() == "settings-item-pending-1" })
        let box = try #require(elements.first { $0.accessibilityIdentifier() == "settings-preview-always-hidden" })
        let previewItem = try #require(settingsTestAccessibility(box).first { $0.accessibilityIdentifier() == "settings-preview-item-1" })
        #expect(previewItem.accessibilityValue() as? String == "Always Hidden")
        #expect(try element("settings-placement-apply", in: hosting.view).isAccessibilityEnabled())
        #expect(elements.contains { $0.accessibilityIdentifier() == "settings-item-bar-visible-1" })
        #expect(writes == 0)

        #expect(try element("settings-placement-apply", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { writes == 1 && !model.hasPendingChanges })
        #expect(model.preferences.itemControls.placement(forKey: "Item 1") == .alwaysHidden)
        #expect(!hosting.testWindow.isVisible)
    }

    // MARK: - Launch at login and Backup sections

    private func hostSection<Content: View>(_ content: Content, scheme: ColorScheme = .light) -> SettingsTestHostingController {
        let hosting = settingsTestHost(
            Form { content }.formStyle(.grouped).environment(\.colorScheme, scheme).frame(width: 640)
        )
        hosting.view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        hosting.testWindow.appearance = hosting.view.appearance
        hosting.render()
        return hosting
    }

    /// Labels, values, and titles: a switch-style toggle carries its text as an AX title.
    private func sectionText(in view: NSView) -> String {
        settingsTestAccessibility(view).flatMap { element in
            [settingsTestAccessibilityText(element), element.property("accessibilityTitle") as? String ?? ""]
        }.joined(separator: " ")
    }

    private func identifiers(in view: NSView) -> [String] {
        settingsTestAccessibility(view).compactMap { $0.accessibilityIdentifier() }
    }

    @Test(arguments: [LoginItemStatus.enabled, .requiresApproval, .notRegistered, .notFound], [false, true])
    func launchAtLoginNoticeAppearsOnlyForAnUnmetSavedPreference(status: LoginItemStatus, launchAtLogin: Bool) throws {
        let loginItem = SettingsTestLoginItem(status: status)
        var writes = 0
        let model = SettingsModel(
            preferences: Preferences(launchAtLogin: launchAtLogin), loginItem: loginItem, itemsProvider: { [] },
            onChange: { _ in writes += 1 }
        )
        let hosting = hostSection(LaunchAtLoginSection(model: model))
        let ids = identifiers(in: hosting.view)
        let text = sectionText(in: hosting.view)
        let expectsNotice = launchAtLogin && status != .enabled
        let expectsButton = launchAtLogin && status == .requiresApproval

        #expect(ids.contains("settings-launch-at-login"))
        #expect(text.contains("Launch at login"))
        #expect(ids.contains("settings-launch-at-login-notice") == expectsNotice)
        #expect(ids.contains("settings-launch-at-login-open") == expectsButton)
        #expect(text.contains("Needs approval in System Settings > General > Login Items") == expectsButton)
        #expect(text.contains("Not registered; toggle off and on to retry") == (expectsNotice && !expectsButton))
        #expect(text.contains("Open Login Items") == expectsButton)
        if expectsButton {
            #expect(try element("settings-launch-at-login-open", in: hosting.view).isAccessibilityEnabled())
        }
        #expect(loginItem.setEnabledCalls.isEmpty)
        #expect(loginItem.openSystemSettingsCalls == 0)
        #expect(writes == 0)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func openLoginItemsButtonCallsTheSeamAndNothingElse() async throws {
        let loginItem = SettingsTestLoginItem(status: .requiresApproval)
        var writes = 0
        let model = SettingsModel(
            preferences: Preferences(launchAtLogin: true), loginItem: loginItem, itemsProvider: { [] },
            onChange: { _ in writes += 1 }
        )
        let hosting = hostSection(LaunchAtLoginSection(model: model))

        #expect(try element("settings-launch-at-login-open", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) { loginItem.openSystemSettingsCalls == 1 })

        #expect(loginItem.setEnabledCalls.isEmpty)
        #expect(model.preferences.launchAtLogin)
        #expect(model.loginItemNotice == .needsApproval)
        #expect(identifiers(in: hosting.view).contains("settings-launch-at-login-open"))
        #expect(writes == 0)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func togglingOnThatStopsAtApprovalShowsTheNoticeUntilApproved() async throws {
        let loginItem = SettingsTestLoginItem(status: .notRegistered)
        loginItem.statusAfterRegister = .requiresApproval
        var writes: [Preferences] = []
        let model = SettingsModel(
            preferences: .default, loginItem: loginItem, itemsProvider: { [] }, onChange: { writes.append($0) }
        )
        let hosting = hostSection(LaunchAtLoginSection(model: model))
        #expect(!identifiers(in: hosting.view).contains("settings-launch-at-login-notice"))

        // The switch toggles on AXPress but reports false for it, so the model is the oracle.
        _ = try element("settings-launch-at-login", in: hosting.view).accessibilityPerformPress()
        #expect(await waitForUpdate(hosting.view) {
            model.preferences.launchAtLogin && identifiers(in: hosting.view).contains("settings-launch-at-login-open")
        })
        #expect(loginItem.setEnabledCalls == [true])
        #expect(writes.map(\.launchAtLogin) == [true])
        #expect(sectionText(in: hosting.view).contains("Needs approval in System Settings > General > Login Items"))
        #expect((try element("settings-launch-at-login", in: hosting.view).accessibilityValue() as? NSNumber)?.intValue == 1)

        loginItem.status = .enabled
        model.refreshLoginItemStatus()
        #expect(await waitForUpdate(hosting.view) {
            !identifiers(in: hosting.view).contains("settings-launch-at-login-notice")
        })
        #expect(!identifiers(in: hosting.view).contains("settings-launch-at-login-open"))
        #expect(model.preferences.launchAtLogin)
        #expect(writes.count == 1)
        #expect(loginItem.openSystemSettingsCalls == 0)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func rejectedToggleSnapsBackWithoutANotice() async throws {
        let loginItem = SettingsTestLoginItem(status: .notRegistered)
        loginItem.rejectsChanges = true
        var writes: [Preferences] = []
        let model = SettingsModel(
            preferences: .default, loginItem: loginItem, itemsProvider: { [] }, onChange: { writes.append($0) }
        )
        let hosting = hostSection(LaunchAtLoginSection(model: model))

        _ = try element("settings-launch-at-login", in: hosting.view).accessibilityPerformPress()
        #expect(await waitForUpdate(hosting.view) {
            loginItem.setEnabledCalls == [true]
                && (try? element("settings-launch-at-login", in: hosting.view).accessibilityValue() as? NSNumber)?.intValue == 0
        })

        #expect(!model.launchAtLogin)
        #expect(!model.preferences.launchAtLogin)
        #expect(writes.allSatisfy { !$0.launchAtLogin })
        #expect(model.loginItemNotice == nil)
        let ids = identifiers(in: hosting.view)
        #expect(!ids.contains("settings-launch-at-login-notice"))
        #expect(!ids.contains("settings-launch-at-login-open"))
        #expect(loginItem.openSystemSettingsCalls == 0)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func backupStatusLineColorsOnlyAFailedWriteRed(scheme: ColorScheme) async throws {
        var writes = 0
        let model = SettingsModel(
            preferences: .default, loginItem: SettingsTestLoginItem(), itemsProvider: { [] }, onChange: { _ in writes += 1 }
        )
        let isRed: (NSColor) -> Bool = {
            $0.redComponent > 0.8 && $0.greenComponent < 0.5 && $0.blueComponent < 0.5 && $0.alphaComponent > 0.5
        }
        @MainActor
        func redPixels(_ hosting: SettingsTestHostingController) throws -> Int {
            let bitmap = try settingsTestBitmap(hosting.view)
            return settingsTestPixelCount(bitmap, matching: isRed)
        }

        let idle = hostSection(BackupSettingsSection(model: model), scheme: scheme)
        #expect(try element("settings-backup-export", in: idle.view).isAccessibilityEnabled())
        #expect(try element("settings-backup-import", in: idle.view).isAccessibilityEnabled())
        #expect(!identifiers(in: idle.view).contains("settings-backup-status"))
        #expect(try redPixels(idle) == 0)

        model.exportLayout(using: { _ in .failed("The disk is full.") })
        let failed = hostSection(BackupSettingsSection(model: model), scheme: scheme)
        let failure = try element("settings-backup-status", in: failed.view)
        #expect(settingsTestAccessibilityText(failure) == "Couldn't write the layout file: The disk is full.")
        #expect(try redPixels(failed) > 20)

        // The same host must drop the line on a cancel and restyle it on a success.
        model.exportLayout(using: { _ in .cancelled })
        #expect(await waitForUpdate(failed.view) { !identifiers(in: failed.view).contains("settings-backup-status") })

        model.exportLayout(using: { _ in .saved(URL(fileURLWithPath: "/tmp/exports/Layout.json")) })
        #expect(await waitForUpdate(failed.view) { identifiers(in: failed.view).contains("settings-backup-status") })
        let saved = hostSection(BackupSettingsSection(model: model), scheme: scheme)
        let success = try element("settings-backup-status", in: saved.view)
        #expect(settingsTestAccessibilityText(success) == "Exported to Layout.json.")
        #expect(try redPixels(saved) == 0)
        #expect(writes == 0)
        #expect(!saved.testWindow.isVisible)
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

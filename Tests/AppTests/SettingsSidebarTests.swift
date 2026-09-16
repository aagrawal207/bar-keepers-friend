import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SettingsSidebarTests {
    /// Each pane exposes one stable container identifier so navigation tests can tell them apart.
    static let paneMarkers: [SettingsView.Tab: String] = [
        .general: "settings-general-content",
        .items: "settings-items-content",
        .style: "settings-style-enabled",
        .behavior: "settings-behavior-content",
        .shortcuts: "settings-shortcuts-content",
        .advanced: "settings-advanced-content",
        .presets: "settings-preset-content",
        .triggers: "settings-trigger-content",
        .groups: "settings-group-content",
        .about: "settings-about-content"
    ]

    @Test func tabsExposeStableIdentifiersTitlesAndSymbols() {
        #expect(SettingsView.Tab.allCases == [.general, .items, .style, .behavior, .shortcuts, .advanced, .presets, .triggers, .groups, .about])
        #expect(SettingsView.Tab.allCases.map(\.rawValue) == ["general", "items", "style", "behavior", "shortcuts", "advanced", "presets", "triggers", "groups", "about"])
        #expect(SettingsView.Tab.allCases.map(\.title) == ["General", "Items", "Style", "Behavior", "Shortcuts", "Advanced", "Presets", "Triggers", "Groups", "About"])
        #expect(SettingsView.Tab.sidebarTabs == [.general, .items, .style, .behavior, .shortcuts, .advanced, .about])
        #expect(SettingsView.Tab.advancedTabs == [.presets, .triggers, .groups])
        for tab in SettingsView.Tab.allCases {
            #expect(tab.id == tab)
            #expect(tab.sidebarTab == ([.presets, .triggers, .groups].contains(tab) ? .advanced : tab))
            #expect(NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil) != nil, "\(tab) needs a real SF Symbol")
        }
    }

    @Test(arguments: ["", " \n\t "])
    func emptySearchShowsTheCompleteSidebarInOrder(query: String) {
        #expect(SettingsView.Tab.matching(query) == SettingsView.Tab.sidebarTabs)
    }

    @Test(arguments: SettingsView.Tab.allCases)
    func pageNamesRankTheirOwnPaneFirst(tab: SettingsView.Tab) {
        #expect(SettingsView.Tab.matching(tab.title).first == tab)
    }

    @Test(arguments: [
        ("screen recording", SettingsView.Tab.general), ("launch at login", .general), ("get started", .general),
        ("Arrange Items", .general), ("export", .advanced), ("backup", .advanced),
        ("hover", .behavior), ("Show hidden items in a floating bar", .behavior),
        ("Dismiss the bar when the pointer leaves it", .behavior), ("notch", .advanced),
        ("keyboard shortcut", .shortcuts), ("Shortcuts", .shortcuts), ("hotkey", .shortcuts),
        ("spacing", .advanced), ("Reset to system default", .advanced), ("advanced tools", .advanced),
        ("menu bar icon", .style), ("app icon", .style), ("sparkle", .style), ("sunset", .style),
        ("apply changes", .items), ("always hidden", .items), ("aliases", .items),
        ("opacity", .style), ("gradient", .style), ("styles", .style), ("save layout", .presets),
        ("low power", .triggers), ("Wi-Fi", .triggers), ("membership", .groups),
        ("Advanced Wi-Fi", .triggers), ("Advanced profiles", .presets), ("Advanced membership", .groups),
        ("Advanced selection padding", .advanced), ("Advanced Triggers Wi-Fi", .triggers),
        ("license", .about), ("support", .about), ("version", .about), ("project", .about),
    ])
    func searchFindsSettingsWithinTheirPane(query: String, expected: SettingsView.Tab) {
        #expect(SettingsView.Tab.matching(query).contains(expected))
    }

    @Test(arguments: [
        ("hover", SettingsView.Tab.general), ("layout mode", .general), ("keyboard shortcut", .general),
        ("spacing", .general), ("Reset to system default", .general), ("export", .general), ("backup", .general),
        ("notch", .behavior),
    ])
    func movedSettingsNoLongerPointAtTheirOldPane(query: String, previous: SettingsView.Tab) {
        #expect(!SettingsView.Tab.matching(query).contains(previous), "\(query) must not still match \(previous)")
    }

    // Container bounds alone miss clipped rows in a Form; the last controls must fit too.
    // Anchors are permission-independent, with the longest ordinary status notes present.
    @Test(arguments: [
        (SettingsView.Tab.general, ["settings-open-items", "settings-permission-screenRecording"]),
        (.behavior, ["settings-reveal-scroll", "settings-scroll-description"]),
        (.advanced, ["settings-advanced-tools", "settings-backup-export", "settings-backup-status"]),
        (.style, ["settings-style-note"]),
        (.shortcuts, ["settings-shortcut-items-empty"]),
        (.about, ["settings-about-license"]),
    ])
    func bottommostControlIsVisibleWithoutScrolling(tab: SettingsView.Tab, lastControls: [String]) async throws {
        var preferences = Preferences.default
        // Richest permission-independent state: every unconditional note and control shown.
        preferences.notchOverflow = .whenNeeded
        preferences.menuBarSpacing = MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4)
        preferences.menuBarStyle = MenuBarStyle(isEnabled: true, borderWidth: 2, shape: .rounded)
        preferences.menuBarStyle.gradientEnd = RGBA(red: 0, green: 0, blue: 1)
        let model = SettingsModel(preferences: preferences, loginItem: SettingsTestLoginItem(), itemsProvider: { [] }, onChange: { _ in })
        model.spacingNeedsLogout = true
        model.exportLayout { _ in .failed("The disk is full. Free up some space and try exporting the layout again.") }
        let hosting = settingsTestHost(SettingsView(model: model, initialTab: tab))
        #expect(await waitForUpdate(hosting.view) { self.paneIsShown(tab, in: hosting.view) })
        if tab == .shortcuts {
            // Shortcuts reads the (empty) menu bar first; its empty-state row is the true bottom.
            #expect(await waitForUpdate(hosting.view) { !model.itemsLoading })
        } else {
            #expect(model.itemsLoading, "\(tab) must not read the menu bar just to render")
        }
        let detail = try element("settings-detail", in: hosting.view).accessibilityFrame()
        for identifier in lastControls {
            let last = try element(identifier, in: hosting.view).accessibilityFrame()
            #expect(!last.isEmpty)
            #expect(detail.contains(last), "\(tab) scrolls: \(identifier) at \(last) is outside the detail \(detail)")
        }
        let bitmap = try settingsTestBitmap(hosting.view)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(png), named: "settings-\(tab.rawValue)-expanded.png")
    }

    @Test(arguments: TriggerCondition.Kind.allCases)
    func everyTriggerConditionLabelIsSearchable(kind: TriggerCondition.Kind) {
        #expect(SettingsView.Tab.matching(kind.displayName).contains(.triggers))
    }

    @Test func searchIgnoresCaseAccentsAndWhitespaceButRequiresEveryWord() {
        #expect(SettingsView.Tab.matching("  OP\u{00C1}CITY\n border\t") == [.style])
        #expect(SettingsView.Tab.matching("opacity charging").isEmpty)
        #expect(SettingsView.Tab.matching("Advanced opacity").isEmpty)
        #expect(SettingsView.Tab.matching("Advanced Wi-Fi membership").isEmpty)
        #expect(SettingsView.Tab.matching("no-such-setting").isEmpty)
    }

    @Test(arguments: SettingsView.Tab.allCases, [ColorScheme.light, .dark])
    func everyPaneFitsBesideTheSidebar(tab: SettingsView.Tab, scheme: ColorScheme) async throws {
        let model = makeModel()
        let hosting = settingsTestHost(SettingsView(model: model, initialTab: tab).environment(\.colorScheme, scheme))
        let window = hosting.testWindow!
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        #expect(await waitForUpdate(hosting.view) { self.paneIsShown(tab, in: hosting.view) })
        if tab == .groups {
            // The member list is populated by Groups' own item load before its bounds are measured.
            try #require(await waitForUpdate(hosting.view) { !model.itemsLoading })
        }

        let size = SettingsView.windowSize
        #expect(hosting.view.bounds.size == size)
        #expect(window.contentLayoutRect.size == size)
        let rootFrame = window.convertToScreen(hosting.view.convert(hosting.view.bounds, to: nil))
        let sidebarFrame = try element("settings-sidebar", in: hosting.view).accessibilityFrame()
        let detailFrame = try element("settings-detail", in: hosting.view).accessibilityFrame()
        let headerFrame = try element("settings-identity-header", in: hosting.view).accessibilityFrame()
        let titleElement = try element("settings-detail-title", in: hosting.view)
        let titleFrame = titleElement.accessibilityFrame()
        let markerFrame = try paneMarker(tab, in: hosting.view).accessibilityFrame()

        #expect(!sidebarFrame.isEmpty)
        #expect(!detailFrame.isEmpty)
        #expect(rootFrame.contains(sidebarFrame))
        #expect(rootFrame.contains(detailFrame))
        #expect(abs(sidebarFrame.width - SettingsView.sidebarWidth) <= 2)
        #expect(sidebarFrame.minX <= 16)
        #expect(sidebarFrame.minY <= 16)
        #expect(sidebarFrame.maxY >= size.height - 40)
        #expect(detailFrame.maxX >= size.width - 2)
        #expect(detailFrame.maxY >= size.height - 40)
        #expect(detailFrame.minY <= 16)
        // Scrolling panes may extend beneath the floating sidebar; their content must not.
        #expect(size.width - sidebarFrame.maxX >= 620)
        #expect(!titleFrame.isEmpty)
        #expect(titleElement.accessibilityLabel() == tab.title)
        #expect(detailFrame.contains(titleFrame))
        #expect(titleFrame.minX >= sidebarFrame.maxX + 16)
        let isAdvancedChild = SettingsView.Tab.advancedTabs.contains(tab)
        #expect(titleFrame.maxY >= detailFrame.maxY - (isAdvancedChild ? 80 : 40))
        #expect(!markerFrame.isEmpty)
        #expect(detailFrame.contains(markerFrame))
        #expect(markerFrame.minX >= sidebarFrame.maxX)
        #expect(markerFrame.maxY <= titleFrame.minY)

        #expect(headerFrame.height >= 48)
        #expect(sidebarFrame.contains(headerFrame))
        #expect(headerFrame.maxY >= sidebarFrame.maxY - 2)
        for row in SettingsView.Tab.sidebarTabs {
            let rowElement = try element("settings-sidebar-\(row.rawValue)", in: hosting.view)
            let rowFrame = rowElement.accessibilityFrame()
            #expect(!rowFrame.isEmpty, "\(row) row must be laid out")
            #expect(sidebarFrame.contains(rowFrame), "\(row) row must sit inside the sidebar")
            #expect(rowFrame.maxY <= headerFrame.minY, "\(row) row must sit below the identity header")
            #expect(rowElement.accessibilityLabel() == row.title)
            #expect(rowElement.isAccessibilityEnabled())
        }
        let table = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSTableView }.first {
            settingsTestAccessibility($0).contains { $0.accessibilityIdentifier() == "settings-sidebar-general" }
        })
        #expect(table.numberOfRows == SettingsView.Tab.sidebarTabs.count)
        let selectedIndex = try #require(SettingsView.Tab.sidebarTabs.firstIndex(of: tab.sidebarTab))
        #expect(table.selectedRowIndexes == IndexSet(integer: selectedIndex))
        for child in SettingsView.Tab.advancedTabs {
            #expect(!settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-sidebar-\(child.rawValue)" })
        }
        if isAdvancedChild {
            let back = try element("settings-back-to-advanced", in: hosting.view)
            #expect(back.accessibilityLabel() == "Advanced")
            #expect(back.isAccessibilityEnabled())
            #expect(!back.accessibilityFrame().isEmpty)
            #expect(detailFrame.contains(back.accessibilityFrame()))
        } else {
            #expect(!settingsTestAccessibility(hosting.view).contains { $0.accessibilityIdentifier() == "settings-back-to-advanced" })
        }
        for other in SettingsView.Tab.allCases where other != tab {
            #expect(!paneIsShown(other, in: hosting.view), "\(other) must not render while \(tab) is selected")
        }
        #expect(window.toolbar?.items.contains { $0.itemIdentifier == .toggleSidebar } != true)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
        // Off-screen renders make appearance reviewable without capturing or opening the desktop.
        let bitmap = try settingsTestBitmap(hosting.view)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(png), named: "settings-\(tab.rawValue)-\(scheme == .light ? "light" : "dark").png")
    }

    @Test func pressingAnySidebarRowFromAnAdvancedChildSwitchesTheDetail() async throws {
        let model = makeModel()
        let hosting = settingsTestHost(SettingsView(model: model, initialTab: .general))
        #expect(await waitForUpdate(hosting.view) { self.paneIsShown(.general, in: hosting.view) })
        #expect(!paneIsShown(.items, in: hosting.view))

        for row in SettingsView.Tab.sidebarTabs {
            #expect(try element("settings-sidebar-advanced", in: hosting.view).accessibilityPerformPress())
            try #require(await waitForUpdate(hosting.view) { self.paneIsShown(.advanced, in: hosting.view) })
            #expect(try element("settings-advanced-presets", in: hosting.view).accessibilityPerformPress())
            try #require(await waitForUpdate(hosting.view) { self.paneIsShown(.presets, in: hosting.view) })

            #expect(try element("settings-sidebar-\(row.rawValue)", in: hosting.view).accessibilityPerformPress())
            try #require(await waitForUpdate(hosting.view) {
                self.paneIsShown(row, in: hosting.view) && !self.paneIsShown(.presets, in: hosting.view)
            })
            #expect(try element("settings-detail-title", in: hosting.view).accessibilityLabel() == row.title)
            let detailFrame = try element("settings-detail", in: hosting.view).accessibilityFrame()
            #expect(detailFrame.contains(try paneMarker(row, in: hosting.view).accessibilityFrame()))
            for other in SettingsView.Tab.allCases where other != row {
                #expect(!paneIsShown(other, in: hosting.view), "\(other) must not mount while navigating to \(row)")
            }
        }
        #expect(model.requestedTab == nil)
        #expect(!hosting.testWindow.isVisible)
    }

    @Test func requestedTabSwitchesTheDetailAndIsConsumed() async throws {
        let model = makeModel()
        model.requestedTab = .presets
        let hosting = settingsTestHost(SettingsView(model: model, initialTab: .general))
        #expect(await waitForUpdate(hosting.view) { self.paneIsShown(.presets, in: hosting.view) })
        #expect(model.requestedTab == nil)
        #expect(!paneIsShown(.general, in: hosting.view))
        #expect(!paneIsShown(.advanced, in: hosting.view))
        #expect(try element("settings-back-to-advanced", in: hosting.view).accessibilityLabel() == "Advanced")

        model.requestedTab = .groups
        #expect(await waitForUpdate(hosting.view) {
            self.paneIsShown(.groups, in: hosting.view) && !self.paneIsShown(.presets, in: hosting.view)
                && !model.itemsLoading
        })
        #expect(model.requestedTab == nil)
        #expect(try element("settings-detail-title", in: hosting.view).accessibilityLabel() == "Groups")
        #expect(!paneIsShown(.advanced, in: hosting.view))
        #expect(try element("settings-back-to-advanced", in: hosting.view).isAccessibilityEnabled())
        #expect(!hosting.testWindow.isVisible)
    }

    private func makeModel() -> SettingsModel {
        SettingsModel(preferences: .default, loginItem: SettingsTestLoginItem(), itemsProvider: { [] }, onChange: { _ in })
    }

    private func paneIsShown(_ tab: SettingsView.Tab, in view: NSView) -> Bool {
        findPaneMarker(tab, in: view) != nil
    }

    private func paneMarker(_ tab: SettingsView.Tab, in view: NSView) throws -> SettingsTestAXElement {
        try #require(findPaneMarker(tab, in: view), "\(tab) pane must be rendered")
    }

    private func findPaneMarker(_ tab: SettingsView.Tab, in view: NSView) -> SettingsTestAXElement? {
        settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == Self.paneMarkers[tab] }
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier })
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

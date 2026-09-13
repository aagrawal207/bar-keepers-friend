import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SettingsSidebarTests {
    /// General has no container identifier of its own, so a stable control inside it stands in.
    private static let paneMarkers: [SettingsView.Tab: String] = [
        .general: "settings-layout-mode-picker",
        .items: "settings-items-content",
        .presets: "settings-preset-content",
        .triggers: "settings-trigger-content",
        .groups: "settings-group-content",
        .widgets: "settings-widget-content",
        .style: "settings-style-enabled"
    ]

    @Test func tabsExposeStableIdentifiersTitlesAndSymbols() {
        #expect(SettingsView.Tab.allCases == [.general, .items, .presets, .triggers, .groups, .widgets, .style])
        #expect(SettingsView.Tab.allCases.map(\.rawValue) == ["general", "items", "presets", "triggers", "groups", "widgets", "style"])
        #expect(SettingsView.Tab.allCases.map(\.title) == ["General", "Items", "Presets", "Triggers", "Groups", "Widgets", "Style"])
        for tab in SettingsView.Tab.allCases {
            #expect(tab.id == tab)
            #expect(NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: nil) != nil, "\(tab) needs a real SF Symbol")
        }
    }

    @Test(arguments: SettingsView.Tab.allCases, [ColorScheme.light, .dark])
    func everyPaneFitsBesideTheSidebar(tab: SettingsView.Tab, scheme: ColorScheme) async throws {
        let model = makeModel()
        let hosting = settingsTestHost(SettingsView(model: model, initialTab: tab).environment(\.colorScheme, scheme))
        let window = hosting.testWindow!
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        #expect(await waitForUpdate(hosting.view) { self.paneIsShown(tab, in: hosting.view) })

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
        #expect(titleFrame.maxY >= detailFrame.maxY - 40)
        #expect(!markerFrame.isEmpty)
        #expect(detailFrame.contains(markerFrame))
        #expect(markerFrame.minX >= sidebarFrame.maxX)
        #expect(markerFrame.maxY <= titleFrame.minY)

        #expect(headerFrame.height >= 48)
        #expect(sidebarFrame.contains(headerFrame))
        #expect(headerFrame.maxY >= sidebarFrame.maxY - 2)
        for row in SettingsView.Tab.allCases {
            let rowElement = try element("settings-sidebar-\(row.rawValue)", in: hosting.view)
            let rowFrame = rowElement.accessibilityFrame()
            #expect(!rowFrame.isEmpty, "\(row) row must be laid out")
            #expect(sidebarFrame.contains(rowFrame), "\(row) row must sit inside the sidebar")
            #expect(rowFrame.maxY <= headerFrame.minY, "\(row) row must sit below the identity header")
            #expect(rowElement.accessibilityLabel() == row.title)
            #expect(rowElement.isAccessibilityEnabled())
        }
        for other in SettingsView.Tab.allCases where other != tab {
            #expect(!paneIsShown(other, in: hosting.view), "\(other) must not render while \(tab) is selected")
        }
        #expect(window.toolbar?.items.contains { $0.itemIdentifier == .toggleSidebar } != true)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)
    }

    @Test func pressingSidebarRowsSwitchesTheDetail() async throws {
        let model = makeModel()
        let hosting = settingsTestHost(SettingsView(model: model, initialTab: .general))
        #expect(await waitForUpdate(hosting.view) { self.paneIsShown(.general, in: hosting.view) })
        #expect(!paneIsShown(.items, in: hosting.view))

        #expect(try element("settings-sidebar-items", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            self.paneIsShown(.items, in: hosting.view) && !self.paneIsShown(.general, in: hosting.view)
        })
        #expect(try element("settings-detail-title", in: hosting.view).accessibilityLabel() == "Items")
        let detailFrame = try element("settings-detail", in: hosting.view).accessibilityFrame()
        #expect(detailFrame.contains(try element("settings-items-content", in: hosting.view).accessibilityFrame()))

        #expect(try element("settings-sidebar-style", in: hosting.view).accessibilityPerformPress())
        #expect(await waitForUpdate(hosting.view) {
            self.paneIsShown(.style, in: hosting.view) && !self.paneIsShown(.items, in: hosting.view)
        })
        #expect(try element("settings-detail-title", in: hosting.view).accessibilityLabel() == "Style")
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

        model.requestedTab = .groups
        #expect(await waitForUpdate(hosting.view) {
            self.paneIsShown(.groups, in: hosting.view) && !self.paneIsShown(.presets, in: hosting.view)
        })
        #expect(model.requestedTab == nil)
        #expect(try element("settings-detail-title", in: hosting.view).accessibilityLabel() == "Groups")
        #expect(!hosting.testWindow.isVisible)
    }

    private func makeModel() -> SettingsModel {
        SettingsModel(preferences: .default, loginItem: LoginItemService(), itemsProvider: { [] }, onChange: { _ in })
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

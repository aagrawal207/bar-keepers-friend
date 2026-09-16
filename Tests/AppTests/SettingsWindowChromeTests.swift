import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SettingsWindowChromeTests {
    @Test func productionConstructorReservesNativeChromeAboveTheUsefulContentArea() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(
            preferences: .default, loginItem: SettingsTestLoginItem(), itemsProvider: { [] }, onChange: { _ in }
        )
        let window = controller.prepareWindow(tab: .about)
        defer { window.close() }
        let hosting = try #require(window.contentViewController as? NSHostingController<SettingsView>)
        let view = try #require(hosting.view as? NSHostingView<SettingsView>)
        for _ in 0..<2 {
            view._renderForTest(interval: 1.0 / 60)
            view.layoutSubtreeIfNeeded()
        }

        try expectChrome(window)
        #expect(window.contentView === view)
        #expect(view.safeAreaInsets.top > 0)
        #expect(view.bounds.width == SettingsView.windowSize.width)
        #expect(view.bounds.height - view.safeAreaInsets.top == SettingsView.windowSize.height)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func chromeKeepsControlsClearAndClosingRetainsTheWindowAndSelectedPane(scheme: ColorScheme) async throws {
        var preferences = Preferences.default
        preferences.notchOverflow = .whenNeeded
        preferences.menuBarSpacing = MenuBarSpacing(enabled: true, spacing: 8, selectionPadding: 4)
        var creations = 0
        var reads = 0
        var writes = 0
        var createdHost: SettingsTestHostingController?
        let controller = SettingsWindowController(
            preferences: preferences, loginItem: SettingsTestLoginItem(),
            itemsProvider: { reads += 1; return [] },
            makeWindow: { content in
                creations += 1
                let hosting = settingsTestHost(
                    content.environment(\.colorScheme, scheme), configureWindow: SettingsWindowController.configureWindow
                )
                hosting.testWindow.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                createdHost = hosting
                return hosting.testWindow
            },
            onChange: { _ in writes += 1 }
        )
        controller.model.spacingNeedsLogout = true
        controller.model.exportLayout { _ in .failed("The disk is full. Free up some space and try exporting the layout again.") }
        #expect(creations == 0)
        let window = controller.prepareWindow(tab: .advanced)
        let hosting = try #require(createdHost)
        try #require(await waitForUpdate(hosting) {
            self.find("settings-detail-title", in: hosting.view)?.accessibilityLabel() == "Advanced"
        })
        #expect(controller.model.requestedTab == nil)
        try expectContentClearOfChrome(window, in: hosting.view)
        let footer = try element("settings-backup-status", in: hosting.view).accessibilityFrame()
        let detail = try element("settings-detail", in: hosting.view).accessibilityFrame()
        #expect(!footer.isEmpty)
        #expect(detail.contains(footer))
        #expect(window.convertToScreen(window.contentLayoutRect).contains(footer))
        let scroll = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSScrollView }.first {
            settingsTestAccessibility($0).contains { $0.accessibilityIdentifier() == "settings-backup-status" }
        })
        let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.visibleRect, to: nil))
        #expect(viewport.contains(footer))

        #expect(try element("settings-sidebar-style", in: hosting.view).accessibilityPerformPress())
        try #require(await waitForUpdate(hosting) {
            self.find("settings-detail-title", in: hosting.view)?.accessibilityLabel() == "Style"
        })
        window.setFrameOrigin(CGPoint(x: 150, y: 160))
        let retainedFrame = window.frame
        window.performClose(nil)

        let reopened = controller.prepareWindow()
        #expect(reopened === window)
        #expect(reopened.contentView === hosting.view)
        #expect(reopened.frame == retainedFrame)
        try #require(await waitForUpdate(hosting) {
            self.find("settings-detail-title", in: hosting.view)?.accessibilityLabel() == "Style"
        })
        #expect(controller.model.requestedTab == nil)
        try expectContentClearOfChrome(reopened, in: hosting.view)

        for tab: SettingsView.Tab in [.about, .presets] {
            #expect(controller.prepareWindow(tab: tab) === window)
            #expect(controller.prepareWindow() === window)
            try #require(await waitForUpdate(hosting) {
                controller.model.requestedTab == nil
                    && self.find("settings-detail-title", in: hosting.view)?.accessibilityLabel() == tab.title
            })
            try expectContentClearOfChrome(window, in: hosting.view)
        }
        #expect(creations == 1)
        #expect(reads == 0)
        #expect(writes == 0)
        #expect(controller.model.preferences == preferences)
    }

    @discardableResult
    private func expectChrome(_ window: NSWindow) throws -> [CGRect] {
        #expect(window.title == "Bar Keeper's Friend")
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.styleMask.contains([.titled, .closable, .miniaturizable, .fullSizeContentView]))
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.isMovable)
        #expect(!window.isMovableByWindowBackground)
        #expect(!window.isReleasedWhenClosed)
        #expect(window.contentLayoutRect.size == SettingsView.windowSize)
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)

        let usefulFrame = window.convertToScreen(window.contentLayoutRect)
        var buttonFrames: [CGRect] = []
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton] {
            let button = try #require(window.standardWindowButton(kind))
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            #expect(button.window === window)
            #expect(button.isEnabled)
            #expect(!button.isHiddenOrHasHiddenAncestor)
            #expect(!frame.isEmpty)
            #expect(window.frame.contains(frame))
            #expect(frame.minY >= usefulFrame.maxY)
            #expect(!usefulFrame.intersects(frame))
            buttonFrames.append(frame)
        }
        #expect(!buttonFrames[0].intersects(buttonFrames[1]))
        let frameView = try #require(window.contentView?.superview)
        let dragPoint = frameView.convert(CGPoint(
            x: window.contentLayoutRect.midX,
            y: (window.contentLayoutRect.maxY + window.frame.height) / 2
        ), from: nil)
        let dragView = try #require(frameView.hitTest(dragPoint))
        #expect(dragView.mouseDownCanMoveWindow)
        return buttonFrames
    }

    private func expectContentClearOfChrome(_ window: NSWindow, in view: NSView) throws {
        let buttonFrames = try expectChrome(window)
        let usefulFrame = window.convertToScreen(window.contentLayoutRect)
        for identifier in ["settings-identity-header", "settings-identity-icon", "settings-detail-title"] {
            let frame = try element(identifier, in: view).accessibilityFrame()
            #expect(!frame.isEmpty)
            #expect(usefulFrame.contains(frame), "\(identifier) must fit below the native titlebar safe area.")
            #expect(buttonFrames.allSatisfy { !$0.intersects(frame) })
        }
        let field = try #require(settingsTestSubviews(window.contentView?.superview ?? view)
            .compactMap { $0 as? NSSearchField }.first {
                $0.placeholderString == "Search Settings" || $0.placeholderAttributedString?.string == "Search Settings"
            })
        let searchFrame = window.convertToScreen(field.convert(field.bounds, to: nil))
        #expect(!searchFrame.isEmpty)
        #expect(field.isEnabled)
        #expect(!field.isHiddenOrHasHiddenAncestor)
        #expect(field.visibleRect.contains(field.bounds))
        #expect(usefulFrame.contains(searchFrame))
        #expect(buttonFrames.allSatisfy { !$0.intersects(searchFrame) })
        #expect(try element("settings-identity-header", in: view).accessibilityFrame().minY >= searchFrame.maxY)
    }

    private func find(_ identifier: String, in view: NSView) -> SettingsTestAXElement? {
        settingsTestAccessibility(view).first { $0.accessibilityIdentifier() == identifier }
    }

    private func element(_ identifier: String, in view: NSView) throws -> SettingsTestAXElement {
        try #require(find(identifier, in: view), "Missing Settings accessibility identifier \(identifier).")
    }

    private func waitForUpdate(_ hosting: SettingsTestHostingController, until condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            hosting.render()
            try? await Task.sleep(for: .milliseconds(10))
            hosting.render()
            if condition() { return true }
        } while !Task.isCancelled && clock.now < deadline
        return false
    }
}

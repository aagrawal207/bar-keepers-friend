import AppKit
import BarKeepersFriendCore
import Testing

/// A borderless window that records ordering requests instead of reaching the window server.
/// Ordering out is allowed: it is a no-op for a window that was never shown.
@MainActor
final class OverlayTestWindow: NSWindow {
    private(set) var frontRegardlessCalls = 0
    private(set) var frontCalls = 0
    private(set) var outCalls = 0

    override func orderFrontRegardless() { frontRegardlessCalls += 1 }
    override func orderFront(_ sender: Any?) { frontCalls += 1 }
    override func orderOut(_ sender: Any?) {
        outCalls += 1
        super.orderOut(sender)
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place == .out else {
            frontCalls += 1
            return
        }
        super.order(place, relativeTo: otherWin)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class OverlayTestWindowFactory {
    private(set) var created: [OverlayTestWindow] = []

    func make(frame: CGRect) -> NSWindow {
        let window = OverlayTestWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        created.append(window)
        return window
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MenuBarStyleOverlayControllerTests {
    private let builtIn = MenuBarStyleDisplay(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), menuBarHeight: 37,
        notch: NotchGeometry(
            displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            leftArea: CGRect(x: 0, y: 945, width: 700, height: 37),
            rightArea: CGRect(x: 812, y: 945, width: 700, height: 37)
        )
    )
    private let external = MenuBarStyleDisplay(
        id: 2, frame: CGRect(x: 1512, y: -120, width: 2560, height: 1440), menuBarHeight: 24
    )
    private let stacked = MenuBarStyleDisplay(
        id: 3, frame: CGRect(x: -400, y: 982, width: 1920, height: 1080), menuBarHeight: 24
    )

    private func enabled(_ shape: MenuBarStyle.Shape = .full, shadow: Bool = false, opacity: Double = 0.5) -> MenuBarStyle {
        MenuBarStyle(isEnabled: true, tint: RGBA(red: 1, green: 0, blue: 0), opacity: opacity, shadowEnabled: shadow, shape: shape)
    }

    private func makeController(
        displays: [MenuBarStyleDisplay] = [], level: NSWindow.Level = MenuBarStyleOverlayController.defaultWindowLevel,
        reduceTransparency: Bool = false
    ) -> (MenuBarStyleOverlayController, OverlayTestWindowFactory, DisplaySource) {
        let factory = OverlayTestWindowFactory()
        let source = DisplaySource(displays: displays, reduceTransparency: reduceTransparency)
        let controller = MenuBarStyleOverlayController(
            windowLevel: level,
            windowFactory: { factory.make(frame: $0) },
            displays: { source.displays },
            reduceTransparency: { source.reduceTransparency }
        )
        return (controller, factory, source)
    }

    @MainActor
    final class DisplaySource {
        var displays: [MenuBarStyleDisplay]
        var reduceTransparency: Bool
        init(displays: [MenuBarStyleDisplay], reduceTransparency: Bool) {
            self.displays = displays
            self.reduceTransparency = reduceTransparency
        }
    }

    private func testWindow(_ controller: MenuBarStyleOverlayController, _ id: CGDirectDisplayID) throws -> OverlayTestWindow {
        try #require(controller.window(for: id) as? OverlayTestWindow)
    }

    /// Every window must come from the fake factory and none may ever have been shown.
    private func assertHostless(_ controller: MenuBarStyleOverlayController, _ factory: OverlayTestWindowFactory) {
        #expect(!controller.usesSystemWindowFactory)
        for window in factory.created {
            #expect(!window.isVisible)
            #expect(window.frontCalls == 0)
        }
        for id in controller.displayIDs {
            #expect(controller.window(for: id) is OverlayTestWindow)
        }
    }

    // MARK: Level

    @Test func defaultLevelSitsJustBelowTheMenuBarWindow() {
        let level = MenuBarStyleOverlayController.defaultWindowLevel
        #expect(level.rawValue == Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        #expect(level.rawValue < NSWindow.Level.mainMenu.rawValue)
        #expect(level.rawValue < NSWindow.Level.statusBar.rawValue)
        #expect(level.rawValue > NSWindow.Level.normal.rawValue)
        #expect(level.rawValue > Int(CGWindowLevelForKey(.desktopIconWindow)))
        #expect(MenuBarStyleOverlayController.windowTitle.hasPrefix(HiddenItemsResolver.controlItemNamePrefix))
    }

    // MARK: Creation and configuration

    @Test func disabledStyleCreatesNoWindows() {
        let (controller, factory, _) = makeController(displays: [builtIn, external])
        controller.apply(style: .none)
        #expect(controller.windowCount == 0)
        #expect(factory.created.isEmpty)
        var transparent = enabled()
        transparent.opacity = 0
        controller.apply(style: transparent)
        #expect(controller.windowCount == 0)
        #expect(factory.created.isEmpty)
        assertHostless(controller, factory)
    }

    @Test func enabledStyleCreatesOneConfiguredWindowPerDisplay() throws {
        let level = NSWindow.Level(rawValue: 17)
        let (controller, factory, _) = makeController(displays: [builtIn, external, stacked], level: level)
        controller.apply(style: enabled(.pill, shadow: true))
        #expect(controller.windowCount == 3)
        #expect(factory.created.count == 3)
        #expect(controller.displayIDs == [1, 2, 3])

        let expectedFrames: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 982 - 37, width: 1512, height: 37),
            2: CGRect(x: 1512, y: -120 + 1440 - 24, width: 2560, height: 24),
            3: CGRect(x: -400, y: 982 + 1080 - 24, width: 1920, height: 24)
        ]
        for (id, frame) in expectedFrames {
            let window = try testWindow(controller, id)
            #expect(window.frame == frame)
            #expect(window.level == level)
            #expect(window.ignoresMouseEvents)
            #expect(!window.isOpaque)
            #expect(window.backgroundColor == .clear)
            #expect(window.hasShadow)
            #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
            #expect(window.collectionBehavior.contains(.stationary))
            #expect(window.collectionBehavior.contains(.ignoresCycle))
            #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
            #expect(window.title == MenuBarStyleOverlayController.windowTitle)
            #expect(!window.styleMask.contains(.titled))
            #expect(!window.isMovable)
            #expect(!window.hidesOnDeactivate)
            #expect(window.frontRegardlessCalls == 1)
            #expect(window.outCalls == 0)
            #expect(!window.isVisible)
            let view = try #require(window.contentView as? MenuBarStyleOverlayView)
            #expect(view === controller.overlayView(for: id))
            #expect(view.style == enabled(.pill, shadow: true).normalized())
            #expect(view.layout == controller.layout(for: id))
            #expect(view.frame.size == frame.size)
        }
        // The notched display splits its pill; the others paint one capsule.
        #expect(controller.layout(for: 1)?.segments.count == 2)
        #expect(controller.layout(for: 2)?.segments.count == 1)
        assertHostless(controller, factory)
    }

    @Test func displaysWithoutAVisibleMenuBarGetNoWindowUntilOneAppears() {
        let hidden = MenuBarStyleDisplay(id: 9, frame: external.frame, menuBarHeight: nil)
        let (controller, factory, source) = makeController(displays: [hidden])
        controller.apply(style: enabled())
        #expect(controller.windowCount == 0)
        source.displays = [MenuBarStyleDisplay(id: 9, frame: external.frame, menuBarHeight: 24)]
        controller.screensChanged()
        #expect(controller.windowCount == 1)
        #expect(factory.created.count == 1)
        source.displays = [hidden]
        controller.screensChanged()
        #expect(controller.windowCount == 0)
        #expect(factory.created.first?.outCalls == 1)
        assertHostless(controller, factory)
    }

    @Test func duplicateDisplayIDsUseTheFirstReport() {
        let twin = MenuBarStyleDisplay(id: 2, frame: stacked.frame, menuBarHeight: 24)
        let (controller, factory, _) = makeController(displays: [external, twin])
        controller.apply(style: enabled())
        #expect(controller.windowCount == 1)
        #expect(controller.window(for: 2)?.frame == CGRect(x: 1512, y: 1296, width: 2560, height: 24))
        assertHostless(controller, factory)
    }

    // MARK: Diffing

    @Test func screensChangedKeepsSurvivorsRemovesVanishedAndAddsNew() throws {
        let (controller, factory, source) = makeController(displays: [builtIn, external])
        controller.apply(style: enabled())
        let survivor = try testWindow(controller, 2)
        let vanished = try testWindow(controller, 1)

        source.displays = [external, stacked]
        controller.screensChanged()
        #expect(controller.displayIDs == [2, 3])
        #expect(try testWindow(controller, 2) === survivor)
        #expect(survivor.frontRegardlessCalls == 1)
        #expect(vanished.outCalls == 1)
        #expect(vanished.contentView == nil)
        #expect(factory.created.count == 3)
        assertHostless(controller, factory)
    }

    @Test func displayFrameChangeMovesTheExistingWindow() throws {
        let (controller, factory, source) = makeController(displays: [external])
        controller.apply(style: enabled())
        let window = try testWindow(controller, 2)
        source.displays = [MenuBarStyleDisplay(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), menuBarHeight: 24)]
        controller.screensChanged()
        #expect(try testWindow(controller, 2) === window)
        #expect(window.frame == CGRect(x: 1512, y: 1056, width: 1920, height: 24))
        #expect(window.contentView?.frame.size == CGSize(width: 1920, height: 24))
        #expect(window.frontRegardlessCalls == 1)
        #expect(factory.created.count == 1)
        assertHostless(controller, factory)
    }

    @Test func styleChangesUpdateWindowsInPlace() throws {
        let (controller, factory, _) = makeController(displays: [builtIn])
        controller.apply(style: enabled(.full))
        let window = try testWindow(controller, 1)
        let view = try #require(controller.overlayView(for: 1))
        #expect(!window.hasShadow)
        #expect(view.layout?.segments.count == 1)

        controller.apply(style: enabled(.rounded, shadow: true))
        #expect(try testWindow(controller, 1) === window)
        #expect(window.hasShadow)
        #expect(view.style.shape == .rounded)
        #expect(view.layout?.segments.count == 2)
        #expect(controller.currentStyle == enabled(.rounded, shadow: true).normalized())
        #expect(factory.created.count == 1)

        controller.apply(style: .none)
        #expect(controller.windowCount == 0)
        #expect(window.outCalls == 1)
        controller.apply(style: enabled())
        #expect(factory.created.count == 2)
        assertHostless(controller, factory)
    }

    @Test func removeAllOrdersOutEveryWindow() throws {
        let (controller, factory, _) = makeController(displays: [builtIn, external, stacked])
        controller.apply(style: enabled())
        controller.removeAll()
        #expect(controller.windowCount == 0)
        #expect(factory.created.count == 3)
        for window in factory.created {
            #expect(window.outCalls == 1)
            #expect(window.contentView == nil)
        }
        controller.removeAll()
        for window in factory.created { #expect(window.outCalls == 1) }
        // The style is remembered, so a later screen change restores the overlay.
        controller.screensChanged()
        #expect(controller.windowCount == 3)
        assertHostless(controller, factory)
    }

    @Test func setWindowLevelRetunesLiveAndFutureWindows() throws {
        let (controller, factory, source) = makeController(displays: [builtIn])
        controller.apply(style: enabled())
        controller.setWindowLevel(.statusBar)
        #expect(try testWindow(controller, 1).level == .statusBar)
        source.displays = [builtIn, external]
        controller.screensChanged()
        #expect(try testWindow(controller, 2).level == .statusBar)
        #expect(controller.windowLevel == .statusBar)
        assertHostless(controller, factory)
    }

    // MARK: Reduce Transparency

    @Test func reduceTransparencyPaintsOpaqueWithoutChangingTheSavedStyle() throws {
        let (controller, factory, source) = makeController(displays: [external], reduceTransparency: true)
        controller.apply(style: enabled(opacity: 0.3))
        let view = try #require(controller.overlayView(for: 2))
        #expect(view.style.opacity == 1)
        #expect(controller.currentStyle.opacity == 0.3)

        source.reduceTransparency = false
        controller.refresh()
        #expect(view.style.opacity == 0.3)
        #expect(factory.created.count == 1)
        assertHostless(controller, factory)
    }

    // MARK: Live screen description

    @Test func liveScreensDescribeThemselvesWithoutOrderingAnything() {
        for screen in NSScreen.screens {
            guard let display = MenuBarStyleDisplay(screen: screen) else {
                Issue.record("Screen without a display number: \(screen)")
                continue
            }
            #expect(display.frame == screen.frame)
            #expect(display.id != 0)
            if let height = display.menuBarHeight {
                #expect(height > 0 && height <= 60)
            }
            #expect(display.notch?.hasNotch == (screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil))
        }
        #expect(MenuBarStyleDisplay.current().count == NSScreen.screens.count)
    }

    // MARK: Rendering

    private func pixel(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    private func render(_ style: MenuBarStyle, width: CGFloat = 200, height: CGFloat = 24, notch: NotchGeometry? = nil) throws -> NSBitmapImageRep {
        let frame = CGRect(x: 0, y: 0, width: width, height: 400)
        let layout = MenuBarStyleGeometry.layout(displayFrame: frame, menuBarHeight: height, notch: notch, style: style)
        let view = MenuBarStyleOverlayView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.configure(style: style, layout: layout)
        return try #require(view.render(size: CGSize(width: width, height: height)))
    }

    @Test func solidTintFillsTheStripWithTheRequestedOpacity() throws {
        let opaque = try render(enabled(opacity: 1))
        #expect(opaque.pixelsWide == 400 && opaque.pixelsHigh == 48)
        let center = try pixel(opaque, 200, 24)
        #expect(center.redComponent > 0.95 && center.greenComponent < 0.05 && center.blueComponent < 0.05)
        #expect(center.alphaComponent > 0.95)
        let corner = try pixel(opaque, 0, 47)
        #expect(corner.alphaComponent > 0.95)

        let half = try render(enabled(opacity: 0.5))
        let halfCenter = try pixel(half, 200, 24)
        #expect(abs(halfCenter.alphaComponent - 0.5) < 0.03)
    }

    @Test func disabledOrLayoutlessViewsRenderTransparent() throws {
        let disabled = try render(.none)
        #expect(settingsTestPixelCount(disabled) { $0.alphaComponent > 0.01 } == 0)
        let view = MenuBarStyleOverlayView(frame: CGRect(x: 0, y: 0, width: 50, height: 24))
        view.configure(style: enabled(opacity: 1), layout: nil)
        let bitmap = try #require(view.render(size: CGSize(width: 50, height: 24)))
        #expect(settingsTestPixelCount(bitmap) { $0.alphaComponent > 0.01 } == 0)
    }

    @Test func gradientRunsFromTintToEndAcrossTheWholeStrip() throws {
        var style = enabled(opacity: 1)
        style.gradientEnd = RGBA(red: 0, green: 0, blue: 1)
        let bitmap = try render(style)
        let left = try pixel(bitmap, 2, 24)
        let right = try pixel(bitmap, 397, 24)
        #expect(left.redComponent > 0.9 && left.blueComponent < 0.1)
        #expect(right.blueComponent > 0.9 && right.redComponent < 0.1)
        let middle = try pixel(bitmap, 200, 24)
        #expect(middle.redComponent > 0.2 && middle.blueComponent > 0.2)
    }

    @Test func fullBarBorderIsABottomEdgeLineOnly() throws {
        var style = enabled(opacity: 1)
        style.borderWidth = 2
        style.borderColor = RGBA(red: 1, green: 1, blue: 1)
        let bitmap = try render(style)
        // Bitmap rows count from the top; the bottom 2pt (4px) row is the border.
        let bottom = try pixel(bitmap, 200, 46)
        #expect(bottom.greenComponent > 0.9 && bottom.blueComponent > 0.9)
        let top = try pixel(bitmap, 200, 1)
        #expect(top.redComponent > 0.9 && top.greenComponent < 0.1)
        let leftEdge = try pixel(bitmap, 1, 24)
        #expect(leftEdge.redComponent > 0.9 && leftEdge.greenComponent < 0.1)
    }

    @Test func pillLeavesTheCornersAndInsetsTransparentAndStrokesItsOutline() throws {
        var style = enabled(.pill, opacity: 1)
        style.cornerRadius = 20
        style.borderWidth = 2
        style.borderColor = RGBA(red: 0, green: 1, blue: 0)
        let bitmap = try render(style)
        #expect(try pixel(bitmap, 0, 0).alphaComponent < 0.01)
        #expect(try pixel(bitmap, 399, 47).alphaComponent < 0.01)
        #expect(try pixel(bitmap, 200, 1).alphaComponent < 0.01) // 2pt top inset
        let center = try pixel(bitmap, 200, 24)
        #expect(center.redComponent > 0.9 && center.greenComponent < 0.1)
        // The stroke sits just inside the capsule's top edge: y = 2pt inset + 1pt half-width.
        let outline = try pixel(bitmap, 200, 6)
        #expect(outline.greenComponent > 0.9 && outline.redComponent < 0.1)
    }

    @Test func roundedBarStaysFlushAtTheTopAndClearsTheBottomCorners() throws {
        var style = enabled(.rounded, opacity: 1)
        style.cornerRadius = 12
        let bitmap = try render(style)
        #expect(try pixel(bitmap, 0, 0).alphaComponent > 0.95)   // top-left flush
        #expect(try pixel(bitmap, 399, 0).alphaComponent > 0.95) // top-right flush
        #expect(try pixel(bitmap, 0, 47).alphaComponent < 0.01)  // bottom-left rounded away
        #expect(try pixel(bitmap, 399, 47).alphaComponent < 0.01)
        #expect(try pixel(bitmap, 200, 47).alphaComponent > 0.95) // bottom middle intact
    }

    @Test func notchSplitsRoundedAndPillButNotFull() throws {
        let notch = NotchGeometry(
            displayFrame: CGRect(x: 0, y: 0, width: 200, height: 400),
            leftArea: CGRect(x: 0, y: 376, width: 80, height: 24),
            rightArea: CGRect(x: 120, y: 376, width: 80, height: 24)
        )
        for shape in MenuBarStyle.Shape.allCases {
            var style = enabled(shape, opacity: 1)
            style.cornerRadius = 8
            let bitmap = try render(style, notch: notch)
            let gap = try pixel(bitmap, 200, 24)
            let left = try pixel(bitmap, 80, 24)
            #expect(left.alphaComponent > 0.95, "\(shape) paints the left segment")
            #expect((gap.alphaComponent > 0.95) == (shape == .full), "\(shape) gap under the notch")
        }
    }

    @Test func reduceTransparencyRenderingIsFullyOpaque() throws {
        let (controller, factory, _) = makeController(displays: [external], reduceTransparency: true)
        controller.apply(style: enabled(opacity: 0.2))
        let view = try #require(controller.overlayView(for: 2))
        let bitmap = try #require(view.render(size: CGSize(width: 100, height: 24)))
        #expect(try pixel(bitmap, 100, 24).alphaComponent > 0.95)
        assertHostless(controller, factory)
    }
}

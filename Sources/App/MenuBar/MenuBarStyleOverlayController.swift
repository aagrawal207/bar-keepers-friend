import AppKit
import BarKeepersFriendCore

/// One display's inputs for the style overlay, in AppKit screen coordinates.
struct MenuBarStyleDisplay: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    /// nil when the display shows no menu bar right now (auto-hidden or a full-screen Space).
    let menuBarHeight: CGFloat?
    let notch: NotchGeometry?

    init(id: CGDirectDisplayID, frame: CGRect, menuBarHeight: CGFloat?, notch: NotchGeometry? = nil) {
        self.id = id
        self.frame = frame
        self.menuBarHeight = menuBarHeight
        self.notch = notch
    }

    /// Reads the live screen. The bar height comes from the visible-frame gap rather than
    /// `NSStatusBar.thickness`, which stays 24 on notched displays whose bar is taller.
    @MainActor
    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let gap = screen.frame.maxY - screen.visibleFrame.maxY
        self.init(
            id: CGDirectDisplayID(number.uint32Value),
            frame: screen.frame,
            menuBarHeight: gap > 0 ? gap : nil,
            notch: NotchGeometry(
                displayFrame: screen.frame,
                leftArea: screen.auxiliaryTopLeftArea,
                rightArea: screen.auxiliaryTopRightArea
            )
        )
    }

    @MainActor
    static func current() -> [MenuBarStyleDisplay] {
        NSScreen.screens.compactMap(MenuBarStyleDisplay.init(screen:))
    }
}

/// One borderless, click-through window per display, painted under the system menu bar. Pure
/// `MenuBarStyleGeometry` decides every frame; nothing here enumerates, captures, or moves items.
@MainActor
final class MenuBarStyleOverlayController {
    typealias WindowFactory = @MainActor (CGRect) -> NSWindow
    typealias DisplaysProvider = @MainActor () -> [MenuBarStyleDisplay]

    /// 23: under the bar's own window (24, transparent on Tahoe by default) and its items (25), so
    /// the paint shows through behind every title and icon; 25+ would wash over them. QA can retune.
    static let defaultWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

    /// QA fallback if 23 turns out hidden: Ice's approach, a translucent wash above the items.
    /// Only usable with a capped opacity, since it covers every icon and menu title.
    static let aboveItemsWindowLevel = NSWindow.Level.statusBar

    /// Recognized by `HiddenItemsResolver.isOwnControlItem`, so a QA level of 25 never lists the
    /// overlay as a hideable status item.
    static let windowTitle = "\(HiddenItemsResolver.controlItemNamePrefix)MenuBarStyle"

    private struct Entry {
        let window: NSWindow
        let view: MenuBarStyleOverlayView
        var layout: MenuBarStyleGeometry.Layout
    }

    private let windowFactory: WindowFactory
    private let displaysProvider: DisplaysProvider
    private let reduceTransparency: @MainActor () -> Bool
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private var accessibilityObserver: NSObjectProtocol?

    /// True only when no factory was injected, so tests can prove they never reach `NSWindow` ordering.
    let usesSystemWindowFactory: Bool
    private(set) var windowLevel: NSWindow.Level
    /// The last style handed to `apply`, before any Reduce Transparency adjustment.
    private(set) var currentStyle: MenuBarStyle = .none

    init(
        windowLevel: NSWindow.Level = MenuBarStyleOverlayController.defaultWindowLevel,
        windowFactory: WindowFactory? = nil,
        displays: DisplaysProvider? = nil,
        reduceTransparency: (@MainActor () -> Bool)? = nil
    ) {
        self.windowLevel = windowLevel
        self.usesSystemWindowFactory = windowFactory == nil
        self.windowFactory = windowFactory ?? MenuBarStyleOverlayController.makeSystemWindow
        self.displaysProvider = displays ?? { MenuBarStyleDisplay.current() }
        self.reduceTransparency = reduceTransparency ?? { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    isolated deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        removeAll()
    }

    var windowCount: Int { entries.count }
    var displayIDs: Set<CGDirectDisplayID> { Set(entries.keys) }

    func window(for displayID: CGDirectDisplayID) -> NSWindow? { entries[displayID]?.window }
    func overlayView(for displayID: CGDirectDisplayID) -> MenuBarStyleOverlayView? { entries[displayID]?.view }
    func layout(for displayID: CGDirectDisplayID) -> MenuBarStyleGeometry.Layout? { entries[displayID]?.layout }

    /// Applies `style` to the displays the provider reports right now.
    func apply(style: MenuBarStyle) {
        apply(style: style, displays: displaysProvider())
    }

    /// Diffs windows against `displays`: surviving displays keep their window and are updated in
    /// place, vanished displays lose theirs, new ones gain one. A disabled style removes them all.
    func apply(style: MenuBarStyle, displays: [MenuBarStyleDisplay]) {
        currentStyle = style.normalized()
        let effective = currentStyle.honoringReduceTransparency(reduceTransparency())
        var live: Set<CGDirectDisplayID> = []
        for display in displays where !live.contains(display.id) {
            guard let height = display.menuBarHeight,
                  let layout = MenuBarStyleGeometry.layout(
                      displayFrame: display.frame, menuBarHeight: height, notch: display.notch, style: effective
                  ) else { continue }
            live.insert(display.id)
            update(displayID: display.id, layout: layout, style: effective)
        }
        for id in entries.keys where !live.contains(id) {
            remove(displayID: id)
        }
    }

    /// Re-reads the displays; call from the debounced screen-parameters handler.
    func screensChanged() {
        apply(style: currentStyle)
    }

    /// Re-applies the current style, picking up a changed Reduce Transparency setting.
    func refresh() {
        apply(style: currentStyle)
    }

    /// For hardware QA: moves every live window to `level` and keeps it for new ones.
    func setWindowLevel(_ level: NSWindow.Level) {
        windowLevel = level
        for entry in entries.values { entry.window.level = level }
    }

    func removeAll() {
        for id in Array(entries.keys) { remove(displayID: id) }
    }

    // MARK: - Internals

    private func update(displayID: CGDirectDisplayID, layout: MenuBarStyleGeometry.Layout, style: MenuBarStyle) {
        if var entry = entries[displayID] {
            if entry.window.frame != layout.windowFrame {
                entry.window.setFrame(layout.windowFrame, display: false)
            }
            entry.window.level = windowLevel
            entry.window.hasShadow = style.shadowEnabled
            entry.view.configure(style: style, layout: layout)
            // The window-server shadow follows the drawn alpha, so a new shape needs a recompute.
            entry.window.invalidateShadow()
            entry.layout = layout
            entries[displayID] = entry
            return
        }
        let window = windowFactory(layout.windowFrame)
        window.title = Self.windowTitle
        window.level = windowLevel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = style.shadowEnabled
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isExcludedFromWindowsMenu = true
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        let view = MenuBarStyleOverlayView(frame: CGRect(origin: .zero, size: layout.contentSize))
        view.configure(style: style, layout: layout)
        window.contentView = view
        if window.frame != layout.windowFrame {
            window.setFrame(layout.windowFrame, display: false)
        }
        entries[displayID] = Entry(window: window, view: view, layout: layout)
        // Regardless: the agent has no key window, so a plain orderFront could be ignored.
        window.orderFrontRegardless()
    }

    private func remove(displayID: CGDirectDisplayID) {
        guard let entry = entries.removeValue(forKey: displayID) else { return }
        entry.window.orderOut(nil)
        entry.window.contentView = nil
    }

    private static func makeSystemWindow(frame: CGRect) -> NSWindow {
        MenuBarStyleOverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
    }
}

/// The production window: borderless, never key or main, invisible to accessibility, and free to
/// sit inside the menu bar strip that AppKit would otherwise constrain a frame away from.
final class MenuBarStyleOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func isAccessibilityElement() -> Bool { false }
}

/// Draws a `MenuBarStyle` for a computed layout with plain `draw(_:)` calls, so the same code
/// paints the live overlay, the Settings preview, and the test bitmaps.
final class MenuBarStyleOverlayView: NSView {
    private(set) var style: MenuBarStyle = .none
    private(set) var layout: MenuBarStyleGeometry.Layout?

    override var isOpaque: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(style: MenuBarStyle, layout: MenuBarStyleGeometry.Layout?) {
        guard style != self.style || layout != self.layout else { return }
        self.style = style
        self.layout = layout
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        Self.draw(style: style, layout: layout, in: bounds)
    }

    /// Renders the current style into a fresh bitmap of `size` points at `scale`, off screen.
    func render(size: CGSize, scale: CGFloat = 2) -> NSBitmapImageRep? {
        Self.render(style: style, layout: layout, size: size, scale: scale)
    }

    static func render(
        style: MenuBarStyle, layout: MenuBarStyleGeometry.Layout?, size: CGSize, scale: CGFloat = 2
    ) -> NSBitmapImageRep? {
        let pixelsWide = Int((size.width * scale).rounded(.up))
        let pixelsHigh = Int((size.height * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        // The rep still reports pixel size here, so the only scale in play is the explicit one.
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.cgContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        if let layout {
            draw(style: style, layout: layout, in: CGRect(origin: .zero, size: size))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        return bitmap
    }

    /// `bounds` is the strip the layout was computed for; segments are already local to it.
    static func draw(style: MenuBarStyle, layout: MenuBarStyleGeometry.Layout, in bounds: CGRect) {
        let style = style.normalized()
        guard style.isVisible else { return }
        let fill = nsColor(style.tint, opacity: style.opacity)
        let gradient: NSGradient? = style.gradientEnd.flatMap {
            NSGradient(starting: fill, ending: nsColor($0, opacity: style.opacity))
        }
        let border = nsColor(style.borderColor, opacity: style.opacity)
        for segment in layout.segments {
            let path = shapePath(for: segment)
            if let gradient {
                // Clip per segment but span the whole strip so a split bar keeps one continuous ramp.
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                gradient.draw(in: bounds, angle: 0)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                fill.setFill()
                path.fill()
            }
            if style.hasBorder {
                let stroke = borderPath(for: segment, shape: layout.shape, width: CGFloat(style.borderWidth))
                stroke.lineWidth = CGFloat(style.borderWidth)
                border.setStroke()
                stroke.stroke()
            }
        }
    }

    static func nsColor(_ color: RGBA, opacity: Double) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha * opacity)
    }

    /// The filled outline of one segment.
    static func shapePath(for segment: MenuBarStyleGeometry.Segment) -> NSBezierPath {
        let rect = segment.rect
        let radius = segment.cornerRadius
        guard radius > 0 else { return NSBezierPath(rect: rect) }
        if segment.roundsTopCorners {
            return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        // Square top corners, round bottom corners: start at the top-left and walk clockwise.
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.appendArc(
            withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius, startAngle: 0, endAngle: -90, clockwise: true
        )
        path.line(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.appendArc(
            withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius, startAngle: -90, endAngle: -180, clockwise: true
        )
        path.close()
        return path
    }

    /// The stroked outline, inset by half the width so it stays inside the shape. Edges that lie
    /// on the display's top edge are skipped: a hairline there would sit on the physical bezel.
    static func borderPath(for segment: MenuBarStyleGeometry.Segment, shape: MenuBarStyle.Shape, width: CGFloat) -> NSBezierPath {
        let half = width / 2
        let rect = segment.rect
        let path = NSBezierPath()
        switch shape {
        case .full:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + half))
            path.line(to: CGPoint(x: rect.maxX, y: rect.minY + half))
        case .pill:
            let inset = rect.insetBy(dx: half, dy: half)
            let radius = max(segment.cornerRadius - half, 0)
            path.append(NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius))
        case .rounded:
            let inset = CGRect(x: rect.minX + half, y: rect.minY + half, width: rect.width - width, height: rect.height - half)
            let radius = max(min(segment.cornerRadius - half, inset.height, inset.width / 2), 0)
            path.move(to: CGPoint(x: inset.minX, y: inset.maxY))
            path.line(to: CGPoint(x: inset.minX, y: inset.minY + radius))
            if radius > 0 {
                path.appendArc(
                    withCenter: CGPoint(x: inset.minX + radius, y: inset.minY + radius),
                    radius: radius, startAngle: 180, endAngle: 270, clockwise: false
                )
            }
            path.line(to: CGPoint(x: inset.maxX - radius, y: inset.minY))
            if radius > 0 {
                path.appendArc(
                    withCenter: CGPoint(x: inset.maxX - radius, y: inset.minY + radius),
                    radius: radius, startAngle: 270, endAngle: 360, clockwise: false
                )
            }
            path.line(to: CGPoint(x: inset.maxX, y: inset.maxY))
        }
        return path
    }
}

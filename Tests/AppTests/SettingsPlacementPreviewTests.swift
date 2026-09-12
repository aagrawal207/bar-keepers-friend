import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite
@MainActor
struct SettingsPlacementPreviewTests {
    @Test(arguments: FloatingBarStyle.allCases, [ColorScheme.light, .dark])
    func cellsDrawCachedImagesAndLabelsWithinSharedMetrics(style: FloatingBarStyle, scheme: ColorScheme) throws {
        for metrics in [FloatingBarLayout.Metrics.default, FloatingBarLayout.Metrics(
            itemExtent: 36, iconSize: 20, rowLabelWidth: 144,
            padding: 12, gapBelowMenuBar: 6, cornerInset: 10
        )] {
            var item = settingsTestItem(1, alias: String(repeating: "A long display alias ", count: 20))
            item.isDisabled = true
            let hosting = settingsTestHost(SettingsPlacementPreview.Item(
                item: item, style: style, section: "Hidden", metrics: metrics
            ).environment(\.colorScheme, scheme))
            hosting.view.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            hosting.testWindow.appearance = hosting.view.appearance
            hosting.render()
            let expectedWidth = metrics.itemExtent + (style == .vertical ? metrics.rowLabelWidth : 0)
            #expect(hosting.view.fittingSize == CGSize(width: expectedWidth, height: metrics.itemExtent))

            let bitmap = try settingsTestBitmap(hosting.view)
            #expect(settingsTestPixelCount(bitmap) { color in
                color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1
                    && color.alphaComponent > 0.9
            } > 100)
            if style == .vertical {
                let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
                let labelPixels = (Int(metrics.itemExtent * scale)..<bitmap.pixelsWide).reduce(0) { count, x in
                    count + (0..<bitmap.pixelsHigh).filter { y in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              color.alphaComponent > 0.8 else { return false }
                        return scheme == .dark ? color.redComponent > 0.8 : color.redComponent < 0.2
                    }.count
                }
                #expect(labelPixels > 20)
            }

            let element = try #require(settingsTestAccessibility(hosting.view).first {
                $0.accessibilityIdentifier() == "settings-preview-item-1"
            })
            #expect(element.accessibilityLabel() == item.displayName)
            #expect(element.accessibilityValue() as? String == "Hidden")
            #expect(element.accessibilityRole() != .button)
            #expect(!settingsTestSubviews(hosting.view).contains { $0 is NSButton })
        }
    }

    @Test(arguments: FloatingBarStyle.allCases, [ColorScheme.light, .dark])
    func emptySingleAndLargePreviewsStayBounded(style: FloatingBarStyle, scheme: ColorScheme) throws {
        var heights: [CGFloat] = []
        for count in [0, 1, 80, 160] {
            let shown = (0..<count).map { settingsTestItem(CGWindowID($0 + 1)) }
            let hidden = (0..<count).map {
                settingsTestItem(CGWindowID($0 + 1001), alias: String(repeating: "Long alias ", count: 40))
            }
            let unknown = (0..<count).map { settingsTestItem(CGWindowID($0 + 2001)) }
            let hosting = settingsTestHost(SettingsPlacementPreview(
                shown: shown, hidden: hidden, unknown: unknown, style: style,
                useFloatingBar: false, hasPendingChanges: true
            ).environment(\.colorScheme, scheme).frame(width: 608))
            let size = hosting.view.fittingSize
            heights.append(size.height)
            #expect(size.height > 80)
            #expect(size.height <= 230)

            let elements = settingsTestAccessibility(hosting.view)
            let text = elements.map { settingsTestAccessibilityText($0) }.joined(separator: " ")
            #expect(text.contains("Menu Bar"))
            #expect(text.contains(style == .horizontal ? "Hidden Bar" : "Hidden List"))
            #expect(text.contains("Hidden bar is disabled"))
            #expect(text.contains("cached glyphs or app icons"))
            if count == 0 {
                #expect(!elements.contains { $0.accessibilityIdentifier()?.hasPrefix("settings-preview-item-") == true })
                #expect(text.contains("No items in this preview"))
            } else {
                #expect(elements.contains { $0.accessibilityIdentifier() == "settings-preview-item-1" })
                #expect(elements.contains { $0.accessibilityIdentifier() == "settings-preview-item-1001" })
                #expect(elements.contains { $0.accessibilityIdentifier() == "settings-preview-item-2001" })
                let bitmap = try settingsTestBitmap(hosting.view)
                #expect(settingsTestPixelCount(bitmap) { $0.redComponent > 0.9 && $0.greenComponent < 0.1 } > 100)
            }
        }
        #expect(heights[2] == heights[3])
    }

    @Test(arguments: FloatingBarStyle.allCases)
    func overflowScrollsToTheLastCachedItem(style: FloatingBarStyle) throws {
        let items = (0..<80).map { settingsTestItem(CGWindowID($0 + 1), green: $0 == 79) }
        let metrics = FloatingBarLayout.Metrics.default
        let hosting = settingsTestHost(SettingsPlacementPreview.Items(
            items: items, style: style, section: "Hidden", metrics: metrics
        ).frame(width: 260))
        let scroll = try #require(settingsTestSubviews(hosting.view).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        let before = try settingsTestBitmap(hosting.view)
        #expect(settingsTestPixelCount(before) { $0.greenComponent > 0.9 && $0.redComponent < 0.1 } == 0)

        var origin = scroll.contentView.bounds.origin
        if style == .horizontal {
            #expect(document.bounds.width >= CGFloat(items.count) * metrics.itemExtent)
            #expect(document.bounds.width > scroll.contentView.bounds.width)
            origin.x = document.bounds.maxX - scroll.contentView.bounds.width
        } else {
            #expect(document.bounds.height >= CGFloat(items.count) * metrics.itemExtent)
            #expect(document.bounds.height > scroll.contentView.bounds.height)
            origin.y = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        hosting.view.layoutSubtreeIfNeeded()

        let after = try settingsTestBitmap(hosting.view)
        #expect(settingsTestPixelCount(after) { $0.greenComponent > 0.9 && $0.redComponent < 0.1 } > 100)
        #expect(hosting.view.fittingSize.height <= metrics.itemExtent * 2 + metrics.padding * 2)
        #expect(!settingsTestSubviews(hosting.view).contains { $0 is NSButton })
    }

    @Test(arguments: [false, true], [false, true])
    func phaseAndUnknownPlacementAreExplicit(hasDraft: Bool, applying: Bool) throws {
        let hosting = settingsTestHost(SettingsPlacementPreview(
            shown: [settingsTestItem(1, alias: "Shown alias")],
            hidden: [settingsTestItem(2, alias: "Hidden alias")],
            unknown: [settingsTestItem(3, alias: "Unobserved alias")],
            style: .vertical, hasPendingChanges: hasDraft, placementInProgress: applying
        ).frame(width: 608))
        let elements = settingsTestAccessibility(hosting.view)
        let phase = try #require(elements.first { $0.accessibilityIdentifier() == "settings-preview-phase" })
        #expect(settingsTestAccessibilityText(phase).contains(applying ? "Applying" : hasDraft ? "After Apply" : "Last Observed"))
        let caption = try #require(elements.first { $0.accessibilityIdentifier() == "settings-preview-caption" })
        #expect(settingsTestAccessibilityText(caption).contains("After Apply includes saved placement requests.") == hasDraft)

        for (identifier, expectedItem, excludedItem) in [
            ("settings-preview-menu-bar", "settings-preview-item-1", "settings-preview-item-3"),
            ("settings-preview-hidden", "settings-preview-item-2", "settings-preview-item-3"),
            ("settings-preview-unknown", "settings-preview-item-3", "settings-preview-item-1")
        ] {
            let section = try #require(elements.first { $0.accessibilityIdentifier() == identifier })
            let children = settingsTestAccessibility(section)
            #expect(children.contains { $0.accessibilityIdentifier() == expectedItem })
            #expect(!children.contains { $0.accessibilityIdentifier() == excludedItem })
        }
        let unknown = try #require(elements.first { $0.accessibilityIdentifier() == "settings-preview-item-3" })
        #expect(unknown.accessibilityValue() as? String == "Placement unknown")
        #expect(unknown.accessibilityRole() != .button)
    }

    @Test func overlappingHostsRestoreTheProcessAccessibilitySetting() {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let original = app.accessibilityAttributeValue(attribute) as? Bool
        var first: SettingsTestHostingController? = settingsTestHost(Text("First"))
        var second: SettingsTestHostingController? = settingsTestHost(Text("Second"))
        weak var firstReference = first
        weak var secondReference = second
        #expect(app.accessibilityAttributeValue(attribute) as? Bool == true)

        first = nil
        #expect(firstReference == nil)
        #expect(app.accessibilityAttributeValue(attribute) as? Bool == true)
        second = nil
        #expect(secondReference == nil)
        #expect(app.accessibilityAttributeValue(attribute) as? Bool == original)
    }
}

@MainActor
func settingsTestItem(
    _ id: CGWindowID, alias: String? = nil, observedHidden: Bool? = nil, green: Bool = false
) -> FloatingBarItem {
    let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
        NSColor(srgbRed: green ? 0 : 1, green: green ? 1 : 0, blue: 0, alpha: 1).setFill()
        rect.fill()
        return true
    }
    return FloatingBarItem(
        snapshot: MenuBarItemSnapshot(windowID: id, ownerPID: 1, ownerBundleID: "Item \(id)", frame: .zero),
        image: image, alias: alias, observedHidden: observedHidden
    )
}

@MainActor
func settingsTestHost<Content: View>(_ content: Content) -> SettingsTestHostingController {
    SettingsTestHostingController(rootView: AnyView(content.environment(\.accessibilityEnabled, true)))
}

@MainActor
final class SettingsTestHostingController: NSHostingController<AnyView> {
    private(set) var testWindow: NSWindow!
    private static let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private static var activeHosts = 0
    private static var previousEnhancedUI: Any?

    override init(rootView: AnyView) {
        // Native SwiftUI scroll/list metadata requires this process-local accessibility opt-in.
        // Preserve it across overlapping hosts and restore the caller's value after the last host.
        if Self.activeHosts == 0 {
            Self.previousEnhancedUI = NSApplication.shared.accessibilityAttributeValue(Self.enhancedUI)
            NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhancedUI)
        }
        Self.activeHosts += 1
        super.init(rootView: rootView)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        // Native scroll documents and list rows require a window-backed render, not just fittingSize.
        testWindow = SettingsTestWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable],
                                       backing: .buffered, defer: true)
        testWindow.isReleasedWhenClosed = false
        testWindow.contentView = view
        render()
        #expect(!testWindow.isVisible)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    isolated deinit {
        testWindow.close()
        Self.activeHosts -= 1
        if Self.activeHosts == 0 {
            NSApplication.shared.accessibilitySetValue(Self.previousEnhancedUI, forAttribute: Self.enhancedUI)
            Self.previousEnhancedUI = nil
        }
    }

    func render() {
        guard let hostingView = view as? NSHostingView<AnyView> else {
            Issue.record("The Settings harness requires an NSHostingView backing view.")
            return
        }
        for _ in 0..<2 {
            for element in settingsTestAccessibility(hostingView) {
                _ = element.accessibilityIdentifier()
                _ = element.accessibilityLabel()
            }
            hostingView._renderForTest(interval: 1.0 / 60)
            hostingView.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
private final class SettingsTestWindow: NSWindow {
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place == .out else {
            Issue.record("Settings tests must never order a window on screen.")
            return
        }
        super.order(place, relativeTo: otherWin)
    }

    override func orderFrontRegardless() {
        Issue.record("Settings tests must never order a window on screen.")
    }
}

// SwiftUI's virtual nodes expose the standard selectors without NSAccessibilityProtocol conformance.
// KVC preserves those nodes in the in-process accessibility tree.
@MainActor
struct SettingsTestAXElement {
    let object: NSObject

    func accessibilityIdentifier() -> String? { property("accessibilityIdentifier") as? String }
    func accessibilityLabel() -> String? { property("accessibilityLabel") as? String }
    func accessibilityValue() -> Any? { property("accessibilityValue") }
    func accessibilityHelp() -> String? { property("accessibilityHelp") as? String }
    func isAccessibilityEnabled() -> Bool { property("isAccessibilityEnabled") as? Bool == true }
    func accessibilityRole() -> NSAccessibility.Role? {
        (property("accessibilityRole") as? String).map { NSAccessibility.Role(rawValue: $0) }
    }
    func accessibilityFrame() -> CGRect {
        (property("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
    }
    func accessibilityPerformPress() -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard isAccessibilityEnabled(), object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let press = unsafeBitCast(object.method(for: selector), to: Press.self)
        return press(object, selector)
    }

    func property(_ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }
}

@MainActor
func settingsTestAccessibility(_ root: NSObject) -> [SettingsTestAXElement] {
    settingsTestAccessibility(SettingsTestAXElement(object: root))
}

@MainActor
func settingsTestAccessibility(_ root: SettingsTestAXElement) -> [SettingsTestAXElement] {
    var elements: [SettingsTestAXElement] = []
    var visited: Set<ObjectIdentifier> = []
    @MainActor
    func visit(_ element: SettingsTestAXElement) {
        guard visited.insert(ObjectIdentifier(element.object)).inserted else { return }
        elements.append(element)
        for key in ["accessibilityChildren", "accessibilityRows", "accessibilityContents"] {
            for child in element.property(key) as? [NSObject] ?? [] {
                visit(SettingsTestAXElement(object: child))
            }
        }
        // Closed windows omit table rows from AXChildren; their hosted views still expose real AX metadata.
        if let view = element.object as? NSView {
            for child in view.subviews { visit(SettingsTestAXElement(object: child)) }
        }
    }
    visit(root)
    return elements
}

@MainActor
func settingsTestAccessibilityText(_ element: SettingsTestAXElement) -> String {
    [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }.joined(separator: " ")
}

@MainActor
func settingsTestSubviews(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { settingsTestSubviews($0) }
}

@MainActor
func settingsTestBitmap(_ view: NSView) throws -> NSBitmapImageRep {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(ceil(view.bounds.width * 2)), pixelsHigh: Int(ceil(view.bounds.height * 2)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    bitmap.size = view.bounds.size
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }
    #expect(view.window?.isVisible != true)
    return bitmap
}

@MainActor
func settingsTestPixelCount(_ bitmap: NSBitmapImageRep, matching predicate: (NSColor) -> Bool) -> Int {
    var count = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) { count += 1 }
        }
    }
    return count
}

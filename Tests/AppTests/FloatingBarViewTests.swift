import AppKit
import BarKeepersFriendCore
import SwiftUI
import Testing

@Suite
@MainActor
struct FloatingBarViewTests {
    @Test(arguments: FloatingBarStyle.allCases, [false, true])
    func emptyAndPreparingContentFitsBelowTheAnchor(style: FloatingBarStyle, isPreparing: Bool) {
        let display = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        let hosting = NSHostingController(rootView: FloatingBarView(
            items: [], style: style, isPreparing: isPreparing, onActivate: { _ in }
        ))
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        let frame = FloatingBarLayout.panelFrame(
            contentSize: size, anchorRightX: -100, menuBarHeight: 24, displayFrame: display
        )

        #expect(size.width > 30)
        #expect(size.height > 0)
        #expect(frame.size == size)
        #expect(frame.maxX == -100)
        #expect(frame.minY == 28)
        #expect(display.contains(frame))
        #expect(hosting.view.window == nil)
    }

    @Test(arguments: FloatingBarStyle.allCases, [
        FloatingBarLayout.Metrics.default,
        FloatingBarLayout.Metrics(
            itemExtent: 36, iconSize: 20, rowLabelWidth: 144,
            padding: 12, gapBelowMenuBar: 6, cornerInset: 10
        )
    ])
    func fittingSizeMatchesCoreLayout(style: FloatingBarStyle, metrics: FloatingBarLayout.Metrics) {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let menuBarHeight: CGFloat = 24
        let perLine = FloatingBarLayout.itemsPerLine(
            style: style, displayFrame: display, menuBarHeight: menuBarHeight, metrics: metrics
        )
        let image = NSImage(size: CGSize(width: metrics.iconSize, height: metrics.iconSize))

        for count in [1, perLine, perLine + 1, 80, perLine * 2 + 3] {
            let items = (0..<count).map { index in
                FloatingBarItem(
                    snapshot: MenuBarItemSnapshot(
                        windowID: CGWindowID(index + 1), ownerPID: 1,
                        ownerBundleID: "Item \(index)", frame: .zero
                    ),
                    image: image,
                    alias: "A long display name that must not widen the floating bar's rows"
                )
            }
            let layout = FloatingBarLayout.layout(
                style: style, itemCount: count, anchorRightX: 1400,
                menuBarHeight: menuBarHeight, displayFrame: display, metrics: metrics
            )
            let hosting = NSHostingController(rootView: FloatingBarView(
                items: items, style: style, itemsPerLine: perLine,
                metrics: metrics, onActivate: { _ in }
            ))
            hosting.view.layoutSubtreeIfNeeded()

            #expect(hosting.view.window == nil)
            #expect(
                hosting.view.fittingSize == layout.panelFrame.size,
                "itemCount: \(count), itemsPerLine: \(perLine)"
            )
        }
    }

    @Test(arguments: FloatingBarStyle.allCases, [ColorScheme.light, .dark])
    func hoverHighlightFillsTheCellWithoutChangingItsSize(style: FloatingBarStyle, scheme: ColorScheme) throws {
        let normal = try highlightImage(style: style, scheme: scheme)
        let hovered = try highlightImage(style: style, scheme: scheme, isHovered: true)
        #expect(hovered.pixelsWide == normal.pixelsWide)
        #expect(hovered.pixelsHigh == normal.pixelsHigh)
        for x in [5, hovered.pixelsWide / 2, hovered.pixelsWide - 6] {
            let normalColor = try #require(normal.colorAt(x: x, y: normal.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            let hoverColor = try #require(hovered.colorAt(x: x, y: hovered.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            #expect(normalColor.alphaComponent == 0)
            #expect(hoverColor.alphaComponent > 0.1)
            if scheme == .dark {
                #expect(hoverColor.redComponent > 0.9)
            } else {
                #expect(hoverColor.redComponent < 0.1)
            }
        }
        #expect(hovered.colorAt(x: 0, y: 0)?.alphaComponent == 0)
    }

    @Test(arguments: [false, true])
    func pressingProvidesFeedbackEvenWithoutHover(isHovered: Bool) throws {
        let hovered = try highlightImage(isHovered: true)
        let pressed = try highlightImage(isHovered: isHovered, isPressed: true)
        let hoverAlpha = try #require(hovered.colorAt(x: 5, y: 15)?.alphaComponent)
        let pressedAlpha = try #require(pressed.colorAt(x: 5, y: 15)?.alphaComponent)
        #expect(pressedAlpha > hoverAlpha)
        #expect(pressed.pixelsWide == hovered.pixelsWide)
        #expect(pressed.pixelsHigh == hovered.pixelsHigh)
    }

    @Test(arguments: [false, true], [false, true])
    func disabledItemsNeverShowInteractiveHighlight(isHovered: Bool, isPressed: Bool) throws {
        let image = try highlightImage(isHovered: isHovered, isPressed: isPressed, isEnabled: false)
        #expect(image.colorAt(x: 5, y: 15)?.alphaComponent == 0)
    }

    private func highlightImage(
        style: FloatingBarStyle = .vertical, scheme: ColorScheme = .light,
        isHovered: Bool = false, isPressed: Bool = false, isEnabled: Bool = true
    ) throws -> NSBitmapImageRep {
        let metrics = FloatingBarLayout.Metrics.default
        let width = metrics.itemExtent + (style == .vertical ? metrics.rowLabelWidth : 0)
        let content = FloatingBarItemButtonStyle.Content(
            label: Color.clear.frame(width: width, height: metrics.itemExtent),
            isPressed: isPressed, isHovered: isHovered
        )
        .environment(\.colorScheme, scheme)
        .environment(\.isEnabled, isEnabled)
        // ImageRenderer paints a disabled-state artifact here; use the panel's AppKit hosting path.
        let hosting = NSHostingController(rootView: content)
        hosting.view.frame = CGRect(x: 0, y: 0, width: width, height: metrics.itemExtent)
        hosting.view.layoutSubtreeIfNeeded()
        let image = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(metrics.itemExtent),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: image))
        context.cgContext.clear(hosting.view.bounds)
        hosting.view.cacheDisplay(in: hosting.view.bounds, to: image)
        #expect(hosting.view.window == nil)
        #expect(hosting.view.fittingSize == CGSize(width: width, height: metrics.itemExtent))
        return image
    }
}

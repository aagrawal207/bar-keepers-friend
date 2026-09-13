import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct MenuBarStyleGeometryTests {

    /// A 14" MacBook-style notched display in AppKit coordinates: menu bar strip y 945...982.
    private let notchedFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notchedBarHeight: CGFloat = 37
    private var notch: NotchGeometry {
        NotchGeometry(
            displayFrame: notchedFrame,
            leftArea: CGRect(x: 0, y: 945, width: 700, height: 37),
            rightArea: CGRect(x: 812, y: 945, width: 700, height: 37)
        )
    }

    /// An external display to the right of the primary, with its own 24pt bar.
    private let externalFrame = CGRect(x: 1512, y: -120, width: 2560, height: 1440)

    private func style(_ shape: MenuBarStyle.Shape, radius: Double = 8, enabled: Bool = true, opacity: Double = 0.5) -> MenuBarStyle {
        MenuBarStyle(isEnabled: enabled, opacity: opacity, cornerRadius: radius, shape: shape)
    }

    // MARK: needsOverlay

    @Test func disabledOrInvisibleStylesNeedNoOverlay() {
        #expect(!MenuBarStyleGeometry.needsOverlay(style: .none, displayFrame: notchedFrame, menuBarHeight: 24))
        #expect(!MenuBarStyleGeometry.needsOverlay(style: style(.full, opacity: 0), displayFrame: notchedFrame, menuBarHeight: 24))
        #expect(MenuBarStyleGeometry.needsOverlay(style: style(.full), displayFrame: notchedFrame, menuBarHeight: 24))
        #expect(MenuBarStyleGeometry.layout(displayFrame: notchedFrame, menuBarHeight: 24, notch: nil, style: .none) == nil)
    }

    @Test(arguments: [CGFloat(0), CGFloat(-1), CGFloat.nan, CGFloat.infinity])
    func hiddenOrBrokenMenuBarHeightsNeedNoOverlay(height: CGFloat) {
        #expect(!MenuBarStyleGeometry.needsOverlay(style: style(.full), displayFrame: notchedFrame, menuBarHeight: height))
        #expect(MenuBarStyleGeometry.layout(displayFrame: notchedFrame, menuBarHeight: height, notch: nil, style: style(.full)) == nil)
    }

    @Test(arguments: [CGRect.zero, CGRect(x: 0, y: 0, width: -10, height: 900), CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)])
    func degenerateDisplayFramesNeedNoOverlay(frame: CGRect) {
        #expect(!MenuBarStyleGeometry.needsOverlay(style: style(.full), displayFrame: frame, menuBarHeight: 24))
        #expect(MenuBarStyleGeometry.layout(displayFrame: frame, menuBarHeight: 24, notch: nil, style: style(.full)) == nil)
    }

    // MARK: Window frame

    @Test func windowFrameIsTheMenuBarStripOfTheDisplay() throws {
        let layout = try #require(MenuBarStyleGeometry.layout(
            displayFrame: externalFrame, menuBarHeight: 24, notch: nil, style: style(.full)
        ))
        #expect(layout.windowFrame == CGRect(x: 1512, y: -120 + 1440 - 24, width: 2560, height: 24))
        #expect(layout.contentSize == CGSize(width: 2560, height: 24))
        #expect(layout.shape == .full)
    }

    @Test func stackedAndLeftwardDisplaysKeepTheirOwnOffsets() throws {
        let above = CGRect(x: -400, y: 982, width: 1920, height: 1080)
        let layout = try #require(MenuBarStyleGeometry.layout(displayFrame: above, menuBarHeight: 24, notch: nil, style: style(.pill)))
        #expect(layout.windowFrame == CGRect(x: -400, y: 982 + 1080 - 24, width: 1920, height: 24))
        // Segments are window-local, so the display offset never leaks into them.
        let segment = try #require(layout.segments.first)
        #expect(segment.rect.minX == MenuBarStyleGeometry.pillHorizontalInset)
        #expect(segment.rect.maxX == 1920 - MenuBarStyleGeometry.pillHorizontalInset)
    }

    @Test func menuBarTallerThanTheDisplayIsClampedToIt() throws {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 20)
        let layout = try #require(MenuBarStyleGeometry.layout(displayFrame: tiny, menuBarHeight: 50, notch: nil, style: style(.full)))
        #expect(layout.windowFrame == CGRect(x: 0, y: 0, width: 300, height: 20))
        #expect(layout.segments.first?.rect == CGRect(x: 0, y: 0, width: 300, height: 20))
    }

    // MARK: Full

    @Test(arguments: [false, true])
    func fullBarIsOneContinuousSegmentEvenWithANotch(notched: Bool) throws {
        let layout = try #require(MenuBarStyleGeometry.layout(
            displayFrame: notchedFrame, menuBarHeight: notchedBarHeight, notch: notched ? notch : nil, style: style(.full, radius: 20)
        ))
        #expect(layout.segments.count == 1)
        let segment = try #require(layout.segments.first)
        #expect(segment.rect == CGRect(x: 0, y: 0, width: 1512, height: notchedBarHeight))
        #expect(segment.cornerRadius == 0)
        #expect(!segment.roundsTopCorners)
    }

    // MARK: Rounded

    @Test func roundedBarWithoutANotchStaysFlushWithTheTopAndSides() throws {
        let layout = try #require(MenuBarStyleGeometry.layout(
            displayFrame: externalFrame, menuBarHeight: 24, notch: nil, style: style(.rounded, radius: 10)
        ))
        #expect(layout.segments.count == 1)
        let segment = try #require(layout.segments.first)
        #expect(segment.rect == CGRect(x: 0, y: 0, width: 2560, height: 24))
        #expect(segment.cornerRadius == 10)
        #expect(!segment.roundsTopCorners)
    }

    @Test func roundedBarSplitsAroundTheNotch() throws {
        let layout = try #require(MenuBarStyleGeometry.layout(
            displayFrame: notchedFrame, menuBarHeight: notchedBarHeight, notch: notch, style: style(.rounded, radius: 12)
        ))
        #expect(layout.segments.count == 2)
        #expect(layout.segments[0].rect == CGRect(x: 0, y: 0, width: 700, height: notchedBarHeight))
        #expect(layout.segments[1].rect == CGRect(x: 812, y: 0, width: 700, height: notchedBarHeight))
        for segment in layout.segments {
            #expect(segment.cornerRadius == 12)
            #expect(!segment.roundsTopCorners)
        }
    }

    @Test func roundedRadiusIsClampedToTheBarHeightAndHalfWidth() throws {
        var style = style(.rounded, radius: 20)
        style.cornerRadius = 500 // normalized to the 20pt maximum first
        let short = try #require(MenuBarStyleGeometry.layout(displayFrame: externalFrame, menuBarHeight: 12, notch: nil, style: style))
        #expect(short.segments.first?.cornerRadius == 12)
        let narrow = try #require(MenuBarStyleGeometry.layout(
            displayFrame: CGRect(x: 0, y: 0, width: 30, height: 100), menuBarHeight: 24, notch: nil, style: style
        ))
        #expect(narrow.segments.first?.cornerRadius == 15)
    }

    // MARK: Pill

    @Test func pillIsInsetFromEveryEdgeAndRoundsAllCorners() throws {
        let layout = try #require(MenuBarStyleGeometry.layout(
            displayFrame: externalFrame, menuBarHeight: 24, notch: nil, style: style(.pill, radius: 20)
        ))
        let segment = try #require(layout.segments.first)
        let dx = MenuBarStyleGeometry.pillHorizontalInset
        let dy = MenuBarStyleGeometry.pillVerticalInset
        #expect(segment.rect == CGRect(x: dx, y: dy, width: 2560 - dx * 2, height: 24 - dy * 2))
        // A 20pt radius exceeds half the 20pt pill height, so the pill gets fully round ends.
        #expect(segment.cornerRadius == (24 - dy * 2) / 2)
        #expect(segment.roundsTopCorners)
    }

    @Test func pillSplitsAroundTheNotchWithInsetsOnBothSidesOfIt() throws {
        let layout = try #require(MenuBarStyleGeometry.layout(
            displayFrame: notchedFrame, menuBarHeight: notchedBarHeight, notch: notch, style: style(.pill, radius: 6)
        ))
        let dx = MenuBarStyleGeometry.pillHorizontalInset
        let dy = MenuBarStyleGeometry.pillVerticalInset
        #expect(layout.segments.count == 2)
        #expect(layout.segments[0].rect == CGRect(x: dx, y: dy, width: 700 - dx * 2, height: notchedBarHeight - dy * 2))
        #expect(layout.segments[1].rect == CGRect(x: 812 + dx, y: dy, width: 700 - dx * 2, height: notchedBarHeight - dy * 2))
        for segment in layout.segments {
            #expect(segment.cornerRadius == 6)
            #expect(segment.roundsTopCorners)
        }
    }

    @Test func pillSkipsInsetsThatWouldSwallowTheShape() throws {
        let sliver = CGRect(x: 0, y: 0, width: 20, height: 200)
        let layout = try #require(MenuBarStyleGeometry.layout(displayFrame: sliver, menuBarHeight: 6, notch: nil, style: style(.pill)))
        let segment = try #require(layout.segments.first)
        #expect(segment.rect == CGRect(x: 0, y: 0, width: 20, height: 6))
        #expect(segment.cornerRadius == 3)
    }

    // MARK: Notch edge cases

    @Test func notchOutsideOrEdgeOfTheDisplayIsIgnored() throws {
        let elsewhere = NotchGeometry(
            displayFrame: externalFrame,
            leftArea: CGRect(x: 1512, y: 1296, width: 1000, height: 24),
            rightArea: CGRect(x: 2600, y: 1296, width: 1472, height: 24)
        )
        // This notch belongs to the external display; applied to the built-in one it lies off-display.
        let layout = try #require(MenuBarStyleGeometry.layout(
            displayFrame: notchedFrame, menuBarHeight: notchedBarHeight, notch: elsewhere, style: style(.pill)
        ))
        #expect(layout.segments.count == 1)

        let flushLeft = NotchGeometry(
            displayFrame: notchedFrame,
            leftArea: CGRect(x: 0, y: 945, width: 0, height: 37),
            rightArea: CGRect(x: 100, y: 945, width: 1412, height: 37)
        )
        let flush = try #require(MenuBarStyleGeometry.layout(
            displayFrame: notchedFrame, menuBarHeight: notchedBarHeight, notch: flushLeft, style: style(.rounded)
        ))
        #expect(flush.segments.count == 1)
    }

    @Test func notchlessGeometrySplitsNothing() throws {
        let notchless = NotchGeometry(displayFrame: externalFrame, leftArea: nil, rightArea: nil)
        let layout = try #require(MenuBarStyleGeometry.layout(
            displayFrame: externalFrame, menuBarHeight: 24, notch: notchless, style: style(.pill)
        ))
        #expect(layout.segments.count == 1)
    }

    @Test func notchedExternalOffsetsProduceWindowLocalSegments() throws {
        // The same notch shape on a display that starts at x = 1512 must yield the same local rects.
        let shifted = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        let shiftedNotch = NotchGeometry(
            displayFrame: shifted,
            leftArea: CGRect(x: 1512, y: 945, width: 700, height: 37),
            rightArea: CGRect(x: 2324, y: 945, width: 700, height: 37)
        )
        let local = try #require(MenuBarStyleGeometry.layout(
            displayFrame: notchedFrame, menuBarHeight: notchedBarHeight, notch: notch, style: style(.rounded)
        ))
        let remote = try #require(MenuBarStyleGeometry.layout(
            displayFrame: shifted, menuBarHeight: notchedBarHeight, notch: shiftedNotch, style: style(.rounded)
        ))
        #expect(local.segments == remote.segments)
        #expect(remote.windowFrame.minX == 1512)
        #expect(local.windowFrame.minX == 0)
    }

    @Test func everySegmentStaysInsideTheWindow() {
        let displays: [(CGRect, CGFloat, NotchGeometry?)] = [
            (notchedFrame, notchedBarHeight, notch), (externalFrame, 24, nil),
            (CGRect(x: -3000, y: -500, width: 800, height: 600), 24, nil), (CGRect(x: 0, y: 0, width: 40, height: 40), 24, nil)
        ]
        for shape in MenuBarStyle.Shape.allCases {
            for radius in [0.0, 1, 8, 20] {
                for (frame, height, notch) in displays {
                    guard let layout = MenuBarStyleGeometry.layout(
                        displayFrame: frame, menuBarHeight: height, notch: notch, style: style(shape, radius: radius)
                    ) else {
                        Issue.record("Expected a layout for \(shape) on \(frame)")
                        continue
                    }
                    let bounds = CGRect(origin: .zero, size: layout.contentSize)
                    #expect(!layout.segments.isEmpty)
                    for segment in layout.segments {
                        #expect(bounds.contains(segment.rect))
                        #expect(segment.rect.width > 0 && segment.rect.height > 0)
                        #expect(segment.cornerRadius >= 0)
                        #expect(segment.cornerRadius <= segment.rect.width / 2 + 0.0001)
                        #expect(segment.cornerRadius <= segment.rect.height + 0.0001)
                        #expect(segment.roundsTopCorners == (shape == .pill))
                    }
                }
            }
        }
    }
}

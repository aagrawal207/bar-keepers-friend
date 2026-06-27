import CoreGraphics
import Testing
@testable import BarKeepersFriendCore

@Suite struct FloatingBarLayoutTests {

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let menuBarHeight: CGFloat = 24

    @Test func horizontalPanelWidthGrowsWithItemCount() {
        let m = FloatingBarLayout.Metrics.default
        let three = FloatingBarLayout.panelSize(style: .horizontal, itemCount: 3, metrics: m)
        let six = FloatingBarLayout.panelSize(style: .horizontal, itemCount: 6, metrics: m)
        #expect(six.width > three.width)
        #expect(three.height == six.height) // height fixed for horizontal
    }

    @Test func verticalPanelHeightGrowsWithItemCount() {
        let three = FloatingBarLayout.panelSize(style: .vertical, itemCount: 3)
        let six = FloatingBarLayout.panelSize(style: .vertical, itemCount: 6)
        #expect(six.height > three.height)
        #expect(three.width == six.width) // width fixed for vertical
    }

    @Test func panelSitsJustBelowMenuBar() {
        let result = FloatingBarLayout.layout(
            style: .horizontal, itemCount: 4,
            anchorRightX: 1400, menuBarHeight: menuBarHeight, displayFrame: display
        )
        #expect(result.panelFrame.minY == menuBarHeight + FloatingBarLayout.Metrics.default.gapBelowMenuBar)
    }

    @Test func panelRightEdgeAlignsUnderAnchorWhenRoom() {
        let result = FloatingBarLayout.layout(
            style: .horizontal, itemCount: 4,
            anchorRightX: 1000, menuBarHeight: menuBarHeight, displayFrame: display
        )
        // Right edge should land at the anchor x (within float tolerance).
        #expect(abs(result.panelFrame.maxX - 1000) < 0.5)
    }

    @Test func panelNeverOverflowsRightEdge() {
        // Anchor near the far right; panel must clamp inside the display.
        let result = FloatingBarLayout.layout(
            style: .horizontal, itemCount: 10,
            anchorRightX: 1510, menuBarHeight: menuBarHeight, displayFrame: display
        )
        let inset = FloatingBarLayout.Metrics.default.cornerInset
        #expect(result.panelFrame.maxX <= display.maxX - inset + 0.5)
        #expect(result.panelFrame.minX >= display.minX)
    }

    @Test func itemRectCountMatchesItemCount() {
        let h = FloatingBarLayout.layout(style: .horizontal, itemCount: 5, anchorRightX: 1000, menuBarHeight: menuBarHeight, displayFrame: display)
        #expect(h.itemRects.count == 5)
        let v = FloatingBarLayout.layout(style: .vertical, itemCount: 7, anchorRightX: 1000, menuBarHeight: menuBarHeight, displayFrame: display)
        #expect(v.itemRects.count == 7)
    }

    @Test func horizontalItemsLaidLeftToRightNonOverlapping() {
        let result = FloatingBarLayout.layout(style: .horizontal, itemCount: 4, anchorRightX: 1000, menuBarHeight: menuBarHeight, displayFrame: display)
        let xs = result.itemRects.map(\.minX)
        #expect(xs == xs.sorted())
        for i in 1..<result.itemRects.count {
            #expect(result.itemRects[i].minX >= result.itemRects[i - 1].maxX - 0.001)
        }
    }

    @Test func zeroItemsProducesNoItemRects() {
        let result = FloatingBarLayout.layout(style: .horizontal, itemCount: 0, anchorRightX: 1000, menuBarHeight: menuBarHeight, displayFrame: display)
        #expect(result.itemRects.isEmpty)
    }
}

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
}

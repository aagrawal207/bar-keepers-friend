import CoreGraphics
import Foundation

/// The two presentations of the floating bar that mirrors hidden items.
public enum FloatingBarStyle: String, CaseIterable, Sendable, Codable {
    /// A single horizontal row of icons (Bartender/Ice style).
    case horizontal
    /// A vertical list of icon + name rows.
    case vertical
}

/// Pure geometry for the floating panel that appears below the menu bar.
///
/// Computes the panel's frame and each item's rect within it for both styles, keeping the
/// panel fully on-screen and right-aligned under the anchor (matching where the items came
/// from). All of this is testable without ever creating an `NSPanel`.
public enum FloatingBarLayout {

    /// Visual constants shared by both layouts.
    public struct Metrics: Equatable, Sendable {
        public var itemExtent: CGFloat       // width (horizontal) or height (vertical) per item
        public var iconSize: CGFloat
        public var rowLabelWidth: CGFloat    // extra width for the name in vertical style
        public var padding: CGFloat          // inner padding around the item run
        public var gapBelowMenuBar: CGFloat  // vertical gap between menu bar and panel
        public var cornerInset: CGFloat      // keep this far from the screen's right/left edge

        public init(
            itemExtent: CGFloat = 30,
            iconSize: CGFloat = 18,
            rowLabelWidth: CGFloat = 160,
            padding: CGFloat = 8,
            gapBelowMenuBar: CGFloat = 4,
            cornerInset: CGFloat = 8
        ) {
            self.itemExtent = itemExtent
            self.iconSize = iconSize
            self.rowLabelWidth = rowLabelWidth
            self.padding = padding
            self.gapBelowMenuBar = gapBelowMenuBar
            self.cornerInset = cornerInset
        }

        public static let `default` = Metrics()
    }

    /// The computed layout: where to put the panel and each item inside it.
    public struct Result: Equatable, Sendable {
        /// Panel frame in global (screen) coordinates, with a top-left origin convention
        /// (y measured down from the top of the display) for ease of testing.
        public let panelFrame: CGRect
        /// Item rects relative to the panel's own coordinate space (top-left origin).
        public let itemRects: [CGRect]

        public init(panelFrame: CGRect, itemRects: [CGRect]) {
            self.panelFrame = panelFrame
            self.itemRects = itemRects
        }
    }

    /// Computes the floating bar layout.
    ///
    /// - Parameters:
    ///   - style: horizontal strip or vertical list.
    ///   - itemCount: number of hidden items to show.
    ///   - anchorRightX: the right edge (global x) under which the panel should align — the
    ///     anchor control item's position, so the bar opens beneath it.
    ///   - menuBarHeight: height of the system menu bar (panel sits just below it).
    ///   - displayFrame: the display's frame (top-left origin) used to clamp on-screen.
    ///   - metrics: visual constants.
    public static func layout(
        style: FloatingBarStyle,
        itemCount: Int,
        anchorRightX: CGFloat,
        menuBarHeight: CGFloat,
        displayFrame: CGRect,
        metrics: Metrics = .default
    ) -> Result {
        let count = max(0, itemCount)

        let panelSize = panelSize(style: style, itemCount: count, metrics: metrics)

        // Right edge aligns under the anchor, but never past the screen's right inset.
        let maxRight = displayFrame.maxX - metrics.cornerInset
        let desiredRight = min(anchorRightX, maxRight)
        var originX = desiredRight - panelSize.width
        // Clamp to the left edge too.
        originX = max(displayFrame.minX + metrics.cornerInset, originX)

        let originY = displayFrame.minY + menuBarHeight + metrics.gapBelowMenuBar

        let panelFrame = CGRect(x: originX, y: originY, width: panelSize.width, height: panelSize.height)
        let itemRects = itemRects(style: style, itemCount: count, panelSize: panelSize, metrics: metrics)
        return Result(panelFrame: panelFrame, itemRects: itemRects)
    }

    /// The panel's size for a given style and item count.
    public static func panelSize(
        style: FloatingBarStyle,
        itemCount: Int,
        metrics: Metrics = .default
    ) -> CGSize {
        let count = max(0, itemCount)
        switch style {
        case .horizontal:
            let width = metrics.padding * 2 + CGFloat(count) * metrics.itemExtent
            let height = metrics.padding * 2 + metrics.itemExtent
            return CGSize(width: max(width, metrics.padding * 2 + metrics.itemExtent), height: height)
        case .vertical:
            let width = metrics.padding * 2 + metrics.itemExtent + metrics.rowLabelWidth
            let height = metrics.padding * 2 + CGFloat(count) * metrics.itemExtent
            return CGSize(width: width, height: max(height, metrics.padding * 2 + metrics.itemExtent))
        }
    }

    /// Per-item rects within the panel (top-left origin).
    public static func itemRects(
        style: FloatingBarStyle,
        itemCount: Int,
        panelSize: CGSize,
        metrics: Metrics = .default
    ) -> [CGRect] {
        let count = max(0, itemCount)
        guard count > 0 else { return [] }
        switch style {
        case .horizontal:
            return (0..<count).map { i in
                CGRect(
                    x: metrics.padding + CGFloat(i) * metrics.itemExtent,
                    y: metrics.padding,
                    width: metrics.itemExtent,
                    height: metrics.itemExtent
                )
            }
        case .vertical:
            let rowWidth = panelSize.width - metrics.padding * 2
            return (0..<count).map { i in
                CGRect(
                    x: metrics.padding,
                    y: metrics.padding + CGFloat(i) * metrics.itemExtent,
                    width: rowWidth,
                    height: metrics.itemExtent
                )
            }
        }
    }
}

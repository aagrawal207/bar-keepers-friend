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

        // How many items fit along the panel's primary axis before it must WRAP, so a large
        // hidden set never grows the panel past the screen (which would push items off-screen and
        // out of reach). Horizontal wraps into extra rows; vertical wraps into extra columns.
        let perLine = itemsPerLine(style: style, displayFrame: displayFrame, menuBarHeight: menuBarHeight, metrics: metrics)
        let grid = gridDimensions(style: style, itemCount: count, perLine: perLine)

        let panelSize = panelSize(style: style, columns: grid.columns, rows: grid.rows, metrics: metrics)
        let frame = panelFrame(
            contentSize: panelSize, anchorRightX: anchorRightX, menuBarHeight: menuBarHeight,
            displayFrame: displayFrame, metrics: metrics
        )
        let itemRects = itemRects(style: style, itemCount: count, columns: grid.columns, rows: grid.rows, panelSize: panelSize, metrics: metrics)
        return Result(panelFrame: frame, itemRects: itemRects)
    }

    /// Positions either a grid or an intrinsically sized empty/preparing view below the anchor.
    public static func panelFrame(
        contentSize: CGSize,
        anchorRightX: CGFloat,
        menuBarHeight: CGFloat,
        displayFrame: CGRect,
        metrics: Metrics = .default
    ) -> CGRect {
        let maxRight = displayFrame.maxX - metrics.cornerInset
        let desiredRight = min(anchorRightX, maxRight)
        let originX = max(displayFrame.minX + metrics.cornerInset, desiredRight - contentSize.width)
        let originY = displayFrame.minY + menuBarHeight + metrics.gapBelowMenuBar
        return CGRect(origin: CGPoint(x: originX, y: originY), size: contentSize)
    }

    /// How many items fit along the panel's primary axis (a horizontal row's width, or a vertical
    /// column's height) within the usable screen extent, before the panel must wrap to a new
    /// line. Always at least 1 so a single very large item still lays out. The usable extent
    /// leaves the corner inset on both sides (horizontal) and the menu bar + gap + inset
    /// (vertical).
    public static func itemsPerLine(
        style: FloatingBarStyle,
        displayFrame: CGRect,
        menuBarHeight: CGFloat,
        metrics: Metrics = .default
    ) -> Int {
        switch style {
        case .horizontal:
            let usableWidth = displayFrame.width - metrics.cornerInset * 2 - metrics.padding * 2
            return max(1, Int(usableWidth / metrics.itemExtent))
        case .vertical:
            let usableHeight = displayFrame.height - menuBarHeight - metrics.gapBelowMenuBar
                - metrics.cornerInset - metrics.padding * 2
            return max(1, Int(usableHeight / metrics.itemExtent))
        }
    }

    /// Splits `itemCount` items into a grid. For horizontal, `perLine` is items-per-row and the
    /// grid grows in rows; for vertical, `perLine` is items-per-column and the grid grows in
    /// columns. Returns at least 1×1 (even for zero items, so the empty panel has a sensible size).
    public static func gridDimensions(
        style: FloatingBarStyle,
        itemCount: Int,
        perLine: Int
    ) -> (columns: Int, rows: Int) {
        let count = max(0, itemCount)
        let line = max(1, perLine)
        guard count > 0 else { return (1, 1) }
        switch style {
        case .horizontal:
            let columns = min(count, line)
            let rows = Int(ceil(Double(count) / Double(line)))
            return (columns, rows)
        case .vertical:
            let rows = min(count, line)
            let columns = Int(ceil(Double(count) / Double(line)))
            return (columns, rows)
        }
    }

    /// The panel's size for a single line of items (no wrapping). Retained for callers/tests that
    /// reason about how the panel grows with item count along its primary axis; the wrapping
    /// layout uses `panelSize(style:columns:rows:)`.
    public static func panelSize(
        style: FloatingBarStyle,
        itemCount: Int,
        metrics: Metrics = .default
    ) -> CGSize {
        let count = max(1, itemCount) // a single line of at least one item
        switch style {
        case .horizontal:
            return panelSize(style: .horizontal, columns: count, rows: 1, metrics: metrics)
        case .vertical:
            return panelSize(style: .vertical, columns: 1, rows: count, metrics: metrics)
        }
    }

    /// The panel's size for a grid of `columns` × `rows` item cells.
    ///
    /// Horizontal cells are square (`itemExtent` each way); vertical cells are a fixed-width row
    /// (icon + label). Always at least one cell so an empty panel still has a sensible size.
    public static func panelSize(
        style: FloatingBarStyle,
        columns: Int,
        rows: Int,
        metrics: Metrics = .default
    ) -> CGSize {
        let cols = CGFloat(max(1, columns))
        let rws = CGFloat(max(1, rows))
        switch style {
        case .horizontal:
            let width = metrics.padding * 2 + cols * metrics.itemExtent
            let height = metrics.padding * 2 + rws * metrics.itemExtent
            return CGSize(width: width, height: height)
        case .vertical:
            let columnWidth = metrics.itemExtent + metrics.rowLabelWidth
            let width = metrics.padding * 2 + cols * columnWidth
            let height = metrics.padding * 2 + rws * metrics.itemExtent
            return CGSize(width: width, height: height)
        }
    }

    /// Per-item rects within the panel (top-left origin), laid into a `columns` × `rows` grid.
    ///
    /// Horizontal fills left-to-right then wraps to the next row down; vertical fills top-to-
    /// bottom then wraps to the next column right. This keeps every item on-screen no matter how
    /// many are hidden — a single overlong strip would otherwise spill past the display edge.
    public static func itemRects(
        style: FloatingBarStyle,
        itemCount: Int,
        columns: Int,
        rows: Int,
        panelSize: CGSize,
        metrics: Metrics = .default
    ) -> [CGRect] {
        let count = max(0, itemCount)
        guard count > 0 else { return [] }
        let cols = max(1, columns)
        let rws = max(1, rows)
        switch style {
        case .horizontal:
            return (0..<count).map { i in
                let row = i / cols
                let col = i % cols
                return CGRect(
                    x: metrics.padding + CGFloat(col) * metrics.itemExtent,
                    y: metrics.padding + CGFloat(row) * metrics.itemExtent,
                    width: metrics.itemExtent,
                    height: metrics.itemExtent
                )
            }
        case .vertical:
            let columnWidth = metrics.itemExtent + metrics.rowLabelWidth
            return (0..<count).map { i in
                let col = i / rws
                let row = i % rws
                return CGRect(
                    x: metrics.padding + CGFloat(col) * columnWidth,
                    y: metrics.padding + CGFloat(row) * metrics.itemExtent,
                    width: columnWidth,
                    height: metrics.itemExtent
                )
            }
        }
    }
}

import CoreGraphics

/// Pure frame math for the per-display style overlay, in AppKit screen coordinates: the window is
/// the menu bar strip; rounded and pill shapes split around a notch like the system's own bar.
public enum MenuBarStyleGeometry {

    /// Horizontal gap a pill keeps from the display edges and from the notch.
    public static let pillHorizontalInset: CGFloat = 6
    /// Vertical gap a pill keeps from the top and bottom of the strip; items stay centered either way.
    public static let pillVerticalInset: CGFloat = 2

    /// One painted shape, in the overlay window's own coordinates.
    public struct Segment: Equatable, Sendable {
        public let rect: CGRect
        /// Already clamped so the arcs fit inside `rect`; 0 for `.full`.
        public let cornerRadius: CGFloat
        /// Pills round every corner; rounded bars keep square top corners flush with the display edge.
        public let roundsTopCorners: Bool

        public init(rect: CGRect, cornerRadius: CGFloat, roundsTopCorners: Bool) {
            self.rect = rect
            self.cornerRadius = cornerRadius
            self.roundsTopCorners = roundsTopCorners
        }
    }

    public struct Layout: Equatable, Sendable {
        /// The overlay window's frame: exactly the display's menu bar strip, in screen coordinates.
        public let windowFrame: CGRect
        public let segments: [Segment]
        public let shape: MenuBarStyle.Shape

        public init(windowFrame: CGRect, segments: [Segment], shape: MenuBarStyle.Shape) {
            self.windowFrame = windowFrame
            self.segments = segments
            self.shape = shape
        }

        public var contentSize: CGSize { windowFrame.size }
    }

    /// Whether a display with this menu bar height should carry an overlay for `style` at all.
    /// False for a disabled or fully transparent style, a hidden menu bar, or a degenerate display.
    public static func needsOverlay(style: MenuBarStyle, displayFrame: CGRect, menuBarHeight: CGFloat) -> Bool {
        guard style.isVisible else { return false }
        // Raw size, not `width`/`height`: those report magnitudes and would accept a negative size.
        guard !displayFrame.isNull, !displayFrame.isInfinite,
              displayFrame.minX.isFinite, displayFrame.minY.isFinite,
              displayFrame.size.width.isFinite, displayFrame.size.height.isFinite,
              displayFrame.size.width > 0, displayFrame.size.height > 0 else { return false }
        return menuBarHeight.isFinite && menuBarHeight > 0
    }

    /// The overlay for one display, or nil when it needs none (see `needsOverlay`).
    /// `notch` is consulted only for its x-range and only when that range lies inside the display.
    public static func layout(
        displayFrame: CGRect,
        menuBarHeight: CGFloat,
        notch: NotchGeometry?,
        style: MenuBarStyle
    ) -> Layout? {
        guard needsOverlay(style: style, displayFrame: displayFrame, menuBarHeight: menuBarHeight) else { return nil }
        let style = style.normalized()
        let height = min(menuBarHeight, displayFrame.height)
        let windowFrame = CGRect(
            x: displayFrame.minX, y: displayFrame.maxY - height,
            width: displayFrame.width, height: height
        )
        // Local x-spans to paint. A full bar stays continuous; the notch simply covers its middle.
        var spans: [ClosedRange<CGFloat>] = [0...displayFrame.width]
        if style.shape != .full, let range = notch?.notchXRange,
           range.lowerBound > displayFrame.minX, range.upperBound < displayFrame.maxX {
            spans = [
                0...(range.lowerBound - displayFrame.minX),
                (range.upperBound - displayFrame.minX)...displayFrame.width
            ]
        }
        let segments = spans.compactMap { span in
            segment(spanning: span, height: height, style: style)
        }
        return Layout(windowFrame: windowFrame, segments: segments, shape: style.shape)
    }

    private static func segment(spanning span: ClosedRange<CGFloat>, height: CGFloat, style: MenuBarStyle) -> Segment? {
        let width = span.upperBound - span.lowerBound
        guard width > 0 else { return nil }
        let radius = CGFloat(style.cornerRadius)
        switch style.shape {
        case .full:
            return Segment(
                rect: CGRect(x: span.lowerBound, y: 0, width: width, height: height),
                cornerRadius: 0, roundsTopCorners: false
            )
        case .rounded:
            // Only the bottom corners curve, so the radius may use the whole height.
            return Segment(
                rect: CGRect(x: span.lowerBound, y: 0, width: width, height: height),
                cornerRadius: min(radius, height, width / 2), roundsTopCorners: false
            )
        case .pill:
            let dx = width > pillHorizontalInset * 4 ? pillHorizontalInset : 0
            let dy = height > pillVerticalInset * 4 ? pillVerticalInset : 0
            let rect = CGRect(x: span.lowerBound + dx, y: dy, width: width - dx * 2, height: height - dy * 2)
            return Segment(
                rect: rect,
                cornerRadius: min(radius, rect.height / 2, rect.width / 2), roundsTopCorners: true
            )
        }
    }
}

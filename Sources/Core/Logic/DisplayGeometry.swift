import CoreGraphics

/// Pure conversions between AppKit's screen coordinate space (bottom-left origin, y grows up)
/// and CoreGraphics' global space (top-left origin, y grows down) for multi-display rigs.
///
/// `NSScreen.frame` is bottom-left; the window snapshots from `CGWindowListCopyWindowInfo` are
/// top-left. The two share an x-axis but flip y, and the flip is anchored to the **primary
/// display** — the one whose AppKit frame origin is `(0, 0)`. The CG-global y of any screen's top
/// edge is therefore `primaryHeight − screenFrame.maxY`, where `primaryHeight` is the primary's
/// height. Getting "the primary" wrong (e.g. trusting `NSScreen.screens.first`, whose order is not
/// guaranteed to lead with the primary) skews every off-primary display's converted y.
///
/// This holds only the arithmetic so it can be unit-tested against synthetic frames, without a
/// real `NSScreen`. The app passes the live `NSScreen.frame`s in.
public enum DisplayGeometry {

    /// The height of the primary display — the screen whose AppKit frame origin is `(0, 0)` — given
    /// all screens' AppKit frames. Returns `nil` if no zero-origin screen is present (e.g. an empty
    /// list, or a transient state during a display reconfiguration), so the caller can no-op rather
    /// than compute against a wrong anchor.
    ///
    /// We match on origin rather than array position: `NSScreen.screens` is not documented to place
    /// the primary first, and on a multi-display rig it frequently doesn't.
    public static func primaryHeight(screenFrames: [CGRect]) -> CGFloat? {
        screenFrames.first { $0.origin == .zero }?.height
    }

    /// The CoreGraphics-global y of a screen's top edge (its menu-bar top), given that screen's
    /// AppKit frame and the primary display's height. This is the value the snapshot frames are
    /// measured in, so it is what the plausibility filter's per-display top should use.
    ///
    /// For the primary itself (`maxY == primaryHeight`) this is 0, matching the single-display
    /// default. A display stacked above the primary yields a negative top; one stacked below yields
    /// a positive top.
    public static func cgTopY(screenFrame: CGRect, primaryHeight: CGFloat) -> CGFloat {
        primaryHeight - screenFrame.maxY
    }

    /// Convenience: the CG-global menu-bar top of `screenFrame`, resolving the primary height from
    /// the full set of screen frames. Returns `0` (the safe single-display default) when the
    /// primary can't be resolved, so a transient reconfiguration never produces a wild offset.
    public static func menuBarTopY(of screenFrame: CGRect, allScreenFrames: [CGRect]) -> CGFloat {
        guard let primaryHeight = primaryHeight(screenFrames: allScreenFrames) else { return 0 }
        return cgTopY(screenFrame: screenFrame, primaryHeight: primaryHeight)
    }
}

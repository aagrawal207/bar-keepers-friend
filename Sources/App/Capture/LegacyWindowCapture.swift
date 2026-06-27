import CoreGraphics
import Foundation

/// Bridges to the legacy `CGWindowListCreateImage`, which is compile-time `unavailable` on
/// macOS 26 but still present and functional at runtime.
///
/// Unlike ScreenCaptureKit — which can enumerate but NOT render windows that are entirely
/// off-screen — this API captures a window by id regardless of whether it is on-screen.
/// That is exactly what the floating bar needs: the hidden menu bar items are pushed to
/// negative x by the expanded divider, and `SCScreenshotManager` returns nil for them.
/// This is the same mechanism Ice/Bartender rely on for off-screen item capture.
///
/// Resolved via `dlsym` so the `unavailable` Swift declaration never blocks compilation.
/// Reading another window's pixels requires Screen Recording (TCC) permission, which the
/// app requests up front.
enum LegacyWindowCapture {
    private typealias CreateImageFn = @convention(c) (
        CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption
    ) -> Unmanaged<CGImage>?

    private static let createImage: CreateImageFn? = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImageFn.self)
    }()

    /// Whether the legacy symbol resolved at launch.
    static var isAvailable: Bool { createImage != nil }

    /// Captures the image of a single window by id, including when it is off-screen.
    /// Returns `nil` if the symbol is unavailable, permission is missing, or the window
    /// can't be rendered.
    static func captureImage(windowID: CGWindowID) -> CGImage? {
        guard let createImage else { return nil }
        // .null screen bounds → use the window's own bounds. Include just this window,
        // ignore framing/shadow, render at full resolution.
        let imageOption: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return createImage(.null, .optionIncludingWindow, windowID, imageOption)?.takeRetainedValue()
    }
}

import AppKit
import BarKeepersFriendCore
import CoreGraphics
import ScreenCaptureKit

/// Captures bitmap images of menu bar status items so the floating bar can mirror them.
///
/// This is the reason the app needs Screen Recording permission. On macOS 26 a per-window
/// capture of a status item returns a transparent image (the glyph is composited into the
/// menu bar layer, not the item's own window backing), and an off-screen item can't be
/// captured at all. So we capture the whole DISPLAY once and crop to each item's on-screen
/// frame in-process — callers must capture while items are visible and cache the result.
///
/// Capturing the full display once (instead of one ScreenCaptureKit call per item) keeps the
/// units unambiguous: we never juggle `sourceRect`/`destinationRect`, we just crop a known
/// pixel buffer. It is also far faster (one capture transaction, not N) and correct across
/// displays with different backing scale factors.
@MainActor
final class IconCaptureService {

    /// Whether Screen Recording appears granted. `CGPreflightScreenCaptureAccess` only
    /// reflects launch-time state, so a run of empty captures is also treated as a lapse.
    nonisolated var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the Screen Recording permission prompt. Touching `SCShareableContent` is the
    /// reliable trigger on macOS 15+, with the CoreGraphics request as a fallback.
    func requestScreenRecordingAccess() async {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Captures images for the given items by cropping a single full-display capture, returning
    /// window id → image for those that succeeded. Only items currently on-screen
    /// (`frame.minX >= 0`) can be captured.
    func captureIcons(for items: [MenuBarItemSnapshot]) async -> [CGWindowID: CGImage] {
        let onScreen = items.filter { $0.frame.minX >= 0 }
        guard !onScreen.isEmpty else { return [:] }
        guard let (display, displayBounds) = await display(containing: onScreen) else { return [:] }
        guard let full = await captureFullDisplay(display, displayBounds) else {
            DebugLog.log("capture: full-display capture failed")
            return [:]
        }

        // Derive the scale from the returned image rather than assuming 2x: external displays
        // can be 1x and some panels aren't exactly 2x. This keeps crops pixel-accurate.
        let scale = displayBounds.width > 0 ? CGFloat(full.width) / displayBounds.width : 2
        let imageBounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)

        var result: [CGWindowID: CGImage] = [:]
        for item in onScreen {
            // Item frames are global, top-left origin (same space as the display bounds), so
            // subtract the display origin before scaling to pixels.
            let cropPoints = CGRect(
                x: (item.frame.minX - displayBounds.minX) * scale,
                y: (item.frame.minY - displayBounds.minY) * scale,
                width: item.frame.width * scale,
                height: max(item.frame.height, 24) * scale
            ).integral
            let crop = cropPoints.intersection(imageBounds)
            guard !crop.isEmpty, let cropped = full.cropping(to: crop) else { continue }
            result[item.windowID] = cropped
        }

        let opacity = result.map { "\($0.key)=\(opaquePixelCount($0.value))" }.joined(separator: ",")
        DebugLog.log("capture: strip-cropped \(result.count)/\(onScreen.count) on-screen items; scale=\(scale); opaque[\(opacity)]")
        return result
    }

    // MARK: - Capture

    /// Captures the entire display as a single image (no `sourceRect`/`destinationRect`, so
    /// there is no point/pixel unit ambiguity — the output is the whole display in pixels).
    private func captureFullDisplay(_ display: SCDisplay, _ displayBounds: CGRect) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false
        // Request native pixels. `display.width/height` are already pixel dimensions.
        config.width = display.width
        config.height = display.height
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The shareable display whose global bounds contain the items, with its global bounds
    /// (top-left origin, points). Falls back to the first shareable display.
    private func display(containing items: [MenuBarItemSnapshot]) async -> (SCDisplay, CGRect)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              !content.displays.isEmpty else { return nil }
        // Match the display whose bounds contain an item's midpoint (the menu bar lives on the
        // display the items belong to, which may not be the first one on a multi-display rig).
        let probe = items.first.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        for display in content.displays {
            let bounds = CGDisplayBounds(display.displayID)
            if let probe, bounds.contains(probe) {
                return (display, bounds)
            }
        }
        let first = content.displays[0]
        return (first, CGDisplayBounds(first.displayID))
    }

    // MARK: - Diagnostics

    /// Counts non-transparent pixels in an image, used only for the capture debug log so we
    /// can tell a successful-but-transparent capture from one that actually has glyph pixels.
    private func opaquePixelCount(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return 0 }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &alpha,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return alpha.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
    }
}

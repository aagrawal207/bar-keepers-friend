import AppKit
import BarKeepersFriendCore
import CoreGraphics
import ScreenCaptureKit

/// Captures bitmap images of menu bar status items so the floating bar can mirror them.
///
/// This is the reason the app needs Screen Recording permission. On macOS 26 a per-window
/// capture of a status item returns a transparent image (the glyph is composited into the
/// menu bar layer, not the item's own window backing), and an off-screen item can't be
/// captured at all. So we capture the DISPLAY and crop to each item's on-screen frame —
/// callers must capture while items are visible and cache the result.
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

    /// Captures images for the given items by their on-screen display region, returning
    /// window id → image for those that succeeded. Only items currently on-screen
    /// (`frame.minX >= 0`) can be captured.
    func captureIcons(for items: [MenuBarItemSnapshot]) async -> [CGWindowID: CGImage] {
        guard !items.isEmpty else { return [:] }
        guard let (display, displayFrame) = await firstDisplay() else { return [:] }

        var result: [CGWindowID: CGImage] = [:]
        for item in items where item.frame.minX >= 0 {
            let rect = CGRect(
                x: item.frame.minX,
                y: 0,
                width: item.frame.width,
                height: max(item.frame.height, 24)
            )
            if let image = await captureDisplayRegion(rect, display: display, fullDisplayFrame: displayFrame) {
                result[item.windowID] = image
            }
        }
        DebugLog.log("capture: rect-captured \(result.count)/\(items.count) on-screen items")
        return result
    }

    /// Captures a rectangular region of the display by cropping a full-display capture.
    private func captureDisplayRegion(_ rect: CGRect, display: SCDisplay, fullDisplayFrame: CGRect) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = 2 // Retina
        config.showsCursor = false
        // sourceRect is in points, top-left origin relative to the display.
        config.sourceRect = rect
        config.destinationRect = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        config.width = max(Int(rect.width) * scale, 1)
        config.height = max(Int(rect.height) * scale, 1)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The first available shareable display and its frame, if any.
    private func firstDisplay() async -> (SCDisplay, CGRect)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first else { return nil }
        return (display, CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height)))
    }
}

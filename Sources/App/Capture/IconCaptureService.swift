import AppKit
import BarKeepersFriendCore
import CoreGraphics
import ScreenCaptureKit

/// Captures bitmap images of menu bar status items — including ones pushed off-screen by
/// the hidden divider — so the floating bar can mirror them.
///
/// This is the reason the app needs Screen Recording permission. On macOS 26 the legacy
/// `CGWindowListCreateImage` family is compile-time unavailable, so we use ScreenCaptureKit:
/// `SCShareableContent` enumerates every status-item window (even off-screen ones, verified
/// on Tahoe) and `SCScreenshotManager.captureImage` renders an individual window to a
/// `CGImage`. The whole capture surface is isolated here behind a small async API.
@MainActor
final class IconCaptureService {

    enum CaptureError: Error {
        case screenRecordingNotGranted
        case noMatchingWindow(CGWindowID)
    }

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

    /// Captures images for the given items, returning window id → image for those that
    /// succeeded. A fully empty result when items were requested signals that Screen
    /// Recording is denied or has lapsed.
    ///
    /// Hidden menu bar items are pushed off-screen (negative x), and `SCScreenshotManager`
    /// cannot render off-screen windows — so we use the legacy `CGWindowListCreateImage`
    /// path (off-screen-capable) first, falling back to ScreenCaptureKit for any that miss.
    func captureIcons(for items: [MenuBarItemSnapshot]) async -> [CGWindowID: CGImage] {
        guard !items.isEmpty else { return [:] }

        var result: [CGWindowID: CGImage] = [:]
        var legacyFailed: [CGWindowID] = []

        // Primary path: legacy capture, which works for off-screen windows.
        for item in items {
            if let image = LegacyWindowCapture.captureImage(windowID: item.windowID) {
                result[item.windowID] = image
            } else {
                legacyFailed.append(item.windowID)
            }
        }

        // Fallback path: ScreenCaptureKit for anything the legacy path missed.
        if !legacyFailed.isEmpty {
            let sckResults = await captureViaScreenCaptureKit(windowIDs: Set(legacyFailed))
            for (id, image) in sckResults { result[id] = image }
            let stillMissing = legacyFailed.filter { result[$0] == nil }
            DebugLog.log("capture: legacy got \(items.count - legacyFailed.count)/\(items.count), SCK recovered \(sckResults.count), stillMissing=\(stillMissing.sorted()) legacyAvailable=\(LegacyWindowCapture.isAvailable)")
        }
        return result
    }

    /// Captures a rectangular region of the display by cropping a full-display capture.
    /// Menu bar status-item glyphs are composited by the window server into the menu bar
    /// layer, not into each item's own window backing — so a per-window capture comes back
    /// transparent. Capturing the display and cropping to the item's frame gets real pixels.
    func captureDisplayRegion(_ rect: CGRect, display: SCDisplay, fullDisplayFrame: CGRect) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = 2 // Retina
        config.width = Int(fullDisplayFrame.width) * scale
        config.height = Int(fullDisplayFrame.height) * scale
        config.showsCursor = false
        // sourceRect is in points with a top-left origin relative to the display.
        config.sourceRect = rect
        config.destinationRect = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        config.width = max(Int(rect.width) * scale, 1)
        config.height = max(Int(rect.height) * scale, 1)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The first available shareable display, if any.
    func firstDisplay() async -> (SCDisplay, CGRect)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first else { return nil }
        return (display, CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height)))
    }

    /// ScreenCaptureKit fallback for the given window ids.
    private func captureViaScreenCaptureKit(windowIDs: Set<CGWindowID>) async -> [CGWindowID: CGImage] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return [:]
        }
        let windowsByID = Dictionary(
            content.windows.map { (CGWindowID($0.windowID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [CGWindowID: CGImage] = [:]
        for id in windowIDs {
            guard let window = windowsByID[id] else { continue }
            if let image = await captureWindow(window) {
                result[id] = image
            }
        }
        return result
    }

    /// Captures a single `SCWindow` to a `CGImage` at its natural pixel size.
    private func captureWindow(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(Int(window.frame.width * 2), 1)   // 2x for Retina crispness
        config.height = max(Int(window.frame.height * 2), 1)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Debug helper: dumps captured icons to PNGs under `directory`, so a build can verify
    /// capture works on the current OS. Returns the files written.
    @discardableResult
    func dumpCaptures(for items: [MenuBarItemSnapshot], to directory: URL) async -> [URL] {
        let captures = await captureIcons(for: items)
        var written: [URL] = []
        for (windowID, cgImage) in captures {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let url = directory.appendingPathComponent("icon-\(windowID).png")
            if (try? data.write(to: url)) != nil {
                written.append(url)
            }
        }
        return written
    }
}

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
    func captureIcons(for items: [MenuBarItemSnapshot]) async -> [CGWindowID: CGImage] {
        guard !items.isEmpty else { return [:] }
        let wantedIDs = Set(items.map(\.windowID))

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
        for id in wantedIDs {
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

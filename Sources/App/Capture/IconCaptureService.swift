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
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              !content.displays.isEmpty else { return [:] }

        let probe = onScreen.first.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        let display = displayContaining(probe, in: content.displays) ?? content.displays[0]
        let displayBounds = CGDisplayBounds(display.displayID)

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
            if ProcessInfo.processInfo.environment["BKF_DUMP_CROPS"] != nil {
                dumpRawCrop(cropped, windowID: item.windowID)
            }
            // Key out the wallpaper background and trim to the glyph. A nil result means the
            // crop had no glyph — typically the capture caught the menu bar mid-reveal before
            // the glyphs composited in. We deliberately do NOT fall back to the raw crop (an
            // opaque wallpaper tile); the caller validates the returned count and re-captures.
            guard let glyph = removingBackground(from: cropped) else { continue }
            result[item.windowID] = glyph
        }

        let frames = onScreen.map { "\($0.windowID)=\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX))" }.joined(separator: ",")
        let opacity = result.map { "\($0.key)=\(opaquePixelCount($0.value))" }.joined(separator: ",")
        DebugLog.log("capture: strip-cropped \(result.count)/\(onScreen.count) on-screen items; scale=\(scale); frames[\(frames)]; opaque[\(opacity)]")
        return result
    }

    // MARK: - Capture

    /// Captures the entire display as a single image (no `sourceRect`/`destinationRect`, so
    /// there is no point/pixel unit ambiguity — the output is the whole display in pixels).
    ///
    /// Note: we deliberately do NOT exclude the wallpaper/backdrop windows. Excluding `layer < 0`
    /// windows removed the desktop but also left the status glyphs compositing to nothing
    /// (crops came back fully transparent/black). Capturing the full composited display keeps
    /// the real glyphs; any wallpaper fringe behind a translucent glyph is cosmetic, and a
    /// genuinely blank crop falls back to the app icon upstream.
    private func captureFullDisplay(_ display: SCDisplay, _ displayBounds: CGRect) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false
        // `display.width/height` are in POINTS. Scale to native pixels using the matching
        // screen's backing scale, found by displayID (no coordinate-space mixing).
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }?.backingScaleFactor ?? 2
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        DebugLog.log("capture: full display \(config.width)x\(config.height) px (scale \(scale))")
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The shareable display whose bounds contain the probe point (the menu bar lives on the
    /// display the items belong to, which may not be the first one on a multi-display rig).
    private func displayContaining(_ point: CGPoint?, in displays: [SCDisplay]) -> SCDisplay? {
        guard let point else { return nil }
        return displays.first { CGDisplayBounds($0.displayID).contains(point) }
    }

    /// Writes a raw (un-keyed) crop to ~/Library/Logs for pixel inspection during development,
    /// plus a row-by-row RGB profile of the center column so the keying thresholds can be tuned
    /// against real data instead of guesses. Gated behind BKF_DUMP_CROPS.
    private func dumpRawCrop(_ image: CGImage, windowID: CGWindowID) {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: logs.appendingPathComponent("BKF-crop-\(windowID).png"))
        }
        // Sample mean RGB of edge rows vs center region so we can see what's actually there.
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func meanRow(_ y: Int) -> String {
            var r = 0, g = 0, b = 0
            for x in 0..<w { let p = (y * w + x) * 4; r += Int(px[p]); g += Int(px[p+1]); b += Int(px[p+2]) }
            return "(\(r/w),\(g/w),\(b/w))"
        }
        DebugLog.log("crop \(windowID) \(w)x\(h): row0=\(meanRow(0)) rowMid=\(meanRow(h/2)) rowLast=\(meanRow(h-1))")
    }

    // MARK: - Background keying

    /// Removes the wallpaper background from a status-item crop and trims to the glyph, leaving
    /// a tight, opaque glyph on transparency that drops cleanly into the floating bar.
    ///
    /// The crop is an opaque tile: menu-bar-tinted wallpaper with the glyph composited on top.
    /// Keying on color *distance* from an estimated background fails on a textured wallpaper —
    /// the texture survives and a near-white glyph can read as "close" to a bright patch. So we
    /// key on what actually separates a menu bar glyph from any wallpaper, then trim:
    ///
    ///   1. **Luminance.** Monochrome template glyphs are near-white (luma ≳ 220); even bright
    ///      grass or sky tops out far lower (≲ 115, measured). A luma ramp keeps the glyph and
    ///      drops the wallpaper regardless of its color or texture.
    ///   2. **Saturated, off-background, clustered hue.** A colored badge (e.g. the yellow ACME
    ///      icon) is darker than white but vividly saturated and unlike the wallpaper. Requiring
    ///      a horizontal cluster (not a lone pixel) rejects sparse saturated wallpaper speckle.
    ///   3. **Trim + boost.** The glyph fills only the center of its padded crop, so we trim to
    ///      its bounding box (computed from the robust luma mask + clustered color mask) — this
    ///      is what makes it fill the 18pt icon instead of floating tiny and faint — and boost
    ///      alpha so thin strokes survive downsampling.
    ///
    /// Principled rather than tuned-to-one-wallpaper: a glyph the user sees in the menu bar must
    /// contrast with it by design. If a crop keys to nothing, the caller's `isBlank` check falls
    /// back to the app icon. Verified offline against real Tahoe crops (white mic/hammer/cloud
    /// glyphs and the colored ACME badge over a grass wallpaper).
    private func removingBackground(from image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return nil }

        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Background color estimate (for the colored-badge term): mean RGB of the edge rows. A
        // status item is vertically centered with padding, so the edge rows are wallpaper.
        let band = max(2, h / 12)
        var sr = 0, sg = 0, sb = 0, n = 0
        for row in 0..<band {
            let mirrored = h - 1 - row
            // Skip the mirrored bottom row when it coincides with (or falls inside) the top
            // band — otherwise a center row is summed twice and skews the estimate. Only the
            // degenerate h==3 crop hits this, but the guard is cheap and exact.
            let edges = mirrored > row ? [row, mirrored] : [row]
            for edge in edges {
                let base = edge * w * 4
                for col in 0..<w {
                    let p = base + col * 4
                    sr += Int(px[p]); sg += Int(px[p + 1]); sb += Int(px[p + 2]); n += 1
                }
            }
        }
        guard n > 0 else { return nil }
        let bgR = sr / n, bgG = sg / n, bgB = sb / n

        func luma(_ p: Int) -> Double {
            0.299 * Double(px[p]) + 0.587 * Double(px[p + 1]) + 0.114 * Double(px[p + 2])
        }
        // Strong colored-badge test (saturated + far from wallpaper hue), used both to extend
        // the bbox and in the alpha mask.
        func colorAlpha(_ p: Int) -> Double {
            let r = Int(px[p]), g = Int(px[p + 1]), b = Int(px[p + 2])
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            let sat = mx > 0 ? Double(mx - mn) / Double(mx) : 0
            let dr = Double(r - bgR), dg = Double(g - bgG), db = Double(b - bgB)
            let dist = (dr * dr + dg * dg + db * db).squareRoot()
            return (sat > 0.55 && dist > 110) ? max(0, min(1, (dist - 110) / 50)) : 0
        }

        // Bounding box from the glyph body: luma well above the wallpaper ceiling, plus any
        // CLUSTERED colored-badge pixels (a lone saturated speckle is ignored).
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                var isGlyph = luma(p) > 180
                if !isGlyph, x > 0, x < w - 1 {
                    isGlyph = colorAlpha(p) > 0.5 && colorAlpha(p - 4) > 0.5 && colorAlpha(p + 4) > 0.5
                }
                if isGlyph {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 2
        minX = max(0, minX - pad); minY = max(0, minY - pad)
        maxX = min(w - 1, maxX + pad); maxY = min(h - 1, maxY + pad)

        // Build the keyed alpha over the whole buffer (cheap), then crop to the bbox.
        let lumaLo = 150.0, lumaHi = 205.0
        for y in 0..<h {
            let base = y * w * 4
            for x in 0..<w {
                let p = base + x * 4
                let r = Int(px[p]), g = Int(px[p + 1]), b = Int(px[p + 2])
                let aLuma = max(0, min(1, (luma(p) - lumaLo) / (lumaHi - lumaLo)))
                // Boost so thin anti-aliased strokes stay solid through the downscale to 18pt.
                let a = UInt8(min(1, max(aLuma, colorAlpha(p)) * 1.4) * 255)
                px[p] = UInt8(r * Int(a) / 255)
                px[p + 1] = UInt8(g * Int(a) / 255)
                px[p + 2] = UInt8(b * Int(a) / 255)
                px[p + 3] = a
            }
        }
        return ctx.makeImage()?.cropping(to: CGRect(
            x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
        ))
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

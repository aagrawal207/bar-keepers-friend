import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Regenerate the app icon (the source of truth for Assets.xcassets/AppIcon.appiconset):
//
//   swift Scripts/render_icon.swift /tmp/icons
//   # then copy the px renditions into the appiconset slots:
//   #   icon_16   -> icon_16x16.png
//   #   icon_32   -> icon_16x16@2x.png, icon_32x32.png
//   #   icon_64   -> icon_32x32@2x.png
//   #   icon_128  -> icon_128x128.png
//   #   icon_256  -> icon_128x128@2x.png, icon_256x256.png
//   #   icon_512  -> icon_256x256@2x.png, icon_512x512.png
//   #   icon_1024 -> icon_512x512@2x.png
//   # then `xcodegen generate`, rebuild.
//
// Renders the Bar Keeper's Friend app icon — "Sparkle Clean".
// Concept: lean into the cleaning-product pun. A big, bold four-point "shine"
// sparkle is the hero — a freshly cleaned, well-kept bar — sitting over one short
// white pill (the menu bar) that grounds the mark in "menu bar manager". Cool
// fresh teal→blue squircle, crisp white knockout. Few elements, lots of negative
// space, so it stays legible at 16/32px (where a menu-bar app is seen most).

func srgb() -> CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: srgb(), components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

// A continuous-corner-ish rounded rect (plain rounded rect is fine at icon scale).
func roundedRectPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// A four-point "sparkle"/shine star with concave sides (the classic clean-shine
// glyph). `r` is the tip radius; `waistFactor` controls how pinched the sides are
// (smaller waist = sharper, more dramatic points).
func sparklePath(center c: CGPoint, r: CGFloat, waistFactor: CGFloat = 0.18) -> CGPath {
    let waist = r * waistFactor
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + waist, y: c.y + waist))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + waist, y: c.y - waist))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - waist, y: c.y - waist))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - waist, y: c.y + waist))
    p.closeSubpath()
    return p
}

func drawIcon(size S: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // --- macOS Big Sur+ icon grid: rounded square inset with transparent margin + soft shadow.
    let margin = S * 0.0977                       // ≈100/1024
    let body = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let bodyRadius = body.width * 0.2237          // ≈185/824
    let bodyPath = roundedRectPath(body, bodyRadius)

    // Soft drop shadow under the squircle.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                  blur: S * 0.03, color: color(0, 0, 0, 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0, 0, 0, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // --- Background gradient: fresh teal at top → confident blue at bottom.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: srgb(),
        colors: [color(0.22, 0.86, 0.80), color(0.07, 0.46, 0.90)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY), options: [])

    // Subtle top sheen for depth.
    let sheen = CGGradient(colorsSpace: srgb(),
        colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY + body.height * 0.12), options: [])
    ctx.restoreGState()

    // ---- The mark. White knockout: a single hero sparkle over one short
    // menu-bar pill. Two bold elements only, with a clear gap between them so
    // both stay distinct all the way down to 16px. (A companion mini-sparkle
    // was tried but turned to noise at 32/16px — dropped for legibility.)
    let white = color(1, 1, 1, 1)

    // Hero sparkle — the whole point of the icon. Centered, big, sitting in the
    // upper-middle so there's room for the pill below.
    let heroR = body.width * 0.305
    let heroC = CGPoint(x: body.midX, y: body.minY + body.height * 0.605)
    ctx.addPath(sparklePath(center: heroC, r: heroR, waistFactor: 0.18))
    ctx.setFillColor(white)
    ctx.fillPath()

    // The menu-bar pill underneath — short, centered, rounded. Grounds the mark
    // in "menu bar". Solid white, generous height so it never reads as a
    // hairline. Sits low with a clear gap below the sparkle's bottom tip so the
    // two never merge.
    let pillW = body.width * 0.52
    let pillH = body.height * 0.125
    let pill = CGRect(x: body.midX - pillW / 2,
                      y: body.minY + body.height * 0.12,
                      width: pillW, height: pillH)
    ctx.addPath(roundedRectPath(pill, pillH / 2))
    ctx.setFillColor(white)
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]
for px in sizes {
    let img = drawIcon(size: CGFloat(px))
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(px).png")
    writePNG(img, to: url)
    print("wrote \(url.lastPathComponent)")
}

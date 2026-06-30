import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Regenerate the app icon (the source of truth for Assets.xcassets/AppIcon.appiconset):
//
//   swift Scripts/render_icon.swift /tmp/icons
//   # then copy the px renditions into the appiconset (the 16/32/64/128/256/512/1024
//   # outputs map to the @1x/@2x slots — see the icon commit), `xcodegen generate`, rebuild.
//
// Renders the Bar Keeper's Friend app icon at a given pixel size.
// Concept: a tidy menu bar — a white pill "menu bar" with a few icon dots, a left
// "tuck" chevron (BKF's own hide control), and a small sparkle (the cleaning-product
// pun: a clean, kept bar) — on a fresh teal→blue squircle.

func srgb() -> CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: srgb(), components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

// A continuous-corner-ish rounded rect (plain rounded rect is fine at icon scale).
func roundedRectPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
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

    // --- Background gradient (fresh teal at top → confident blue at bottom).
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: srgb(),
        colors: [color(0.20, 0.84, 0.78), color(0.09, 0.49, 0.88)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY), options: [])

    // Subtle top sheen for depth.
    let sheen = CGGradient(colorsSpace: srgb(),
        colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY + body.height * 0.12), options: [])
    ctx.restoreGState()

    // ---- The menu-bar motif. Coordinates are in "body" space, y measured from the
    // body's top so the mark sits in the upper-middle and reads at small sizes.
    let blue = color(0.10, 0.46, 0.82)            // knockout color for glyphs on the white bar

    // White menu-bar pill.
    let barH = body.height * 0.165
    let barInsetX = body.width * 0.135
    let barY = body.maxY - body.height * 0.40 - barH   // upper-middle
    let bar = CGRect(x: body.minX + barInsetX, y: barY,
                     width: body.width - 2 * barInsetX, height: barH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.004), blur: S * 0.012, color: color(0, 0, 0, 0.18))
    ctx.addPath(roundedRectPath(bar, barH / 2))
    ctx.setFillColor(color(1, 1, 1, 0.97))
    ctx.fillPath()
    ctx.restoreGState()

    // Icon dots inside the bar (3 small rounded squares), right-aligned — the "kept" items.
    let dot = barH * 0.42
    let gap = dot * 0.95
    let dotY = bar.midY - dot / 2
    var dx = bar.maxX - barH * 0.55 - dot
    for _ in 0..<3 {
        ctx.addPath(roundedRectPath(CGRect(x: dx, y: dotY, width: dot, height: dot), dot * 0.28))
        ctx.setFillColor(blue)
        ctx.fillPath()
        dx -= (dot + gap)
    }

    // Left "tuck" chevron — BKF's hide control, pointing left (items tucked away).
    let chevX = bar.minX + barH * 0.62
    let chevHalf = barH * 0.22
    let chevW = barH * 0.26
    ctx.saveGState()
    ctx.setLineWidth(max(1, barH * 0.13))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(blue)
    ctx.move(to: CGPoint(x: chevX + chevW, y: bar.midY + chevHalf))
    ctx.addLine(to: CGPoint(x: chevX, y: bar.midY))
    ctx.addLine(to: CGPoint(x: chevX + chevW, y: bar.midY - chevHalf))
    ctx.strokePath()
    ctx.restoreGState()

    // Sparkle below the bar — the "clean" nod. A four-point star.
    func sparkle(center c: CGPoint, r: CGFloat, alpha: CGFloat) {
        let waist = r * 0.30
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + waist, y: c.y + waist))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + waist, y: c.y - waist))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - waist, y: c.y - waist))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - waist, y: c.y + waist))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(color(1, 1, 1, Double(alpha)))
        ctx.fillPath()
    }
    let sBig = body.width * 0.085
    sparkle(center: CGPoint(x: body.midX + body.width * 0.205, y: bar.minY - body.height * 0.155),
            r: sBig, alpha: 0.96)
    sparkle(center: CGPoint(x: body.midX + body.width * 0.07, y: bar.minY - body.height * 0.255),
            r: sBig * 0.5, alpha: 0.80)

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

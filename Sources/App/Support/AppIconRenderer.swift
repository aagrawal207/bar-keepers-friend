import AppKit
import BarKeepersFriendCore

/// Draws BKF's own artwork from an `AppIconChoice`, so the anchor, Settings header, About panel,
/// alerts, and Settings previews all agree. The installed bundle icon is never touched.
enum AppIconRenderer {
    static let accessibilityDescription = "Bar Keeper's Friend"

    /// Template image for the anchor status item. Falls back to the default symbol, then to a
    /// drawn placeholder, so an unavailable symbol can never leave the anchor without artwork.
    static func menuBarImage(_ symbol: AppIconChoice.MenuBarSymbol) -> NSImage {
        let image = NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: accessibilityDescription)
            ?? NSImage(systemSymbolName: AppIconChoice.MenuBarSymbol.lines.systemName, accessibilityDescription: accessibilityDescription)
            ?? placeholderMenuBarImage()
        image.isTemplate = true
        return image
    }

    /// Whether the running OS ships the symbol. macOS 26 ships every case; the parameterized
    /// workflow test is the guard, so a future rename fails a test rather than a user's menu bar.
    static func isMenuBarSymbolAvailable(_ symbol: AppIconChoice.MenuBarSymbol) -> Bool {
        NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: nil) != nil
    }

    private static func placeholderMenuBarImage() -> NSImage {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 6), xRadius: 3, yRadius: 3).fill()
            return true
        }
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// The bundled Ocean artwork is the signed default; every other theme is drawn at runtime with
    /// the same mark (sparkle over a menu-bar pill) on a different gradient. The fallback must never
    /// read `NSApp.applicationIconImage`: this feature sets it, so Ocean would echo the current theme.
    static func appImage(_ theme: AppIconChoice.AppTheme, size: CGFloat = 512) -> NSImage {
        if theme == .ocean, let bundled = NSImage(named: "AppIcon") {
            return bundled
        }
        let image = NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(theme: theme, in: rect, context: context)
            return true
        }
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    /// Mirrors `Scripts/render_icon.swift` so runtime themes match the bundled icon's geometry.
    static func draw(theme: AppIconChoice.AppTheme, in rect: CGRect, context: CGContext) {
        let side = min(rect.width, rect.height)
        let margin = side * 0.0977
        let body = CGRect(x: rect.minX + margin, y: rect.minY + margin, width: side - 2 * margin, height: side - 2 * margin)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: body.width * 0.2237, cornerHeight: body.width * 0.2237, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                          color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(bodyPath)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(bodyPath)
        context.clip()
        let stops = theme.gradient
        let colors = [cgColor(stops.top), cgColor(stops.bottom)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY),
                                       end: CGPoint(x: body.midX, y: body.minY), options: [])
        }
        let sheenColors = [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray
        if let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: sheenColors, locations: [0, 1]) {
            context.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                                       end: CGPoint(x: body.midX, y: body.midY + body.height * 0.12), options: [])
        }
        context.restoreGState()

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(sparklePath(center: CGPoint(x: body.midX, y: body.minY + body.height * 0.605), radius: body.width * 0.305))
        context.fillPath()
        let pillWidth = body.width * 0.52
        let pillHeight = body.height * 0.125
        let pill = CGRect(x: body.midX - pillWidth / 2, y: body.minY + body.height * 0.12, width: pillWidth, height: pillHeight)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: pillHeight / 2, cornerHeight: pillHeight / 2, transform: nil))
        context.fillPath()
    }

    private static func sparklePath(center c: CGPoint, radius r: CGFloat) -> CGPath {
        let waist = r * 0.18
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: c.y + r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + waist, y: c.y + waist))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + waist, y: c.y - waist))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - waist, y: c.y - waist))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - waist, y: c.y + waist))
        path.closeSubpath()
        return path
    }

    private static func cgColor(_ color: RGBA) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

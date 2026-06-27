import AppKit

/// Supplies a real application icon for a menu bar item, looked up from the running app by its
/// (attributed) process id.
///
/// This replaces screenshot-cropping the menu bar glyph, which on the translucent Tahoe menu
/// bar is unreliable (wallpaper bleeds through, or the glyph composites to nothing and the
/// crop comes back fully transparent). The app's own icon is always available, needs no Screen
/// Recording permission, and is recognizable. It is the app's bundle icon, which can differ
/// from the monochrome menu bar glyph, but it reliably identifies the owner.
enum AppIconProvider {

    /// The running app's icon for `pid`, or a generic fallback if the app or icon is missing.
    static func icon(forPID pid: pid_t) -> NSImage {
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        return genericIcon
    }

    /// A neutral placeholder for items whose owning app can't be resolved.
    private static let genericIcon: NSImage = {
        let image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Menu bar item")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()
}

import AppKit
import BarKeepersFriendCore

/// A hidden menu bar item paired with its captured icon image, ready to render in the
/// floating bar. `Identifiable` by window id so SwiftUI can diff the list efficiently.
struct FloatingBarItem: Identifiable {
    let snapshot: MenuBarItemSnapshot
    let image: NSImage
    /// True when the last activation attempt failed via both AX and synthesized click, so the
    /// row is shown dimmed and non-interactive instead of looking clickable but doing nothing.
    var isDisabled: Bool = false
    /// The user's custom alias for this item, if any. Takes precedence over the attributed name
    /// so a user-chosen nickname is what they see and search by.
    var alias: String? = nil

    var id: CGWindowID { snapshot.windowID }

    /// A human-readable label for the vertical list. Prefers the user's alias, then the
    /// Accessibility-attributed name: either the owning app ("Maccy") or, for Control Center
    /// modules, the module's own title ("Wi-Fi", "Battery"), which attribution resolves — so
    /// "Control Center" is trusted here rather than discarded. The window title is unreliable on
    /// Tahoe (generic "Item-0"), so it's only a fallback when attribution found nothing.
    var displayName: String {
        if let alias, !alias.isEmpty {
            return alias
        }
        if let owner = snapshot.ownerBundleID, !owner.isEmpty {
            return owner
        }
        if let title = snapshot.title, !title.isEmpty, !title.hasPrefix("Item-") {
            return title
        }
        return "Menu Bar Item"
    }
}

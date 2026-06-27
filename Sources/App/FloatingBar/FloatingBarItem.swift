import AppKit
import BarKeepersFriendCore

/// A hidden menu bar item paired with its captured icon image, ready to render in the
/// floating bar. `Identifiable` by window id so SwiftUI can diff the list efficiently.
struct FloatingBarItem: Identifiable {
    let snapshot: MenuBarItemSnapshot
    let image: NSImage

    var id: CGWindowID { snapshot.windowID }

    /// A human-readable label for the vertical list. Prefers the Accessibility-attributed
    /// name: either the owning app ("Maccy") or, for Control Center modules, the module's own
    /// title ("Wi-Fi", "Battery"), which attribution now resolves — so "Control Center" is
    /// trusted here rather than discarded. The window title is unreliable on Tahoe (generic
    /// "Item-0"), so it's only a fallback when attribution found nothing.
    var displayName: String {
        if let owner = snapshot.ownerBundleID, !owner.isEmpty {
            return owner
        }
        if let title = snapshot.title, !title.isEmpty, !title.hasPrefix("Item-") {
            return title
        }
        return "Menu Bar Item"
    }
}

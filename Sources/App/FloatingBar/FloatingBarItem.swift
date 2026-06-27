import AppKit
import BarKeepersFriendCore

/// A hidden menu bar item paired with its captured icon image, ready to render in the
/// floating bar. `Identifiable` by window id so SwiftUI can diff the list efficiently.
struct FloatingBarItem: Identifiable {
    let snapshot: MenuBarItemSnapshot
    let image: NSImage

    var id: CGWindowID { snapshot.windowID }

    /// A human-readable label for the vertical list. Prefers the Accessibility-attributed
    /// owner name (a real app name); the window title is unreliable on Tahoe (generic
    /// "Item-0"), so it's only used if it isn't that placeholder.
    var displayName: String {
        if let owner = snapshot.ownerBundleID, !owner.isEmpty, owner != "Control Center" {
            return owner
        }
        if let title = snapshot.title, !title.isEmpty, !title.hasPrefix("Item-") {
            return title
        }
        return "Menu Bar Item"
    }
}

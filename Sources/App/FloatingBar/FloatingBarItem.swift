import AppKit
import BarKeepersFriendCore

/// A hidden menu bar item paired with its captured icon image, ready to render in the
/// floating bar. `Identifiable` by window id so SwiftUI can diff the list efficiently.
struct FloatingBarItem: Identifiable {
    let snapshot: MenuBarItemSnapshot
    let image: NSImage

    var id: CGWindowID { snapshot.windowID }

    /// A human-readable label for the vertical list. Falls back through the title, owner
    /// name, then a generic placeholder.
    var displayName: String {
        if let title = snapshot.title, !title.isEmpty { return title }
        if let owner = snapshot.ownerBundleID, !owner.isEmpty { return owner }
        return "Menu Bar Item"
    }
}

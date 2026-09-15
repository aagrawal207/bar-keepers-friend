import Foundation
import BarKeepersFriendCore

/// A structured, read-only snapshot of the floating bar's current understanding of the hidden
/// menu bar items: what was enumerated, how each was attributed, and the full Accessibility
/// element behind it. Written to `~/Library/Logs/BKF-diag.json` on demand (SIGUSR1) so the
/// exact state can be inspected without guessing from the running UI.
struct DiagnosticsReport: Codable, Sendable {
    var generatedAt: String
    var anchorMinX: Double
    /// "visible", "hidden" (fullscreen Space or auto-hide), or "unknown" (no anchor found).
    var menuBarVisibility: String = "unknown"
    var items: [Item]

    struct Item: Codable, Sendable {
        var windowID: UInt32
        var displayName: String
        var attributedOwner: String?
        var ownerPID: Int32
        var rawTitle: String?
        var frame: [Double]            // [x, y, w, h]
        var isOnScreen: Bool
        /// Whether the cache holds a captured glyph rather than an app-icon fallback.
        var hasGlyph: Bool
        var isDisabled: Bool
        var axElement: AXInspector.ElementInfo?
    }

    /// Writes the report as pretty JSON to `~/Library/Logs/BKF-diag.json`.
    func write() {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("BKF-diag.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url)
            DebugLog.log("diagnostics: wrote report with \(items.count) items to \(url.path)")
        }
    }
}

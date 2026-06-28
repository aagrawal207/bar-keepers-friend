import AppKit
import BarKeepersFriendCore
import UniformTypeIdentifiers

/// Bridges `LayoutConfig` export/import to the AppKit save/open panels. The serialization logic
/// lives in Core (`LayoutConfig`, unit-tested); this is the thin UI-facing wrapper.
///
/// AGENT: implement the two methods using NSSavePanel/NSOpenPanel. The public surface below is
/// fixed — Settings calls `exportLayout(_:)` and `importLayout()`. Do not change the signatures.
@MainActor
enum LayoutTransferService {
    /// Presents a save panel and writes the given preferences as a `LayoutConfig` JSON file.
    /// No-op if the user cancels. Returns the written URL on success, nil otherwise.
    @discardableResult
    static func exportLayout(_ preferences: Preferences) -> URL? {
        // AGENT: NSSavePanel with allowedContentTypes [.json], default name
        // "BarKeepersFriend-Layout.json"; on OK, write LayoutConfig(preferences:).encoded().
        nil
    }

    /// Presents an open panel, reads + decodes a `LayoutConfig`, and returns the imported
    /// preferences. Returns nil if the user cancels; throws `LayoutConfigError` on a bad file so
    /// the caller can surface an alert.
    static func importLayout() throws -> Preferences? {
        // AGENT: NSOpenPanel limited to .json; on OK, read Data, LayoutConfig.decode(from:),
        // return .preferences. Let LayoutConfigError propagate.
        nil
    }
}

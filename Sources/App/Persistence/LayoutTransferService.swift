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
    ///
    /// We `activate(ignoringOtherApps:)` first because this is an accessory (LSUIElement) app:
    /// without a regular Dock presence the panel can open behind the frontmost app — or never
    /// take focus — leaving the user staring at a dialog they can't see. Encoding goes through
    /// `LayoutConfig` so the on-disk shape (and its version stamp) stays identical to what
    /// `importLayout()` expects, and the write is atomic so a crash mid-write can't leave a
    /// half-written file the user would later fail to import.
    @discardableResult
    static func exportLayout(_ preferences: Preferences) -> URL? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BarKeepersFriend-Layout.json"
        panel.title = "Export Layout"
        panel.message = "Save your Bar Keeper's Friend settings and item positions to a JSON file."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let data = try LayoutConfig(preferences: preferences).encoded()
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            // Returning nil (rather than throwing) keeps export best-effort: the caller treats a
            // nil result as "nothing was written". We still log the underlying cause so a failed
            // export isn't silent when diagnosing from the log file.
            DebugLog.log("Layout export failed: \(error)")
            return nil
        }
    }

    /// Presents an open panel, reads + decodes a `LayoutConfig`, and returns the imported
    /// preferences. Returns nil if the user cancels; throws `LayoutConfigError` on a bad file so
    /// the caller can surface an alert.
    ///
    /// We collapse a file *read* error into `LayoutConfigError.malformed` so the caller only ever
    /// has to handle one error type: from the user's point of view "couldn't read it" and
    /// "couldn't parse it" are the same failure — the file is unusable. `LayoutConfig.decode`
    /// already throws `LayoutConfigError` for parse / version problems, so those propagate as-is.
    static func importLayout() throws -> Preferences? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Layout"
        panel.message = "Choose a Bar Keeper's Friend layout file to import."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // Check the file size BEFORE reading it whole — a layout file is a few KB, so a huge
        // file is either not ours or chosen to exhaust memory. `decode` re-checks the in-memory
        // size as a backstop, but this avoids reading a multi-GB file into memory at all.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > LayoutConfig.maxEncodedSize {
            DebugLog.log("Layout import rejected: file is \(size) bytes (> \(LayoutConfig.maxEncodedSize))")
            throw LayoutConfigError.tooLarge(size)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            DebugLog.log("Layout import read failed: \(error)")
            throw LayoutConfigError.malformed
        }

        return try LayoutConfig.decode(from: data).preferences
    }
}

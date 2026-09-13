import AppKit
import BarKeepersFriendCore
import UniformTypeIdentifiers

/// Bridges `LayoutConfig` export/import to the AppKit save/open panels. The serialization logic
/// lives in Core (`LayoutConfig`, unit-tested); this is the thin UI-facing wrapper.
@MainActor
enum LayoutTransferService {
    /// A cancel is not news, but a failed write is; the caller renders them differently.
    enum ExportOutcome: Equatable, Sendable {
        case saved(URL)
        case cancelled
        /// The user-facing reason for the failure.
        case failed(String)
    }

    /// Writes atomically so a crash mid-write cannot leave a half-written file; `destination` and
    /// `write` are injectable so tests can drive a cancel or a failed write without a dialog.
    static func exportLayout(
        _ preferences: Preferences,
        destination: @MainActor () -> URL? = { presentExportPanel() },
        write: @MainActor (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) -> ExportOutcome {
        guard let url = destination() else { return .cancelled }

        do {
            let data = try LayoutConfig(preferences: preferences).encoded()
            try write(data, url)
            return .saved(url)
        } catch {
            DebugLog.log("Layout export failed: \(error)")
            return .failed(error.localizedDescription)
        }
    }

    /// An accessory (LSUIElement) app has no Dock presence, so without activating first the panel
    /// can open behind the frontmost app or never take focus.
    private static func presentExportPanel() -> URL? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BarKeepersFriend-Layout.json"
        panel.title = "Export Layout"
        panel.message = "Save your Bar Keeper's Friend settings and item positions to a JSON file."

        guard panel.runModal() == .OK else { return nil }
        return panel.url
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

import AppKit
import BarKeepersFriendCore
import CryptoKit

/// Last captured glyph per owner, kept across launches so a relaunch, a fullscreen Space, or a
/// cold compositor shows the real monochrome glyph instead of the owning app's icon until the
/// next capture replaces it. Purely a cache: the Caches directory may be emptied at any time and
/// a missing or unreadable file only means the fallback is used.
///
/// Keys are attribution labels (`ItemControlStore.key(for:)`), the same identity Hidden/Shown
/// intent uses, so an app keeps its glyph across window-id churn. Unresolved owners are never
/// stored: their label is Tahoe's blanket "Control Center" and would conflate every such item.
@MainActor
final class GlyphStore {
    private let directory: URL
    private var written: [String: Data] = [:]
    private var loaded: [String: NSImage?] = [:]

    static let `default` = GlyphStore(directory: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BarKeepersFriend", isDirectory: true)
        .appendingPathComponent("glyphs", isDirectory: true))

    init(directory: URL) {
        self.directory = directory
    }

    /// The stored glyph for `key`, or nil when none was ever captured or the file is unreadable.
    func image(for key: String) -> NSImage? {
        if let cached = loaded[key] { return cached }
        let image = (try? Data(contentsOf: url(for: key))).flatMap { data -> NSImage? in
            guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
            let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
            image.addRepresentation(rep)
            return image
        }
        loaded[key] = .some(image)
        return image
    }

    /// Writes a captured glyph; identical bytes are not rewritten within a session.
    func store(_ image: NSImage, for key: String) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
              written[key] != data else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: key), options: .atomic)
            written[key] = data
            loaded[key] = .some(image)
        } catch {
            DebugLog.log("glyphstore: could not write glyph for \(key): \(error.localizedDescription)")
        }
    }

    /// Labels can hold any character an app puts in its name, so the file name is a digest.
    private func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).png")
    }
}

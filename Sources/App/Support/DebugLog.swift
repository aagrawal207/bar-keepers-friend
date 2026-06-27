import Foundation

/// Minimal append-only file logger for diagnosing runtime behavior during development.
///
/// Writes to `~/Library/Logs/BarKeepersFriend.log`, a standard user-readable location that
/// needs no special permission. Useful when the app is launched outside Xcode (or when the
/// console is awkward to read), since the log can be inspected directly from a terminal.
enum DebugLog {
    private static let url: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return logs.appendingPathComponent("BarKeepersFriend.log")
    }()

    private static let queue = DispatchQueue(label: "com.agraabhi.BarKeepersFriend.debuglog")

    static func log(_ message: String) {
        // Mirror to the console too.
        NSLog("BKF: \(message)")
        queue.async {
            let line = "\(Self.timestamp())  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

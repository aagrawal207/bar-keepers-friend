import Foundation

/// Relaunches the app through a detached shell that waits for this process to exit before
/// reopening the bundle, so the new copy never meets the old one in the single-instance guard.
@MainActor
final class RestartService {
    typealias Launch = ([String]) throws -> Void

    /// Polling interval and ceiling for the old process to disappear; the helper gives up rather
    /// than start a duplicate if this process refuses to terminate.
    static let pollInterval = "0.1"
    static let maxPolls = 600

    /// LaunchServices can still list the exited copy for a moment; the guard would quit the new one.
    static let launchServicesSettle = "0.5"

    private let launch: Launch

    init(launch: @escaping Launch = RestartService.spawnDetached) {
        self.launch = launch
    }

    /// argv for `Process`: `/bin/sh -c <script>`. Pure so the script is unit-tested without spawning.
    static func command(bundlePath: String, pid: pid_t) -> [String] {
        let script = "n=0; "
            + "while kill -0 \(pid) 2>/dev/null; do "
            + "n=$((n+1)); [ \"$n\" -ge \(maxPolls) ] && exit 1; sleep \(pollInterval); "
            + "done; "
            + "sleep \(launchServicesSettle); "
            + "exec /usr/bin/open \(shellQuoted(bundlePath))"
        return ["/bin/sh", "-c", script]
    }

    /// POSIX single quoting: nothing is special inside except `'`, which becomes `'\''`.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Starts the relaunch helper. Returns false when it could not start, in which case the caller
    /// must not terminate: quitting without a helper would just leave the app closed.
    @discardableResult
    func restart(bundleURL: URL = Bundle.main.bundleURL, pid: pid_t = getpid()) -> Bool {
        let argv = Self.command(bundlePath: bundleURL.path, pid: pid)
        do {
            try launch(argv)
            DebugLog.log("Restart: relaunch helper started for pid \(pid), bundle \(bundleURL.path)")
            return true
        } catch {
            DebugLog.log("Restart: relaunch helper failed to start: \(error)")
            return false
        }
    }

    /// The child shares no stdio with us and outlives our `exit()`: a GUI app's children are
    /// simply reparented to launchd, so no setsid or double fork is needed.
    private nonisolated static func spawnDetached(_ argv: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

import AppKit
import BarKeepersFriendCore

/// Why a widget's action did not run, worded for a tooltip.
enum WidgetActionError: Error, Equatable, Sendable {
    case invalidAction(WidgetLibrary.ValidationProblem)
    case openURLFailed(URL)
    case appNotFound(bundleIdentifier: String)
    case shortcutsUnavailable
    case shortcutFailed(name: String, reason: String)

    var message: String {
        switch self {
        case let .invalidAction(problem):
            return "This widget's action is not allowed. \(problem.message)"
        case let .openURLFailed(url):
            return "\(url.absoluteString) could not be opened."
        case let .appNotFound(bundleIdentifier):
            return "No installed app has the identifier \(bundleIdentifier)."
        case .shortcutsUnavailable:
            return "The Shortcuts command line tool is not available on this Mac."
        case let .shortcutFailed(name, reason):
            return "The Shortcut \"\(name)\" could not be started. \(reason)"
        }
    }
}

/// Runs widget actions through injected seams. Actions are user-authored data, so the surface stays
/// fixed (allowlisted URL, app by bundle id, `shortcuts run` argv, own toggle) and is re-validated here.
@MainActor
final class WidgetActionRunner {
    typealias OpenURL = @MainActor (URL) -> Bool
    typealias LaunchApp = @MainActor (String) -> Bool
    typealias RunShortcut = @MainActor (String) throws -> Void
    typealias ToggleBar = @MainActor () -> Void

    nonisolated static let shortcutsExecutable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    private let openURL: OpenURL
    private let launchApp: LaunchApp
    private let runShortcut: RunShortcut
    private let toggleBar: ToggleBar

    init(
        openURL: @escaping OpenURL = WidgetActionRunner.systemOpenURL,
        launchApp: @escaping LaunchApp = WidgetActionRunner.systemLaunchApp,
        runShortcut: @escaping RunShortcut = WidgetActionRunner.systemRunShortcut,
        toggleBar: @escaping ToggleBar
    ) {
        self.openURL = openURL
        self.launchApp = launchApp
        self.runShortcut = runShortcut
        self.toggleBar = toggleBar
    }

    /// Refuses an invalid action before touching any seam; failures are logged and returned, never thrown.
    @discardableResult
    func run(_ action: WidgetAction) -> Result<Void, WidgetActionError> {
        if let problem = WidgetLibrary.validate(action) {
            return failing(.invalidAction(problem), action: action)
        }
        switch action {
        case let .openURL(url):
            return openURL(url) ? .success(()) : failing(.openURLFailed(url), action: action)
        case let .launchApp(bundleIdentifier):
            let identifier = WidgetLibrary.trimmed(bundleIdentifier)
            return launchApp(identifier) ? .success(()) : failing(.appNotFound(bundleIdentifier: identifier), action: action)
        case let .runShortcut(name):
            let trimmed = WidgetLibrary.trimmed(name)
            do {
                try runShortcut(trimmed)
                return .success(())
            } catch let error as WidgetActionError {
                return failing(error, action: action)
            } catch {
                return failing(.shortcutFailed(name: trimmed, reason: error.localizedDescription), action: action)
            }
        case .toggleBar:
            toggleBar()
            return .success(())
        }
    }

    private func failing(_ error: WidgetActionError, action: WidgetAction) -> Result<Void, WidgetActionError> {
        DebugLog.log("Widget action failed (\(WidgetLibrary.displayText(for: action))): \(error.message)")
        return .failure(error)
    }

    // MARK: - System seams

    static func systemOpenURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// False only when no app carries the identifier; the launch itself completes asynchronously.
    static func systemLaunchApp(_ bundleIdentifier: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                DebugLog.log("Widget launch of \(bundleIdentifier) failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// argv for `Process`; pure so tests can pin the exact command without spawning anything.
    /// `--` keeps a name beginning with "-" from being parsed as an option.
    nonisolated static func shortcutsCommand(name: String) -> [String] {
        [shortcutsExecutable.path, "run", "--", name]
    }

    /// Starts `shortcuts run <name>` detached: a Shortcut may run for a long time, and the click
    /// handler must not block the main thread waiting for it.
    static func systemRunShortcut(_ name: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shortcutsExecutable.path) else {
            throw WidgetActionError.shortcutsUnavailable
        }
        let argv = shortcutsCommand(name: name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 {
                DebugLog.log("Widget Shortcut \"\(name)\" exited with status \(finished.terminationStatus)")
            }
        }
        do {
            try process.run()
        } catch {
            throw WidgetActionError.shortcutFailed(name: name, reason: error.localizedDescription)
        }
    }
}

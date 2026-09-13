import AppKit
import BarKeepersFriendCore
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct WidgetActionRunnerTests {

    /// Records every seam call; nothing here opens URLs, launches apps, or spawns processes.
    @MainActor
    final class Seams {
        var openedURLs: [URL] = []
        var launched: [String] = []
        var shortcuts: [String] = []
        var toggles = 0
        var openResult = true
        var launchResult = true
        var shortcutError: (any Error)?

        func makeRunner() -> WidgetActionRunner {
            WidgetActionRunner(
                openURL: { [unowned self] url in openedURLs.append(url); return openResult },
                launchApp: { [unowned self] identifier in launched.append(identifier); return launchResult },
                runShortcut: { [unowned self] name in
                    shortcuts.append(name)
                    if let shortcutError { throw shortcutError }
                },
                toggleBar: { [unowned self] in toggles += 1 }
            )
        }

        var callCount: Int { openedURLs.count + launched.count + shortcuts.count + toggles }
    }

    private struct TestError: Error, LocalizedError {
        var errorDescription: String? { "launch refused" }
    }

    @Test func eachActionReachesExactlyItsOwnSeamOnce() throws {
        let seams = Seams()
        let runner = seams.makeRunner()
        let site = URL(string: "https://example.com/dashboard")!

        #expect(runner.run(.openURL(site)).isSuccess)
        #expect(seams.openedURLs == [site])
        #expect(seams.callCount == 1)

        #expect(runner.run(.launchApp(bundleIdentifier: "  com.apple.Safari ")).isSuccess)
        #expect(seams.launched == ["com.apple.Safari"])
        #expect(seams.callCount == 2)

        #expect(runner.run(.runShortcut(name: " Start Focus ")).isSuccess)
        #expect(seams.shortcuts == ["Start Focus"])
        #expect(seams.callCount == 3)

        #expect(runner.run(.toggleBar).isSuccess)
        #expect(seams.toggles == 1)
        #expect(seams.callCount == 4)
    }

    @Test(arguments: [
        WidgetAction.openURL(URL(string: "file:///etc/passwd")!),
        .openURL(URL(string: "javascript:alert(1)")!),
        .openURL(URL(string: "https://")!),
        .openURL(URL(string: "example.com")!),
        .launchApp(bundleIdentifier: "  "),
        .runShortcut(name: "")
    ])
    func invalidActionsAreRefusedWithoutTouchingAnySeam(action: WidgetAction) throws {
        let seams = Seams()
        let runner = seams.makeRunner()
        let result = runner.run(action)
        guard case let .failure(error) = result, case let .invalidAction(problem) = error else {
            Issue.record("expected an invalidAction failure, got \(result)")
            return
        }
        #expect(problem == WidgetLibrary.validate(action))
        #expect(!error.message.isEmpty)
        #expect(seams.callCount == 0)
    }

    @Test func seamFailuresMapToDescriptiveErrors() throws {
        let seams = Seams()
        let runner = seams.makeRunner()
        let site = URL(string: "https://example.com")!

        seams.openResult = false
        #expect(runner.run(.openURL(site)).failure == .openURLFailed(site))
        #expect(seams.openedURLs == [site])

        seams.launchResult = false
        #expect(runner.run(.launchApp(bundleIdentifier: "com.example.Missing")).failure
                == .appNotFound(bundleIdentifier: "com.example.Missing"))
        #expect(seams.launched == ["com.example.Missing"])

        seams.shortcutError = TestError()
        #expect(runner.run(.runShortcut(name: "Go")).failure == .shortcutFailed(name: "Go", reason: "launch refused"))
        seams.shortcutError = WidgetActionError.shortcutsUnavailable
        #expect(runner.run(.runShortcut(name: "Go")).failure == .shortcutsUnavailable)
        #expect(seams.shortcuts == ["Go", "Go"])
        #expect(seams.toggles == 0)

        let messages = [
            WidgetActionError.openURLFailed(site).message,
            WidgetActionError.appNotFound(bundleIdentifier: "com.example.Missing").message,
            WidgetActionError.shortcutsUnavailable.message,
            WidgetActionError.shortcutFailed(name: "Go", reason: "launch refused").message,
            WidgetActionError.invalidAction(.unsupportedURLScheme).message
        ]
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(messages[0].contains("https://example.com"))
        #expect(messages[1].contains("com.example.Missing"))
        #expect(messages[3].contains("Go") && messages[3].contains("launch refused"))
        #expect(messages[4].contains(WidgetLibrary.ValidationProblem.unsupportedURLScheme.message))
    }

    @Test func shortcutsCommandIsAFixedExecutableWithAnArgumentVector() {
        #expect(WidgetActionRunner.shortcutsCommand(name: "Start Focus") == ["/usr/bin/shortcuts", "run", "--", "Start Focus"])
        // Shell metacharacters travel as one literal argument; there is no shell to interpret them.
        let hostile = "x; rm -rf ~ $(whoami) `id` | cat"
        #expect(WidgetActionRunner.shortcutsCommand(name: hostile) == ["/usr/bin/shortcuts", "run", "--", hostile])
        #expect(WidgetActionRunner.shortcutsExecutable.isFileURL)
        #expect(WidgetActionRunner.shortcutsExecutable.path == "/usr/bin/shortcuts")
    }

    @Test func defaultSeamsAreTheSystemOnesAndToggleIsMandatory() {
        var toggles = 0
        let runner = WidgetActionRunner(toggleBar: { toggles += 1 })
        // Only the toggle seam is exercised: it is the one default-free, side-effect-free action.
        #expect(runner.run(.toggleBar).isSuccess)
        #expect(toggles == 1)
        #expect(runner.run(.openURL(URL(string: "file:///tmp")!)).failure == .invalidAction(.unsupportedURLScheme))
        #expect(toggles == 1)
    }
}

/// `Void` is not Equatable, so outcomes are compared through these projections.
extension Result where Success == Void, Failure == WidgetActionError {
    var failure: WidgetActionError? {
        if case let .failure(error) = self { return error }
        return nil
    }

    var isSuccess: Bool { failure == nil }
}

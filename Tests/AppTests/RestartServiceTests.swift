import Foundation
import Testing

@Suite
@MainActor
struct RestartServiceTests {

    @Test func commandIsAShellScriptThatWaitsForThePidThenOpensTheBundle() throws {
        let argv = RestartService.command(bundlePath: "/Applications/Bar Keeper's Friend.app", pid: 4242)
        #expect(argv.count == 3)
        #expect(argv[0] == "/bin/sh")
        #expect(argv[1] == "-c")
        let script = argv[2]
        #expect(script.contains("kill -0 4242 "))
        #expect(!script.contains("4242\n"))
        #expect(script.contains("sleep \(RestartService.pollInterval)"))
        #expect(script.contains("-ge \(RestartService.maxPolls) ] && exit 1"))
        #expect(script.contains("done; sleep \(RestartService.launchServicesSettle); exec /usr/bin/open "))

        // The open call must run only after the wait loop, with the path as one quoted word.
        let openRange = try #require(script.range(of: "exec /usr/bin/open "))
        let waitRange = try #require(script.range(of: "while kill -0 4242"))
        #expect(waitRange.upperBound <= openRange.lowerBound)
        let argument = String(script[openRange.upperBound...])
        #expect(shellUnquote(argument) == "/Applications/Bar Keeper's Friend.app")
    }

    @Test func pidIsInterpolatedVerbatimForAnyProcessID() {
        for pid: pid_t in [1, 501, 99_999, pid_t.max] {
            let script = RestartService.command(bundlePath: "/A.app", pid: pid)[2]
            #expect(script.contains("while kill -0 \(pid) 2>/dev/null; do"))
        }
    }

    @Test(arguments: [
        "/Applications/BarKeepersFriend.app",
        "/Applications/Bar Keeper's Friend.app",
        "/Users/it's/'quoted'/app.app",
        "/tmp/\"double\" $HOME `id` $(rm -rf ~) ; & | > < * ? [x] # ~ \\ back\\slash.app",
        "/Volumes/\u{00DC}n\u{00EF}c\u{00F8}d\u{00E9} \u{1F378}/Bar.app",
        "/new\nline/tab\t.app",
        "'",
        "''",
        "",
        " leading and trailing "
    ])
    func singleQuotingRoundTripsThroughAPOSIXWordParser(path: String) {
        let quoted = RestartService.shellQuoted(path)
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        #expect(shellUnquote(quoted) == path)
        // Inside single quotes only the quote itself needs treatment; everything else is verbatim.
        if !path.contains("'") {
            #expect(quoted == "'\(path)'")
        }
        #expect(quoted.components(separatedBy: "'\\''").count == path.filter { $0 == "'" }.count + 1)
        let script = RestartService.command(bundlePath: path, pid: 7)[2]
        #expect(script.hasSuffix("exec /usr/bin/open \(quoted)"))
    }

    @Test func restartLaunchesExactlyTheCommandOnceAndReportsSuccess() {
        var launched: [[String]] = []
        let service = RestartService(launch: { launched.append($0) })
        let bundle = URL(fileURLWithPath: "/Applications/Bar Keeper's Friend.app", isDirectory: true)
        #expect(service.restart(bundleURL: bundle, pid: 31337))
        #expect(launched.count == 1)
        #expect(launched.first == RestartService.command(bundlePath: "/Applications/Bar Keeper's Friend.app", pid: 31337))
    }

    @Test func restartReportsAFailedLaunchSoTheCallerKeepsRunning() {
        struct SpawnFailure: Error {}
        var attempts = 0
        let service = RestartService(launch: { _ in attempts += 1; throw SpawnFailure() })
        #expect(!service.restart(bundleURL: URL(fileURLWithPath: "/A.app"), pid: 1))
        #expect(attempts == 1)
    }

    @Test func restartDoesNotLaunchAnythingUntilAsked() {
        var launched = 0
        _ = RestartService(launch: { _ in launched += 1 })
        #expect(launched == 0)
    }
}

/// Minimal POSIX word parser: single-quoted runs plus backslash escapes outside quotes. Returns nil
/// when the word would be split or expanded by a real shell, so a quoting bug cannot pass.
private func shellUnquote(_ word: String) -> String? {
    var result = ""
    var index = word.startIndex
    while index < word.endIndex {
        let character = word[index]
        if character == "'" {
            let start = word.index(after: index)
            guard let close = word[start...].firstIndex(of: "'") else { return nil }
            result += word[start..<close]
            index = word.index(after: close)
        } else if character == "\\" {
            let next = word.index(after: index)
            guard next < word.endIndex else { return nil }
            result.append(word[next])
            index = word.index(after: next)
        } else {
            guard !" \t\n|&;<>()$`\"*?[#~=%{}".contains(character) else { return nil }
            result.append(character)
            index = word.index(after: index)
        }
    }
    return result
}

import Testing
@testable import BarKeepersFriendCore

/// Unit tests for the pure version-string formatter behind the Settings header (and any future
/// About surface). The composition rules are easy to get subtly wrong, so they're pinned here.
@Suite struct AppInfoTests {

    @Test func shortAndDistinctBuildAreCombined() {
        #expect(AppInfo.displayVersion(short: "1.2.0", build: "34") == "1.2.0 (34)")
    }

    @Test func buildEqualToShortIsDropped() {
        // Before a real build pipeline assigns distinct numbers, both keys can hold the same value;
        // "1.2.0 (1.2.0)" is noise.
        #expect(AppInfo.displayVersion(short: "1.2.0", build: "1.2.0") == "1.2.0")
    }

    @Test func missingOrEmptyBuildDropsParenthetical() {
        #expect(AppInfo.displayVersion(short: "0.1.0", build: nil) == "0.1.0")
        #expect(AppInfo.displayVersion(short: "0.1.0", build: "") == "0.1.0")
        #expect(AppInfo.displayVersion(short: "0.1.0", build: "   ") == "0.1.0")
    }

    @Test func missingShortVersionFallsBackToDash() {
        #expect(AppInfo.displayVersion(short: nil, build: "34") == "—")
        #expect(AppInfo.displayVersion(short: "", build: "34") == "—")
        #expect(AppInfo.displayVersion(short: "  ", build: nil) == "—")
    }

    @Test func whitespaceIsTrimmedAroundBothFields() {
        // A stray space in Info.plist must not leak into the label or produce "1.2.0 ()".
        #expect(AppInfo.displayVersion(short: " 1.2.0 ", build: " 34 ") == "1.2.0 (34)")
        #expect(AppInfo.displayVersion(short: " 1.2.0 ", build: "  ") == "1.2.0")
    }

    @Test func matchesTheProjectsCurrentVersion() {
        // project.yml ships MARKETING_VERSION 0.1.0 / CURRENT_PROJECT_VERSION 1 → "0.1.0 (1)".
        #expect(AppInfo.displayVersion(short: "0.1.0", build: "1") == "0.1.0 (1)")
    }
}

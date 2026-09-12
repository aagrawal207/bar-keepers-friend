import Testing
@testable import BarKeepersFriendCore

@Suite struct SemanticVersionTests {

    @Test(arguments: [
        ("1", SemanticVersion(major: 1, minor: 0, patch: 0)),
        ("1.2", SemanticVersion(major: 1, minor: 2, patch: 0)),
        ("1.2.3", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("v1.2.3", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("V2.0", SemanticVersion(major: 2, minor: 0, patch: 0)),
        (" v1.2.3\n", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("1.2.3-beta.1", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("1.2.3+build.7", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("1.2.3-rc.1+sha.abc", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("1.2.3+meta-with-dash", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("v0.1.0", SemanticVersion(major: 0, minor: 1, patch: 0)),
        ("01.002.0003", SemanticVersion(major: 1, minor: 2, patch: 3)),
        ("0", SemanticVersion(major: 0, minor: 0, patch: 0)),
        ("10.20.30", SemanticVersion(major: 10, minor: 20, patch: 30))
    ])
    func parsesReleaseTagsAndBundleVersions(text: String, expected: SemanticVersion) {
        #expect(SemanticVersion(text) == expected)
    }

    @Test(arguments: [
        "", " ", "v", "V", "1.2.3.4", "1..2", ".1", "1.", "1.2.", "a.b", "1.2.x", "-1.0", "+1",
        "1.-2", "1 .2", "1. 2", "\u{0661}.\u{0662}", "\u{FF11}.\u{FF12}", "1.2.3 (4)", "1,2,3", "99999999999999999999",
        "1e3", "0x10", "1_000", "vv1"
    ])
    func rejectsAnythingThatIsNotOneToThreeDecimalComponents(text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test func comparesNumericallyPerComponent() {
        let ordered = ["0.0.1", "0.1.0", "0.9.9", "0.10.0", "1.0.0", "1.0.1", "1.1.0", "1.9.0", "1.10.0", "2.0.0", "10.0.0"]
            .compactMap { SemanticVersion($0) }
        #expect(ordered.count == 11)
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            #expect(earlier < later)
            #expect(!(later < earlier))
            #expect(earlier != later)
        }
        #expect(ordered.shuffled().sorted() == ordered)
    }

    @Test func equalityIgnoresPresentationAndSuffixes() {
        #expect(SemanticVersion("v1.2.0") == SemanticVersion("1.2"))
        #expect(SemanticVersion("1.2.3-beta") == SemanticVersion("1.2.3"))
        #expect(SemanticVersion("1") == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(Set([SemanticVersion("1.2.3"), SemanticVersion("v1.2.3+build")]).count == 1)
        #expect(SemanticVersion(major: 1, minor: 2, patch: 3).description == "1.2.3")
        #expect(SemanticVersion("v7")?.description == "7.0.0")
    }

    @Test(arguments: [
        (nil, "v1.0.0"), ("1.0.0", nil), (nil, nil), ("", "v1.0.0"), ("1.0.0", "nightly"),
        ("0.1.0 (1)", "v0.2.0"), ("1.0.0", "1.2.3.4")
    ] as [(String?, String?)])
    func unparseableInputYieldsUnknownRatherThanAGuess(current: String?, latestTag: String?) {
        #expect(UpdateAvailability.compare(current: current, latestTag: latestTag) == .unknown)
    }

    @Test(arguments: [
        ("0.1.0", "v0.1.1"), ("0.1.0", "v0.2.0"), ("0.1.0", "1.0.0"), ("1.9.0", "v1.10.0"),
        ("1.0.0", "1.0.1-beta"), ("0.1", "v0.1.1")
    ])
    func newerTagIsAvailable(current: String, latestTag: String) throws {
        let latest = try #require(SemanticVersion(latestTag))
        #expect(UpdateAvailability.compare(current: current, latestTag: latestTag) == .available(latest: latest))
    }

    @Test(arguments: [
        ("0.1.0", "v0.1.0"), ("0.1.0", "0.1.0"), ("0.1.0", "v0.1.0-rc.1"), ("0.1.0", "v0.0.9"),
        ("2.0.0", "v1.99.99"), ("0.1.0", "0.1")
    ])
    func equalOrOlderTagIsUpToDate(current: String, latestTag: String) {
        #expect(UpdateAvailability.compare(current: current, latestTag: latestTag) == .upToDate)
    }
}

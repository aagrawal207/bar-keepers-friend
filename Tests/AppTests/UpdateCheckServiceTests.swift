import BarKeepersFriendCore
import Foundation
import Synchronization
import Testing

@Suite
@MainActor
struct UpdateCheckServiceTests {
    private static let pageURL = "https://github.com/aagrawal207/bar-keepers-friend/releases/tag/v0.2.0"

    private static func releaseJSON(tag: String?, htmlURL: String? = pageURL, extra: String = "") -> Data {
        var fields: [String] = []
        if let tag { fields.append(#""tag_name":"\#(tag)""#) }
        if let htmlURL { fields.append(#""html_url":"\#(htmlURL)""#) }
        fields.append(#""draft":false,"prerelease":false,"name":"Release""#)
        if !extra.isEmpty { fields.append(extra) }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    /// A service whose transport records every requested URL and returns or throws the given outcome.
    private func makeService(_ outcome: Result<Data, Error>) -> (UpdateCheckService, RequestLog) {
        let log = RequestLog()
        let service = UpdateCheckService(fetch: { url in
            log.record(url)
            return try outcome.get()
        })
        return (service, log)
    }

    @Test func endpointIsTheRepositoriesLatestReleaseAndNothingElseIsContacted() async {
        #expect(UpdateCheckService.latestReleaseURL.absoluteString
                == "https://api.github.com/repos/aagrawal207/bar-keepers-friend/releases/latest")
        let (service, log) = makeService(.success(Self.releaseJSON(tag: "v0.1.0")))
        #expect(log.requested.isEmpty)
        _ = await service.checkNow(currentVersion: "0.1.0")
        #expect(log.requested == [UpdateCheckService.latestReleaseURL])
        _ = await service.checkNow(currentVersion: "0.1.0")
        #expect(log.requested == [UpdateCheckService.latestReleaseURL, UpdateCheckService.latestReleaseURL])
    }

    @Test func newerTagIsReportedWithItsGitHubPage() async throws {
        let (service, _) = makeService(.success(Self.releaseJSON(tag: "v0.2.0")))
        let result = await service.checkNow(currentVersion: "0.1.0")
        let url = try #require(URL(string: Self.pageURL))
        #expect(result == .available(latest: SemanticVersion(major: 0, minor: 2, patch: 0), url: url))
        #expect(result.isAvailable)
        #expect(result.alertTitle == "Update available")
        #expect(result.alertMessage.contains("0.2.0"))
    }

    @Test(arguments: ["v0.1.0", "0.1.0", "v0.1.0-rc.2", "v0.0.9", "0.1"])
    func equalOrOlderTagIsUpToDate(tag: String) async {
        let (service, _) = makeService(.success(Self.releaseJSON(tag: tag)))
        let result = await service.checkNow(currentVersion: "0.1.0")
        #expect(result == .upToDate(current: "0.1.0"))
        #expect(!result.isAvailable)
        #expect(result.alertTitle == "You're up to date")
        #expect(result.alertMessage.contains("0.1.0"))
    }

    @Test(arguments: [
        "", "not json", "[]", "null", #"{"tag_name":7}"#, #"{"html_url":"https://github.com/x"}"#,
        #"{"tag_name":null,"html_url":"https://github.com/x"}"#, "{\"tag_name\":\"v0.2.0\""
    ])
    func malformedPayloadFailsWithoutThrowing(body: String) async {
        let (service, _) = makeService(.success(Data(body.utf8)))
        let result = await service.checkNow(currentVersion: "0.1.0")
        guard case .failed(let reason) = result else {
            Issue.record("Expected a failure for \(body), got \(result)")
            return
        }
        #expect(reason.contains("could not be read"))
        #expect(result.alertTitle == "Could not check for updates")
        #expect(result.alertMessage == reason)
    }

    @Test func unparseableTagIsReportedRatherThanGuessed() async {
        let (service, _) = makeService(.success(Self.releaseJSON(tag: "nightly")))
        let result = await service.checkNow(currentVersion: "0.1.0")
        guard case .failed(let reason) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(reason.contains("nightly"))
        #expect(reason.contains("0.1.0"))
    }

    @Test func displayVersionIsNotAcceptedAsTheCurrentVersion() async {
        let (service, _) = makeService(.success(Self.releaseJSON(tag: "v0.2.0")))
        let result = await service.checkNow(currentVersion: "0.1.0 (1)")
        guard case .failed(let reason) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(reason.contains("0.1.0 (1)"))
    }

    @Test(arguments: [
        nil, "", "not a url", "ftp://github.com/x", "http://github.com/aagrawal207/bar-keepers-friend/releases/tag/v0.2.0",
        "https://evil.example/github.com/", "https://github.com.evil.example/x", "javascript:alert(1)"
    ] as [String?])
    func onlyAnHTTPSGitHubPageIsOpenedFromTheResponse(htmlURL: String?) async {
        #expect(UpdateCheckService.releaseURL(from: htmlURL) == UpdateCheckService.releasesPageURL)
        let (service, _) = makeService(.success(Self.releaseJSON(tag: "v0.2.0", htmlURL: htmlURL)))
        let result = await service.checkNow(currentVersion: "0.1.0")
        #expect(result == .available(latest: SemanticVersion(major: 0, minor: 2, patch: 0), url: UpdateCheckService.releasesPageURL))
    }

    @Test func gitHubPagesAreAcceptedCaseInsensitively() throws {
        let mixed = "HTTPS://GitHub.com/aagrawal207/bar-keepers-friend/releases/tag/v0.2.0"
        #expect(UpdateCheckService.releaseURL(from: mixed) == URL(string: mixed))
        #expect(UpdateCheckService.releaseURL(from: Self.pageURL) == URL(string: Self.pageURL))
        #expect(UpdateCheckService.releaseURL(from: mixed) != UpdateCheckService.releasesPageURL)
    }

    @Test(arguments: [
        (UpdateCheckError.httpStatus(404), "No published releases"),
        (UpdateCheckError.httpStatus(403), "rate limiting"),
        (UpdateCheckError.httpStatus(429), "rate limiting"),
        (UpdateCheckError.httpStatus(500), "HTTP 500"),
        (UpdateCheckError.httpStatus(301), "HTTP 301"),
        (UpdateCheckError.invalidResponse, "unexpected response")
    ])
    func transportStatusesAreWordedForTheUser(error: UpdateCheckError, expected: String) async {
        let (service, _) = makeService(.failure(error))
        let result = await service.checkNow(currentVersion: "0.1.0")
        guard case .failed(let reason) = result else {
            Issue.record("Expected a failure, got \(result)")
            return
        }
        #expect(reason.contains(expected))
    }

    @Test func networkErrorsAndCancellationBecomeFailures() async {
        let offline = makeService(.failure(URLError(.notConnectedToInternet))).0
        guard case .failed(let reason) = await offline.checkNow(currentVersion: "0.1.0") else {
            Issue.record("Expected a failure for an offline fetch")
            return
        }
        #expect(reason.hasPrefix("GitHub could not be reached."))
        #expect(reason.count > "GitHub could not be reached.".count)

        let cancelled = makeService(.failure(CancellationError())).0
        #expect(await cancelled.checkNow(currentVersion: "0.1.0") == .failed("The update check was cancelled."))
    }

    @Test func userAgentIdentifiesTheAppAndItsSource() {
        let agent = UpdateCheckService.userAgent
        #expect(agent.hasPrefix("BarKeepersFriend/"))
        #expect(agent.contains("https://github.com/aagrawal207/bar-keepers-friend"))
        #expect(!agent.contains("\n"))
    }

    @Test func realTransportUsesATenSecondCeiling() {
        #expect(GitHubReleaseFetch.timeout == 10)
    }
}

/// Records the URLs a fake transport was asked for; a class so the Sendable closure can share it.
private final class RequestLog: Sendable {
    private let urls = Mutex<[URL]>([])

    func record(_ url: URL) {
        urls.withLock { $0.append(url) }
    }

    var requested: [URL] {
        urls.withLock { $0 }
    }
}

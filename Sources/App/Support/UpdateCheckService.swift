import BarKeepersFriendCore
import Foundation

/// What a manual update check found, ready for an alert.
enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String)
    case available(latest: SemanticVersion, url: URL)
    case failed(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var alertTitle: String {
        switch self {
        case .upToDate: return "You're up to date"
        case .available: return "Update available"
        case .failed: return "Could not check for updates"
        }
    }

    var alertMessage: String {
        switch self {
        case .upToDate(let current):
            return "Bar Keeper's Friend \(current) is the latest version."
        case .available(let latest, _):
            return "Version \(latest) is available on GitHub."
        case .failed(let reason):
            return reason
        }
    }
}

/// Transport failures the real fetch reports so the service can word them for the user.
enum UpdateCheckError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
}

/// Manual, user-initiated update check against the GitHub Releases API. There is no background
/// polling and nothing is sent beyond the single GET; the result is only ever shown to the user.
@MainActor
final class UpdateCheckService {
    typealias Fetch = @Sendable (URL) async throws -> Data

    nonisolated static let latestReleaseURL = URL(string: "https://api.github.com/repos/aagrawal207/bar-keepers-friend/releases/latest")!
    /// Shown when a release lacks a usable GitHub page URL.
    nonisolated static let releasesPageURL = URL(string: "https://github.com/aagrawal207/bar-keepers-friend/releases")!

    /// GitHub rejects requests without a User-Agent; this one identifies the app and its source.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "BarKeepersFriend/\(version) (macOS; +https://github.com/aagrawal207/bar-keepers-friend)"
    }

    private let fetch: Fetch

    init(fetch: @escaping Fetch = GitHubReleaseFetch.make(userAgent: UpdateCheckService.userAgent)) {
        self.fetch = fetch
    }

    /// Never throws: every failure becomes `.failed` with a sentence the alert can show as-is.
    /// `currentVersion` must be the raw `CFBundleShortVersionString`, not the display version.
    func checkNow(currentVersion: String) async -> UpdateCheckResult {
        let data: Data
        do {
            data = try await fetch(Self.latestReleaseURL)
        } catch let error as UpdateCheckError {
            return .failed(Self.message(for: error))
        } catch is CancellationError {
            return .failed("The update check was cancelled.")
        } catch {
            return .failed("GitHub could not be reached. \(error.localizedDescription)")
        }

        guard let release = try? JSONDecoder().decode(LatestRelease.self, from: data) else {
            return .failed("The release information from GitHub could not be read.")
        }
        switch UpdateAvailability.compare(current: currentVersion, latestTag: release.tagName) {
        case .available(let latest):
            return .available(latest: latest, url: Self.releaseURL(from: release.htmlURL))
        case .upToDate:
            return .upToDate(current: currentVersion)
        case .unknown:
            return .failed("Version \"\(currentVersion)\" and the latest release tag \"\(release.tagName)\" could not be compared.")
        }
    }

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Only an https github.com page is opened from the response; anything else falls back to the
    /// releases list, so a tampered payload cannot send the user elsewhere.
    static func releaseURL(from text: String?) -> URL {
        guard let text, let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              url.host()?.lowercased() == "github.com" else { return releasesPageURL }
        return url
    }

    private static func message(for error: UpdateCheckError) -> String {
        switch error {
        case .invalidResponse:
            return "GitHub returned an unexpected response."
        case .httpStatus(404):
            return "No published releases were found on GitHub."
        case .httpStatus(403), .httpStatus(429):
            return "GitHub is rate limiting update checks right now. Try again later."
        case .httpStatus(let code):
            return "GitHub returned HTTP \(code)."
        }
    }
}

/// The real transport: one ephemeral GET with a 10 second ceiling and no cookies or cache.
enum GitHubReleaseFetch {
    static let timeout: TimeInterval = 10

    static func make(userAgent: String) -> UpdateCheckService.Fetch {
        { url in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }

            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw UpdateCheckError.httpStatus(http.statusCode) }
            return data
        }
    }
}

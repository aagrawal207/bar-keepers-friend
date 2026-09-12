import Foundation

/// A release version compared numerically per component. Pre-release and build suffixes are dropped
/// on parse, so a pre-release tag equals its final release; fine for comparing our own tags.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Accepts 1-3 decimal components, an optional leading `v`/`V`, surrounding whitespace, and
    /// ignores everything from the first `-` or `+`; anything else (signs, 4 parts, ...) is `nil`.
    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        if let suffix = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = text[..<suffix]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var numbers: [Int] = []
        for part in parts {
            // Int("+1") parses, so digits are checked byte-wise before conversion.
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers.count > 1 ? numbers[1] : 0, patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The outcome of comparing the running version with the newest published release tag.
public enum UpdateAvailability: Hashable, Sendable {
    case upToDate
    case available(latest: SemanticVersion)
    /// Either string failed to parse; the caller should say so rather than guess.
    case unknown

    /// A newer `latestTag` is `available`; an equal or older one is `upToDate` (a development build
    /// ahead of the newest release is not an update candidate).
    public static func compare(current: String?, latestTag: String?) -> UpdateAvailability {
        guard let current, let running = SemanticVersion(current),
              let latestTag, let latest = SemanticVersion(latestTag) else { return .unknown }
        return latest > running ? .available(latest: latest) : .upToDate
    }
}

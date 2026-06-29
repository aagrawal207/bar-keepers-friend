import Foundation

/// Pure helpers for presenting the app's identity (name/version). The actual values come from the
/// bundle at the call site (App target); the *formatting* lives here so it's unit-tested rather
/// than assembled ad-hoc in a view.
public enum AppInfo {

    /// A user-facing version string from the marketing version and build number.
    ///
    /// Conventions, matching how a shipped Mac app's About box reads:
    ///   - `"1.2.0"` + `"34"` → `"1.2.0 (34)"` — the build in parentheses.
    ///   - When the build is missing, empty, or identical to the short version (common before a
    ///     real build pipeline assigns distinct numbers), the parenthetical is dropped → `"1.2.0"`,
    ///     since `"1.2.0 (1.2.0)"` is just noise.
    ///   - When the short version itself is missing/empty, fall back to `"—"` so the UI never shows
    ///     an empty label.
    ///
    /// Whitespace is trimmed so a stray space in Info.plist can't produce `"1.2.0 ()"`.
    public static func displayVersion(short: String?, build: String?) -> String {
        let shortTrimmed = (short ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let buildTrimmed = (build ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortTrimmed.isEmpty else { return "—" }
        guard !buildTrimmed.isEmpty, buildTrimmed != shortTrimmed else { return shortTrimmed }
        return "\(shortTrimmed) (\(buildTrimmed))"
    }
}

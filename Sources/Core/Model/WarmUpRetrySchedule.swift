import Foundation

/// The escalating delays (in milliseconds, from launch) at which the floating-bar warm-up should
/// re-attempt a capture while glyphs are still incomplete.
///
/// WHY THIS EXISTS — the cold-launch glyph gap. On a cold launch the menu-bar glyphs do not
/// composite into the capturable display image for ~tens of seconds (observed ~30s on one rig, but
/// the exact time varies by machine/session). The launch warm-up and the in-loop capture retries
/// all finish within ~1.5s, so every one of them captures 0 real glyphs and the bar falls back to
/// app icons until some INCIDENTAL later event (a screen-parameter change, a user open, a diag
/// signal) happens to run after the compositor is warm. These escalating offsets bridge that gap
/// with a SMALL, BOUNDED set of extra warm-up passes that fan out over the window where the
/// compositor typically warms up — early enough to fill in quickly on a fast machine, late enough
/// to still catch a slow one — without a tight capture loop spinning the Screen Recording privacy
/// indicator for the whole window.
///
/// Pure so the cadence (bounded count, monotonically increasing, no single hard-coded "30s") is
/// unit-tested independently of the App-target timer/capture glue that consumes it.
public enum WarmUpRetrySchedule {
    /// Delays from the moment the schedule is armed, in milliseconds. Escalating (each strictly
    /// later than the last) so the passes fan out across the warm-up window instead of clustering,
    /// and BOUNDED (a fixed, short list) so the privacy indicator can flash at most this many extra
    /// times — never an unbounded storm. The last offset is the practical ceiling: if glyphs still
    /// haven't composited by then, the existing event-driven refreshes (screen change, user open)
    /// remain the backstop, exactly as today.
    ///
    /// These are deliberately NOT a single magic constant — they were chosen to straddle the
    /// measured warm-up time on either side. Tunable here in one pure place if a future on-device
    /// session shows a different distribution.
    ///
    /// Span (2s…70s) brackets the measured cold-launch warm-up: on this rig the menu-bar glyphs
    /// first composited ~60s after launch (launch 15:31:30 → glyphs 15:32:30), and an earlier
    /// session showed gaps of similar order. An earlier draft capped at 25s, which always fired
    /// before this machine warmed up and fell through to the incidental backstop; the later offsets
    /// actually catch the warm-up here. Still bounded (6 passes) and escalating, so the privacy
    /// indicator flashes at most a handful of extra times across a ~70s window, not a tight loop.
    public static let offsetsMs: [Int] = [2_000, 5_000, 12_000, 25_000, 45_000, 70_000]

    /// The number of bounded warm-up retries — the maximum number of EXTRA capture passes (and so
    /// the maximum number of extra privacy-indicator flashes) the schedule can ever trigger.
    public static var count: Int { offsetsMs.count }
}

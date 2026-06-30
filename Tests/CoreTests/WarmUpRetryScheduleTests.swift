import Testing
@testable import BarKeepersFriendCore

@Suite struct WarmUpRetryScheduleTests {
    @Test func offsetsAreBoundedAndNonEmpty() {
        // A SMALL, fixed set — the whole point is that the privacy indicator can flash at most this
        // many extra times. Pin the bound so a future edit can't silently turn it into a storm.
        #expect(WarmUpRetrySchedule.offsetsMs.count == WarmUpRetrySchedule.count)
        #expect(WarmUpRetrySchedule.count >= 1)
        #expect(WarmUpRetrySchedule.count <= 6)
    }

    @Test func offsetsStrictlyEscalate() {
        // Each pass must be strictly later than the previous so they fan out across the warm-up
        // window rather than clustering (which would just reproduce the ~1.5s burst that misses).
        let offsets = WarmUpRetrySchedule.offsetsMs
        for (earlier, later) in zip(offsets, offsets.dropFirst()) {
            #expect(later > earlier)
        }
    }

    @Test func offsetsArePositive() {
        // A zero/negative delay would fire synchronously with the launch warm-up — the exact thing
        // that already misses on a cold launch. Every retry must be in the future.
        #expect(WarmUpRetrySchedule.offsetsMs.allSatisfy { $0 > 0 })
    }

    @Test func windowStraddlesTheObservedWarmUp() {
        // The retries must bracket the warm-up time we measured on BOTH sides: at least one early
        // enough to fill in fast on a quick machine, and the window must extend PAST the measured
        // cold-launch warm-up (~60s on this rig: launch 15:31:30 → glyphs 15:32:30) so a
        // late-compositing run is still caught before we give up to event-driven refreshes. Not a
        // single magic constant — a spread that brackets it.
        let offsets = WarmUpRetrySchedule.offsetsMs
        #expect(offsets.first! <= 5_000)
        #expect(offsets.last! >= 60_000)
    }
}

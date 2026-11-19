import Foundation

/// When a playlist changes to its next wallpaper: on the clock.
///
/// Every 30 minutes means at :00 and :30, every 15 at :00, :15, :30 and :45,
/// every 3 hours at 12, 3, 6 and 9. The times are counted from midnight on
/// the Mac's own clock, so they are the same every day. A custom time that
/// does not fit a day evenly, like 45 or 7 minutes, still lands on the same
/// times each day; its last step before midnight is just shorter.
///
/// A playlist used to count from whenever it was started, and every wake
/// from sleep started the count over, so its times moved all day and were
/// different every day (a Discord idea, November 2026).
///
/// A wallpaper that has just gone up, by pressing play, Next or Previous, or
/// by a wake that missed a change, stays at least half the interval before
/// the clock may change it, and never needs more than 30 minutes. Without
/// that, a playlist started at 3:28 on every 30 minutes would change again at
/// 3:30, and a daily one started at 2 PM would skip that midnight and wait
/// until the one after.
///
/// Everything here works from the time zone's own offsets rather than
/// `Calendar`'s "set the hour" calls, which jump a whole day around some
/// summer time changes (Lord Howe Island's half hour one, for instance).
public enum PlaylistClock {
    /// The longest interval the playlist editor offers.
    static let longestInterval = 24 * 60

    /// How long a wallpaper that has just gone up stays before the clock may
    /// change it: half the interval, at most 30 minutes.
    public static func minimumStay(intervalMinutes: Int) -> TimeInterval {
        min(Double(clamped(intervalMinutes)) * 30, 30 * 60)
    }

    /// When the playlist changes next, for a wallpaper that went up at
    /// `shownAt`.
    public static func nextChange(
        afterShownAt shownAt: Date,
        intervalMinutes: Int,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date {
        clockTime(
            atOrAfter: shownAt.addingTimeInterval(minimumStay(intervalMinutes: intervalMinutes)),
            intervalMinutes: intervalMinutes,
            timeZone: timeZone
        )
    }

    /// Whether a change time has come since the wallpaper went up at
    /// `shownAt`. A timer can fire a hair before the wall clock gets there,
    /// so a second early counts as on time.
    public static func isDue(
        shownAt: Date,
        intervalMinutes: Int,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Bool {
        now.addingTimeInterval(1) >= nextChange(
            afterShownAt: shownAt, intervalMinutes: intervalMinutes, timeZone: timeZone
        )
    }

    /// The first of the playlist's clock times at or after `date`.
    ///
    /// Summer time: an hour the clock shows twice has its clock times twice,
    /// and a clock time the clock skips is taken at the moment the clock
    /// jumps past it, so a daily playlist still changes on the night the
    /// clock skips midnight.
    public static func clockTime(
        atOrAfter date: Date,
        intervalMinutes: Int,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date {
        let step = Double(clamped(intervalMinutes) * 60)
        // The wall clock as plain seconds, where every whole day is a
        // midnight. 1:30 shown twice is the same number both times.
        let wall = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        // In an hour the clock shows twice, a clock time that reads earlier
        // than `date` can still come after it, so the search starts a little
        // way back. No summer time change is longer than this.
        let lookBack = 3.0 * 3600
        let from = wall - lookBack
        var dayStart = (from / day).rounded(.down) * day
        var best: Date?
        var bestWall = Double.infinity
        searching: while dayStart < wall + 2 * day {
            var index = max(0, ((from - dayStart) / step).rounded(.up))
            while index * step < day {
                let mark = dayStart + index * step
                // Past this, a clock time can no longer come before the best
                // one found: two readings that far apart never swap order.
                if mark > bestWall + lookBack { break searching }
                for instant in instants(atWall: mark, timeZone: timeZone)
                where instant >= date && instant < (best ?? .distantFuture) {
                    best = instant
                    bestWall = mark
                }
                index += 1
            }
            dayStart += day
        }
        // Never reached: every day has a midnight, or the moment it was
        // skipped. A fallback still has to be a time in the future.
        return best ?? date.addingTimeInterval(step)
    }

    // MARK: - The wall clock

    private static let day = 86_400.0

    static func clamped(_ minutes: Int) -> Int {
        min(max(minutes, 1), longestInterval)
    }

    /// The moments the clock reads `wall`: usually one, two in an hour the
    /// clock shows twice, and for a time the clock skips, the moment it jumps
    /// past it.
    static func instants(atWall wall: Double, timeZone: TimeZone) -> [Date] {
        // Any moment reading `wall` is within 15 hours of it, so the offsets
        // in force 15 hours either side are the only ones it can have.
        let before = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall - 15 * 3600))
        let after = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall + 15 * 3600))
        var found: [Date] = []
        for offset in Set([before, after]) {
            let instant = Date(timeIntervalSince1970: wall - Double(offset))
            if timeZone.secondsFromGMT(for: instant) == offset { found.append(instant) }
        }
        if !found.isEmpty { return found.sorted() }
        // Skipped. The clock jumped forward from `before` to `after`
        // somewhere between these two moments.
        return [jump(
            from: wall - Double(after), to: wall - Double(before),
            reaching: after, timeZone: timeZone
        )]
    }

    /// The first whole second from which the clock runs on `offset`, given
    /// that it does at `high` and does not at `low`.
    private static func jump(from low: Double, to high: Double, reaching offset: Int, timeZone: TimeZone) -> Date {
        var low = low.rounded(.down), high = high.rounded(.up)
        while high - low > 1 {
            let middle = ((low + high) / 2).rounded(.down)
            if timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: middle)) == offset {
                high = middle
            } else {
                low = middle
            }
        }
        return Date(timeIntervalSince1970: high)
    }
}

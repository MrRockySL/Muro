import XCTest
@testable import MuroKit

/// Playlists change on the clock. Every time here is written with its own
/// offset, so a test reads the way a person would say it ("3:07 in Colombo")
/// and does not depend on the time zone of the Mac running the tests.
final class PlaylistClockTests: XCTestCase {
    private let colombo = TimeZone(identifier: "Asia/Colombo")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let lordHowe = TimeZone(identifier: "Australia/Lord_Howe")!
    private let havana = TimeZone(identifier: "America/Havana")!

    private func t(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// When a playlist changes next if its wallpaper went up at `shown`.
    private func next(_ shown: String, every minutes: Int, in zone: TimeZone? = nil) -> Date {
        PlaylistClock.nextChange(afterShownAt: t(shown), intervalMinutes: minutes, timeZone: zone ?? colombo)
    }

    private func due(shown: String, now: String, every minutes: Int, in zone: TimeZone? = nil) -> Bool {
        PlaylistClock.isDue(shownAt: t(shown), intervalMinutes: minutes, now: t(now), timeZone: zone ?? colombo)
    }

    // MARK: - The examples the owner approved (every 30 minutes)

    func testStartedAt307ChangesAt330Then400And430() {
        XCTAssertEqual(next("2026-11-19T03:07:00+05:30", every: 30), t("2026-11-19T03:30:00+05:30"))
        XCTAssertEqual(next("2026-11-19T03:30:00+05:30", every: 30), t("2026-11-19T04:00:00+05:30"))
        XCTAssertEqual(next("2026-11-19T04:00:00+05:30", every: 30), t("2026-11-19T04:30:00+05:30"))
    }

    /// 3:30 would leave the first wallpaper up for 5 minutes.
    func testStartedAt325SkipsTo400() {
        XCTAssertEqual(next("2026-11-19T03:25:00+05:30", every: 30), t("2026-11-19T04:00:00+05:30"))
    }

    func testNextAt340KeepsTheChangeAt400() {
        XCTAssertEqual(next("2026-11-19T03:40:00+05:30", every: 30), t("2026-11-19T04:00:00+05:30"))
    }

    func testLidClosedFrom410To415ChangesNothing() {
        XCTAssertFalse(due(shown: "2026-11-19T04:00:00+05:30", now: "2026-11-19T04:15:00+05:30", every: 30))
        XCTAssertEqual(next("2026-11-19T04:00:00+05:30", every: 30), t("2026-11-19T04:30:00+05:30"))
    }

    func testLidClosedFrom410To445ChangesOnOpeningThenAt500() {
        XCTAssertTrue(due(shown: "2026-11-19T04:00:00+05:30", now: "2026-11-19T04:45:00+05:30", every: 30))
        XCTAssertEqual(next("2026-11-19T04:45:00+05:30", every: 30), t("2026-11-19T05:00:00+05:30"))
    }

    /// However many changes a night of sleep missed, waking changes once and
    /// the clock takes over from there.
    func testOvernightChangesOnceOnWakingThenFollowsTheClock() {
        XCTAssertTrue(due(shown: "2026-11-19T23:00:00+05:30", now: "2026-11-20T08:13:00+05:30", every: 30))
        XCTAssertEqual(next("2026-11-20T08:13:00+05:30", every: 30), t("2026-11-20T08:30:00+05:30"))
    }

    // MARK: - Every choice in the editor, and custom ones

    func testFifteenMinutesChangesAtTheQuarterHours() {
        XCTAssertEqual(next("2026-11-19T03:07:00+05:30", every: 15), t("2026-11-19T03:15:00+05:30"))
        XCTAssertEqual(next("2026-11-19T03:15:00+05:30", every: 15), t("2026-11-19T03:30:00+05:30"))
        XCTAssertEqual(next("2026-11-19T03:30:00+05:30", every: 15), t("2026-11-19T03:45:00+05:30"))
        XCTAssertEqual(next("2026-11-19T03:45:00+05:30", every: 15), t("2026-11-19T04:00:00+05:30"))
    }

    func testTenMinutesChangesOnTheTens() {
        XCTAssertEqual(next("2026-11-19T03:01:00+05:30", every: 10), t("2026-11-19T03:10:00+05:30"))
        XCTAssertEqual(next("2026-11-19T03:10:00+05:30", every: 10), t("2026-11-19T03:20:00+05:30"))
    }

    func testOneHourChangesOnTheHour() {
        XCTAssertEqual(next("2026-11-19T09:20:00+05:30", every: 60), t("2026-11-19T10:00:00+05:30"))
        XCTAssertEqual(next("2026-11-19T10:00:00+05:30", every: 60), t("2026-11-19T11:00:00+05:30"))
        // 10:00 is only 10 minutes away.
        XCTAssertEqual(next("2026-11-19T09:50:00+05:30", every: 60), t("2026-11-19T11:00:00+05:30"))
    }

    /// 12, 3, 6 and 9, day and night. The wait is at most 30 minutes, so 15:00
    /// is not skipped for a wallpaper that went up at 14:00.
    func testThreeHoursChangesAt12And3And6And9() {
        XCTAssertEqual(next("2026-11-19T13:00:00+05:30", every: 180), t("2026-11-19T15:00:00+05:30"))
        XCTAssertEqual(next("2026-11-19T14:00:00+05:30", every: 180), t("2026-11-19T15:00:00+05:30"))
        XCTAssertEqual(next("2026-11-19T14:45:00+05:30", every: 180), t("2026-11-19T18:00:00+05:30"))
        XCTAssertEqual(next("2026-11-19T21:00:00+05:30", every: 180), t("2026-11-20T00:00:00+05:30"))
    }

    /// Daily means midnight. Started at 2 PM it changes that same night.
    func testEveryDayChangesAtMidnight() {
        XCTAssertEqual(next("2026-11-19T14:00:00+05:30", every: 1440), t("2026-11-20T00:00:00+05:30"))
        XCTAssertEqual(next("2026-11-20T00:00:00+05:30", every: 1440), t("2026-11-21T00:00:00+05:30"))
        // 10 minutes is too short a day; it waits for the next midnight.
        XCTAssertEqual(next("2026-11-19T23:50:00+05:30", every: 1440), t("2026-11-21T00:00:00+05:30"))
    }

    /// 45 minutes does not fit an hour evenly; the times count from midnight
    /// and are the same every day.
    func testFortyFiveMinutesCountsFromMidnight() {
        XCTAssertEqual(next("2026-11-19T00:00:00+05:30", every: 45), t("2026-11-19T00:45:00+05:30"))
        XCTAssertEqual(next("2026-11-19T00:45:00+05:30", every: 45), t("2026-11-19T01:30:00+05:30"))
        XCTAssertEqual(next("2026-11-19T22:30:00+05:30", every: 45), t("2026-11-19T23:15:00+05:30"))
        XCTAssertEqual(next("2026-11-19T23:15:00+05:30", every: 45), t("2026-11-20T00:00:00+05:30"))
    }

    /// 7 minutes leaves a shorter last step before midnight: 23:55, then 0:00.
    func testSevenMinutesHasAShorterLastStep() {
        XCTAssertEqual(next("2026-11-19T23:50:00+05:30", every: 7), t("2026-11-19T23:55:00+05:30"))
        XCTAssertEqual(next("2026-11-19T23:55:00+05:30", every: 7), t("2026-11-20T00:00:00+05:30"))
    }

    func testOneMinuteChangesOnTheWholeMinute() {
        XCTAssertEqual(next("2026-11-19T03:07:40+05:30", every: 1), t("2026-11-19T03:09:00+05:30"))
        XCTAssertEqual(next("2026-11-19T03:08:00+05:30", every: 1), t("2026-11-19T03:09:00+05:30"))
    }

    func testTheShortestStayIsHalfTheIntervalAndAtMostHalfAnHour() {
        XCTAssertEqual(PlaylistClock.minimumStay(intervalMinutes: 1), 30)
        XCTAssertEqual(PlaylistClock.minimumStay(intervalMinutes: 30), 15 * 60)
        XCTAssertEqual(PlaylistClock.minimumStay(intervalMinutes: 60), 30 * 60)
        XCTAssertEqual(PlaylistClock.minimumStay(intervalMinutes: 180), 30 * 60)
        XCTAssertEqual(PlaylistClock.minimumStay(intervalMinutes: 1440), 30 * 60)
    }

    /// A broken playlists.json must still give a time in the future, never a
    /// tight loop.
    func testIntervalsOutsideTheEditorsRangeAreClamped() {
        XCTAssertEqual(next("2026-11-19T03:07:40+05:30", every: 0), t("2026-11-19T03:09:00+05:30"))
        XCTAssertEqual(next("2026-11-19T03:07:40+05:30", every: -5), t("2026-11-19T03:09:00+05:30"))
        XCTAssertEqual(next("2026-11-19T14:00:00+05:30", every: 100_000), t("2026-11-20T00:00:00+05:30"))
    }

    // MARK: - The timer

    /// The timer fires on the mark and the wallpaper changes then; the next
    /// change is the next mark, not the same one again.
    func testAChangeOnTheMarkWaitsForTheNextMark() {
        XCTAssertEqual(next("2026-11-19T03:30:00.004+05:30", every: 30), t("2026-11-19T04:00:00+05:30"))
        XCTAssertEqual(next("2026-11-19T03:29:59.600+05:30", every: 30), t("2026-11-19T04:00:00+05:30"))
    }

    func testATimerASecondEarlyCountsAsOnTime() {
        XCTAssertTrue(due(shown: "2026-11-19T03:00:00+05:30", now: "2026-11-19T03:29:59.500+05:30", every: 30))
        XCTAssertFalse(due(shown: "2026-11-19T03:00:00+05:30", now: "2026-11-19T03:29:58+05:30", every: 30))
    }

    func testAClockTimeIsAtOrAfterNotStrictlyAfter() {
        let mark = t("2026-11-19T03:30:00+05:30")
        XCTAssertEqual(PlaylistClock.clockTime(atOrAfter: mark, intervalMinutes: 30, timeZone: colombo), mark)
    }

    // MARK: - Time zones

    /// Colombo is 5:30 ahead of GMT; its :00 is GMT's :30. The clock that
    /// counts is the Mac's own. The same moment, 3:07 in London and 8:37 in
    /// Colombo, changes at 4:00 in London and at 10:00 in Colombo (9:00 is
    /// only 23 minutes away there).
    func testTheMacsOwnClockCountsNotGMT() {
        let shown = t("2026-11-19T03:07:00Z")
        let london = TimeZone(identifier: "Europe/London")!
        XCTAssertEqual(
            PlaylistClock.nextChange(afterShownAt: shown, intervalMinutes: 60, timeZone: london),
            t("2026-11-19T04:00:00Z")
        )
        XCTAssertEqual(
            PlaylistClock.nextChange(afterShownAt: shown, intervalMinutes: 60, timeZone: colombo),
            t("2026-11-19T10:00:00+05:30")
        )
        XCTAssertEqual(
            PlaylistClock.nextChange(afterShownAt: t("2026-11-19T08:17:00+05:30"), intervalMinutes: 60, timeZone: colombo),
            t("2026-11-19T09:00:00+05:30")
        )
    }

    func testAQuarterHourTimeZone() {
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
        XCTAssertEqual(next("2026-11-19T03:07:00+05:45", every: 30, in: kathmandu), t("2026-11-19T03:30:00+05:45"))
    }

    // MARK: - Summer time

    /// New York, 8 March 2026: the clock jumps from 1:59 to 3:00. 2:00 and
    /// 2:30 never come; 3:00 does, 30 real minutes after 1:30.
    func testSpringForwardSkipsTheMissingHalfHours() {
        XCTAssertEqual(next("2026-03-08T01:00:00-05:00", every: 30, in: newYork), t("2026-03-08T01:30:00-05:00"))
        XCTAssertEqual(next("2026-03-08T01:30:00-05:00", every: 30, in: newYork), t("2026-03-08T03:00:00-04:00"))
        XCTAssertEqual(next("2026-03-08T03:00:00-04:00", every: 30, in: newYork), t("2026-03-08T03:30:00-04:00"))
        XCTAssertEqual(next("2026-03-08T01:20:00-05:00", every: 60, in: newYork), t("2026-03-08T03:00:00-04:00"))
    }

    /// New York, 1 November 2026: the clock goes from 1:59 back to 1:00, so
    /// 1:00 and 1:30 come twice, and so do their changes.
    func testFallBackChangesInTheRepeatedHourToo() {
        XCTAssertEqual(next("2026-11-01T01:00:00-04:00", every: 30, in: newYork), t("2026-11-01T01:30:00-04:00"))
        XCTAssertEqual(next("2026-11-01T01:30:00-04:00", every: 30, in: newYork), t("2026-11-01T01:00:00-05:00"))
        XCTAssertEqual(next("2026-11-01T01:00:00-05:00", every: 30, in: newYork), t("2026-11-01T01:30:00-05:00"))
        XCTAssertEqual(next("2026-11-01T01:30:00-05:00", every: 30, in: newYork), t("2026-11-01T02:00:00-05:00"))
        XCTAssertEqual(next("2026-11-01T01:00:00-04:00", every: 60, in: newYork), t("2026-11-01T01:00:00-05:00"))
        XCTAssertEqual(next("2026-11-01T01:00:00-05:00", every: 60, in: newYork), t("2026-11-01T02:00:00-05:00"))
    }

    /// Lord Howe Island moves its clock by half an hour, 4 October 2026: 1:59
    /// then 2:30. The 2:00 change happens at the jump, an hour after 1:00.
    func testAHalfHourJumpChangesAtTheJump() {
        XCTAssertEqual(next("2026-10-04T01:00:00+10:30", every: 60, in: lordHowe), t("2026-10-04T02:30:00+11:00"))
        XCTAssertEqual(next("2026-10-04T01:30:00+10:30", every: 30, in: lordHowe), t("2026-10-04T02:30:00+11:00"))
    }

    /// Lord Howe Island, 5 April 2026: 1:59 then 1:30, so 1:30 comes twice.
    func testAHalfHourFallBack() {
        XCTAssertEqual(next("2026-04-05T01:30:00+11:00", every: 30, in: lordHowe), t("2026-04-05T01:30:00+10:30"))
    }

    /// Havana skips midnight itself, 8 March 2026: 23:59 then 1:00. A daily
    /// playlist still changes that night, at 1:00, instead of losing a day.
    func testADailyPlaylistStillChangesWhenMidnightIsSkipped() {
        XCTAssertEqual(next("2026-03-07T12:00:00-05:00", every: 1440, in: havana), t("2026-03-08T01:00:00-04:00"))
    }

    // MARK: - Against a plain minute by minute search

    /// Thousands of moments, in zones with every kind of clock change, against
    /// the slowest possible answer: walk forward a minute at a time until the
    /// clock reads a change time. The fast answer must be that, or the moment
    /// the clock jumps past one.
    func testAgreesWithAMinuteByMinuteSearch() {
        let zones = [
            "Asia/Colombo", "America/New_York", "Europe/London", "Europe/Berlin", "Australia/Lord_Howe",
            "America/Havana", "Asia/Kathmandu", "Pacific/Chatham", "America/Sao_Paulo", "Pacific/Kiritimati",
        ].map { TimeZone(identifier: $0)! }
        let intervals = [1, 2, 7, 10, 15, 20, 30, 45, 60, 90, 120, 180, 1440]
        let yearStart = t("2026-01-01T00:00:00Z").timeIntervalSince1970
        var random = SeededRandom(seed: 0x6d75726f)
        var checked = 0

        for zone in zones {
            // Around every clock change of the year, and at random moments.
            var moments: [Double] = []
            var cursor = Date(timeIntervalSince1970: yearStart)
            while let change = zone.nextDaylightSavingTimeTransition(after: cursor),
                  change.timeIntervalSince1970 < yearStart + 366 * 86_400 {
                for minutes in stride(from: -200, through: 200, by: 17) {
                    moments.append(change.timeIntervalSince1970 + Double(minutes) * 60 + 7)
                }
                cursor = change
            }
            for _ in 0..<30 {
                moments.append(yearStart + Double(random.next() % (365 * 86_400)) + Double(random.next() % 1000) / 1000)
            }

            for interval in intervals {
                let sample = interval == 1440 ? moments.filter { _ in random.next() % 8 == 0 } : moments
                for moment in sample {
                    let shown = Date(timeIntervalSince1970: moment)
                    let answer = PlaylistClock.nextChange(afterShownAt: shown, intervalMinutes: interval, timeZone: zone)
                    let earliest = shown.addingTimeInterval(PlaylistClock.minimumStay(intervalMinutes: interval))
                    XCTAssertGreaterThanOrEqual(answer, earliest, "\(zone.identifier) every \(interval) from \(shown)")

                    let slow = firstClockTimeBySearching(from: earliest, upTo: answer, every: interval, zone: zone)
                    if slow != answer {
                        // No change time the clock shows may come before the
                        // answer, and an answer earlier than all of them is
                        // only right as the moment the clock jumps past one.
                        XCTAssertNil(slow, "\(zone.identifier) every \(interval) from \(shown): \(String(describing: slow)) comes before \(answer)")
                        let before = zone.secondsFromGMT(for: answer.addingTimeInterval(-1))
                        let after = zone.secondsFromGMT(for: answer)
                        XCTAssertGreaterThan(after, before, "\(zone.identifier) every \(interval) from \(shown): \(answer) is no change time")
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 5_000)
    }

    /// The first whole minute from `start` on whose wall clock reading the
    /// playlist changes, or nil when none comes before `limit`.
    private func firstClockTimeBySearching(from start: Date, upTo limit: Date, every interval: Int, zone: TimeZone) -> Date? {
        var minute = (start.timeIntervalSince1970 / 60).rounded(.up) * 60
        while minute <= limit.timeIntervalSince1970 {
            let reading = minute + Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: minute)))
            let minuteOfDay = Int(reading.truncatingRemainder(dividingBy: 86_400) / 60)
            let wrapped = minuteOfDay < 0 ? minuteOfDay + 1440 : minuteOfDay
            if wrapped % interval == 0 { return Date(timeIntervalSince1970: minute) }
            minute += 60
        }
        return nil
    }
}

/// Repeatable randomness, so a failure can be run again.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: (state >> 33) & 0x7fff_ffff)
    }
}

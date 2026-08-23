import XCTest
@testable import MuroKit

final class AutomationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func clock(_ windows: [(String, Int, Int)]) -> Automation {
        Automation(
            name: "Day",
            mode: .clock,
            steps: windows.map { Automation.Step(wallpaperID: $0.0, startMinute: $0.1, endMinute: $0.2) }
        )
    }

    // MARK: - Storage

    func testAutomationRoundTrip() throws {
        let automations = [
            Automation(name: "Morning", mode: .timer, steps: [
                .init(wallpaperID: "a", seconds: 10),
                .init(wallpaperID: "b", seconds: 7200),
            ]),
            clock([("c", 420, 480)]),
        ]
        try AutomationStore.save(automations, root: root)
        let loaded = AutomationStore.load(root: root)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].mode, .timer)
        XCTAssertEqual(loaded[0].steps.map(\.seconds), [10, 7200])
        XCTAssertEqual(loaded[1].mode, .clock)
        XCTAssertEqual(loaded[1].steps[0].startMinute, 420)
    }

    func testMissingAutomationsFileLoadsAsEmpty() {
        XCTAssertTrue(AutomationStore.load(root: root).isEmpty)
    }

    // MARK: - Timer mode

    func testCycleLengthIsTheSumOfTheSteps() {
        let automation = Automation(name: "Mix", mode: .timer, steps: [
            .init(wallpaperID: "a", seconds: 10),
            .init(wallpaperID: "b", seconds: 1200),
            .init(wallpaperID: "c", seconds: 7200),
        ])
        XCTAssertEqual(automation.cycleSeconds, 8410)
        XCTAssertEqual(durationLabel(8410), "2 h 20 min")
    }

    /// A step with nothing set, or something absurd, must not be able to make
    /// the scheduler fire in a tight loop or never at all.
    func testDurationsAreClampedToSomethingRunnable() {
        XCTAssertEqual(Automation.Step(wallpaperID: "a", seconds: 0).duration, 10)
        XCTAssertEqual(Automation.Step(wallpaperID: "a", seconds: -5).duration, 10)
        XCTAssertEqual(Automation.Step(wallpaperID: "a").duration, 600)
        XCTAssertEqual(Automation.Step(wallpaperID: "a", seconds: 999_999).duration, 86_400)
    }

    // MARK: - Clock mode

    func testTheRightWallpaperIsPickedForATimeOfDay() {
        // 07:00 to 20:00, then 20:00 to 21:00.
        let automation = clock([("morning", 420, 1200), ("evening", 1200, 1260)])
        XCTAssertEqual(automation.clockStep(at: 420)?.wallpaperID, "morning")
        XCTAssertEqual(automation.clockStep(at: 1199)?.wallpaperID, "morning")
        XCTAssertEqual(automation.clockStep(at: 1200)?.wallpaperID, "evening")
        XCTAssertEqual(automation.clockStep(at: 1259)?.wallpaperID, "evening")
        // 21:00 to 07:00 is a gap: nothing matches, so what plays keeps playing.
        XCTAssertNil(automation.clockStep(at: 1260))
        XCTAssertNil(automation.clockStep(at: 60))
    }

    /// 22:00 to 06:00 is one window, not a negative one.
    func testAWindowCanRunPastMidnight() {
        let night = Automation.Step(wallpaperID: "night", startMinute: 1320, endMinute: 360)
        XCTAssertEqual(night.clockLength, 480)
        XCTAssertTrue(night.covers(minute: 1380))
        XCTAssertTrue(night.covers(minute: 0))
        XCTAssertTrue(night.covers(minute: 359))
        XCTAssertFalse(night.covers(minute: 360))
        XCTAssertFalse(night.covers(minute: 720))
    }

    func testOverlapIsResolvedByOrder() {
        let automation = clock([("first", 0, 1440), ("second", 600, 700)])
        XCTAssertEqual(automation.clockStep(at: 650)?.wallpaperID, "first")
    }

    /// 21:00 to 07:00 is one gap. Reported as two it would read "00:00 to
    /// 07:00" and "21:00 to 00:00", which is not how anyone says it.
    func testAGapOverMidnightIsReportedAsOne() {
        let automation = clock([("morning", 420, 1200), ("evening", 1200, 1260)])
        let gaps = automation.uncoveredWindows
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 1260)
        XCTAssertEqual(gaps[0].end, 420)
        XCTAssertTrue(clock([("all", 0, 1440)]).uncoveredWindows.isEmpty, "a full day has no gaps")
    }

    /// The same from and to time is the only way to say "always this one".
    func testTheSameStartAndEndMeansAllDay() {
        let always = Automation.Step(wallpaperID: "a", startMinute: 540, endMinute: 540)
        XCTAssertEqual(always.clockLength, 1440)
        XCTAssertTrue(always.covers(minute: 0))
        XCTAssertTrue(always.covers(minute: 539))
        XCTAssertTrue(always.covers(minute: 1439))
    }

    /// The scheduler sets one timer for a whole day's schedule, so the next
    /// boundary has to be right or the wallpaper changes at the wrong time.
    func testTheNextBoundaryIsTheNearestEdgeAhead() {
        let automation = clock([("morning", 420, 1200), ("evening", 1200, 1260)])
        XCTAssertEqual(automation.minutesToNextBoundary(from: 400), 20)
        XCTAssertEqual(automation.minutesToNextBoundary(from: 420), 780)
        XCTAssertEqual(automation.minutesToNextBoundary(from: 1210), 50)
        // Past the last window, the next edge is tomorrow morning.
        XCTAssertEqual(automation.minutesToNextBoundary(from: 1300), 560)
    }

    // MARK: - Deleted wallpapers

    func testDeletedWallpapersLeaveNoStepsBehind() {
        let automations = [
            Automation(name: "Mixed", mode: .timer, steps: [
                .init(wallpaperID: "a", seconds: 10),
                .init(wallpaperID: "b", seconds: 10),
            ]),
            Automation(name: "Doomed", mode: .timer, steps: [.init(wallpaperID: "a", seconds: 10)]),
        ]
        let result = AutomationStore.pruned(automations, removing: ["a"])
        XCTAssertEqual(result.automations[0].steps.map(\.wallpaperID), ["b"])
        XCTAssertTrue(result.automations[1].steps.isEmpty)
        XCTAssertEqual(result.emptied.count, 1)
    }

    // MARK: - Labels

    func testDurationLabels() {
        XCTAssertEqual(durationLabel(10), "10 s")
        XCTAssertEqual(durationLabel(60), "1 min")
        XCTAssertEqual(durationLabel(90), "1 min 30 s")
        XCTAssertEqual(durationLabel(3600), "1 h")
        XCTAssertEqual(durationLabel(9000), "2 h 30 min")
    }

    func testMinutesWrapInsteadOfGoingNegative() {
        XCTAssertEqual(normalizedMinute(-15), 1425)
        XCTAssertEqual(normalizedMinute(1440), 0)
        XCTAssertEqual(normalizedMinute(1500), 60)
    }
}

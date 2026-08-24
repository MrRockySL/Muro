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

// MARK: - Fitting a clock schedule to the day

final class AutomationFitTests: XCTestCase {
    private func steps(_ count: Int) -> [Automation.Step] {
        (0..<count).map { Automation.Step(wallpaperID: "w\($0)") }
    }

    private func gaps(_ fitted: [Automation.Step]) -> Int {
        Automation(name: "t", mode: .clock, steps: fitted).uncoveredWindows.count
    }

    func testOneWallpaperCoversTheWholeDay() {
        let fitted = Automation.fittedToDay(steps(1))
        XCTAssertEqual(fitted.count, 1)
        XCTAssertTrue(Automation.isAllDay(fitted[0]))
        XCTAssertEqual(gaps(fitted), 0)
    }

    func testTwoWallpapersSplitTheDayInHalf() {
        let fitted = Automation.fittedToDay(steps(2))
        XCTAssertEqual(fitted[0].start, 0)
        XCTAssertEqual(fitted[0].end, 720)
        XCTAssertEqual(fitted[1].start, 720)
        XCTAssertEqual(fitted[1].end, 0)
        XCTAssertEqual(gaps(fitted), 0)
    }

    func testThreeWallpapersTakeEightHoursEach() {
        let fitted = Automation.fittedToDay(steps(3))
        XCTAssertEqual(fitted.map(\.start), [0, 480, 960])
        XCTAssertEqual(gaps(fitted), 0)
    }

    /// The counts that do not divide 1440 evenly are the ones that would leave
    /// a hole if the remainder were dropped.
    func testAnyCountStillCoversTheWholeDay() {
        for count in 1...12 {
            let fitted = Automation.fittedToDay(steps(count))
            XCTAssertEqual(gaps(fitted), 0, "\(count) wallpapers left a gap")
            XCTAssertEqual(Set(fitted.map(\.wallpaperID)).count, count)
        }
    }

    /// Nothing may sit on top of anything else, at any count.
    func testNothingOverlaps() {
        for count in 2...12 {
            let fitted = Automation.fittedToDay(steps(count))
            var owner = [String?](repeating: nil, count: 1440)
            for step in fitted {
                let length = Automation.isAllDay(step) ? 1440 : step.clockLength
                for offset in 0..<length {
                    let minute = (step.start + offset) % 1440
                    XCTAssertNil(owner[minute], "\(count) wallpapers overlap at minute \(minute)")
                    owner[minute] = step.wallpaperID
                }
            }
        }
    }

    func testFittingKeepsOrderAndWallpapers() {
        let original = steps(4)
        let fitted = Automation.fittedToDay(original)
        XCTAssertEqual(fitted.map(\.wallpaperID), original.map(\.wallpaperID))
    }
}

// MARK: - Adding to and removing from a clock schedule

final class AutomationAddRemoveTests: XCTestCase {
    private func step(_ id: String, _ start: Int? = nil, _ end: Int? = nil) -> Automation.Step {
        Automation.Step(wallpaperID: id, startMinute: start, endMinute: end)
    }

    private func gaps(_ steps: [Automation.Step]) -> [(start: Int, end: Int)] {
        Automation(name: "t", mode: .clock, steps: steps).uncoveredWindows
    }

    func testFirstWallpaperTakesTheWholeDay() {
        let result = Automation.fittedAdding(step("a"), to: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(Automation.isAllDay(result[0]))
    }

    /// The report that started this: one wallpaper owning the whole day, and
    /// nowhere for a second one to go.
    func testAddingToAFullDaySplitsIt() {
        let one = Automation.fittedAdding(step("a"), to: [])
        let two = Automation.fittedAdding(step("b"), to: one)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.map(\.start), [0, 720])
        XCTAssertTrue(gaps(two).isEmpty)

        let three = Automation.fittedAdding(step("c"), to: two)
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(three.map(\.start), [0, 480, 960])
        XCTAssertTrue(gaps(three).isEmpty)
    }

    /// His example: 00:00 to 03:00 and 03:00 to 09:00 arranged by hand, with
    /// 09:00 to 24:00 still empty. A third wallpaper belongs in the empty part
    /// and the first two must not move.
    func testAddingFillsTheGapAndLeavesTheArrangementAlone() {
        let arranged = [step("a", 0, 180), step("b", 180, 540)]
        let result = Automation.fittedAdding(step("c"), to: arranged)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 180)
        XCTAssertEqual(result[1].start, 180)
        XCTAssertEqual(result[1].end, 540)
        XCTAssertEqual(result[2].start, 540)
        XCTAssertEqual(result[2].end, 0)
        XCTAssertTrue(gaps(result).isEmpty)
    }

    func testAddingTakesTheLargestGapWhenThereAreSeveral() {
        // Free: 02:00 to 05:00 (180) and 08:00 to 20:00 (720).
        let arranged = [step("a", 0, 120), step("b", 300, 480), step("c", 1200, 0)]
        let result = Automation.fittedAdding(step("d"), to: arranged)
        XCTAssertEqual(result.last?.start, 480)
        XCTAssertEqual(result.last?.end, 1200)
    }

    func testAddingAcrossMidnightGap() {
        // The only window is 06:00 to 09:00, so the gap wraps midnight.
        let arranged = [step("a", 360, 540)]
        let result = Automation.fittedAdding(step("b"), to: arranged)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].start, 540)
        XCTAssertEqual(result[1].end, 360)
        XCTAssertTrue(gaps(result).isEmpty)
    }

    func testRemovingLeavesTheOthersWhereTheyWere() {
        let arranged = [step("a", 0, 180), step("b", 180, 540), step("c", 540, 0)]
        let result = Automation.fittedRemoving(arranged[1], from: arranged)
        XCTAssertEqual(result.map(\.wallpaperID), ["a", "c"])
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 540)
        XCTAssertEqual(result[1].start, 540)
        XCTAssertTrue(gaps(result).isEmpty)
    }

    func testRemovingDownToOneGivesItTheWholeDay() {
        let arranged = [step("a", 0, 720), step("b", 720, 0)]
        let result = Automation.fittedRemoving(arranged[1], from: arranged)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(Automation.isAllDay(result[0]))
    }

    /// His drag: two wallpapers, second pulled above the first. The hours
    /// belong to the rows, so the wallpapers swap slots and the day is drawn
    /// the other way round.
    func testReorderingCarriesTheSlotsNotTheTimes() {
        let arranged = [step("a", 0, 720), step("b", 720, 0)]
        let result = Automation.reordered(arranged, from: 1, to: 0, carryingSlots: true)
        XCTAssertEqual(result.map(\.wallpaperID), ["b", "a"])
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 720)
        XCTAssertEqual(result[1].start, 720)
        XCTAssertEqual(result[1].end, 0)
        XCTAssertTrue(gaps(result).isEmpty)
    }

    func testReorderingThreeKeepsEverySlotInPlace() {
        let arranged = [step("a", 0, 180), step("b", 180, 540), step("c", 540, 0)]
        let result = Automation.reordered(arranged, from: 2, to: 0, carryingSlots: true)
        XCTAssertEqual(result.map(\.wallpaperID), ["c", "a", "b"])
        XCTAssertEqual(result.map(\.start), [0, 180, 540])
        XCTAssertTrue(gaps(result).isEmpty)
    }

    /// Timer mode has no slots: a wallpaper keeps its own length wherever it
    /// lands in the order.
    func testReorderingWithoutSlotsKeepsEachWallpapersOwnTimes() {
        let arranged = [step("a", 0, 720), step("b", 720, 0)]
        let result = Automation.reordered(arranged, from: 1, to: 0, carryingSlots: false)
        XCTAssertEqual(result.map(\.wallpaperID), ["b", "a"])
        XCTAssertEqual(result[0].start, 720)
        XCTAssertEqual(result[1].start, 0)
    }

    func testReorderingOutOfRangeChangesNothing() {
        let arranged = [step("a", 0, 720), step("b", 720, 0)]
        XCTAssertEqual(
            Automation.reordered(arranged, from: 0, to: 0, carryingSlots: true).map(\.wallpaperID),
            ["a", "b"]
        )
        XCTAssertEqual(
            Automation.reordered(arranged, from: 5, to: 0, carryingSlots: true).map(\.wallpaperID),
            ["a", "b"]
        )
    }

    func testAddingThenRemovingReturnsTheDayToOneWallpaper() {
        var steps = Automation.fittedAdding(step("a"), to: [])
        steps = Automation.fittedAdding(step("b"), to: steps)
        steps = Automation.fittedRemoving(steps[1], from: steps)
        XCTAssertEqual(steps.map(\.wallpaperID), ["a"])
        XCTAssertTrue(Automation.isAllDay(steps[0]))
    }
}

// MARK: - Names

final class UniqueNameTests: XCTestCase {
    func testFirstOneKeepsThePlainName() {
        XCTAssertEqual(uniqueName(base: "New Playlist", taken: []), "New Playlist")
        XCTAssertEqual(uniqueName(base: "New Playlist", taken: ["Evening"]), "New Playlist")
    }

    func testTheSecondOneIsNumbered() {
        XCTAssertEqual(uniqueName(base: "New Playlist", taken: ["New Playlist"]), "New Playlist 2")
        XCTAssertEqual(
            uniqueName(base: "New Playlist", taken: ["New Playlist", "New Playlist 2"]),
            "New Playlist 3"
        )
    }

    /// A gap is filled rather than skipped past.
    func testItTakesTheFirstFreeNumber() {
        XCTAssertEqual(
            uniqueName(base: "New Playlist", taken: ["New Playlist", "New Playlist 3"]),
            "New Playlist 2"
        )
    }

    func testCaseAndSpacingDoNotMakeANameFree() {
        XCTAssertEqual(uniqueName(base: "New Playlist", taken: ["  new playlist "]), "New Playlist 2")
    }

    func testTakenIgnoresCaseAndSpacing() {
        let existing = [(id: "a", name: "Evening"), (id: "b", name: "Morning")]
        XCTAssertTrue(nameIsTaken("evening", in: existing, excluding: nil))
        XCTAssertTrue(nameIsTaken("  Evening  ", in: existing, excluding: nil))
        XCTAssertFalse(nameIsTaken("Night", in: existing, excluding: nil))
    }

    /// Editing a playlist without renaming it must not report its own name as
    /// taken.
    func testARowDoesNotClashWithItself() {
        let existing = [(id: "a", name: "Evening"), (id: "b", name: "Morning")]
        XCTAssertFalse(nameIsTaken("Evening", in: existing, excluding: "a"))
        XCTAssertTrue(nameIsTaken("Morning", in: existing, excluding: "a"))
    }

    func testAnEmptyNameIsNotAClash() {
        XCTAssertFalse(nameIsTaken("   ", in: [(id: "a", name: "Evening")], excluding: nil))
    }
}

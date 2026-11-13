import XCTest
@testable import MuroKit

/// The line muro:// links wait in. One at a time and in order is what keeps
/// two lock screen links from writing over each other, and what makes `set`
/// followed by `pause` end paused.
@MainActor
final class MuroLinkQueueTests: XCTestCase {
    /// What the queue did, in order, and how many links it ever carried out
    /// at the same moment.
    private final class Record {
        var events: [String] = []
        var atOnce = 0
        var mostAtOnce = 0
    }

    /// A queue whose links each take a moment, the way setting a lock screen
    /// does, so that two of them would overlap if anything let them.
    private func queue(limit: Int = 16, into record: Record) -> MuroLinkQueue<String> {
        MuroLinkQueue(limit: limit) { link in
            record.atOnce += 1
            record.mostAtOnce = max(record.mostAtOnce, record.atOnce)
            record.events.append("start \(link)")
            try? await Task.sleep(for: .milliseconds(20))
            record.events.append("end \(link)")
            record.atOnce -= 1
        }
    }

    private func finished(_ queue: MuroLinkQueue<String>) async {
        for _ in 0..<400 where !queue.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(queue.isEmpty, "the queue never finished")
    }

    func testLinksAreCarriedOutOneAtATimeInTheOrderTheyCame() async {
        let record = Record()
        let queue = queue(into: record)
        queue.start()
        for link in ["a", "b", "c"] { XCTAssertEqual(queue.add(link), .taken) }
        await finished(queue)
        XCTAssertEqual(record.events, ["start a", "end a", "start b", "end b", "start c", "end c"])
        XCTAssertEqual(record.mostAtOnce, 1)
    }

    func testLinksThatComeWhileMuroIsStartingWaitAndKeepTheirOrder() async {
        // A link that opens Muro from quit arrives before Muro can do
        // anything. `set` and then `pause` used to end playing.
        let record = Record()
        let queue = queue(into: record)
        queue.add("set")
        queue.add("pause")
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(record.events, [], "nothing is carried out before Muro has started")
        XCTAssertFalse(queue.isEmpty)
        queue.start()
        await finished(queue)
        XCTAssertEqual(record.events, ["start set", "end set", "start pause", "end pause"])
    }

    func testALinkThatComesWhileAnotherIsBeingCarriedOutWaitsForItToFinish() async {
        let record = Record()
        let queue = queue(into: record)
        queue.start()
        queue.add("lock screen 1")
        try? await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(record.events, ["start lock screen 1"])
        queue.add("lock screen 2")
        await finished(queue)
        XCTAssertEqual(record.events, [
            "start lock screen 1", "end lock screen 1",
            "start lock screen 2", "end lock screen 2",
        ])
        XCTAssertEqual(record.mostAtOnce, 1)
    }

    func testOnlySoManyLinksMayWait() async {
        let record = Record()
        let queue = queue(limit: 2, into: record)
        XCTAssertEqual(queue.add("a"), .taken)
        XCTAssertEqual(queue.add("b"), .taken)
        XCTAssertEqual(queue.add("c"), .full)
        XCTAssertEqual(queue.add("d"), .full)
        queue.start()
        await finished(queue)
        XCTAssertEqual(record.events, ["start a", "end a", "start b", "end b"])
    }

    func testTheLinkBeingCarriedOutIsNotCountedAsWaiting() async {
        let record = Record()
        let queue = queue(limit: 2, into: record)
        queue.start()
        XCTAssertEqual(queue.add("a"), .taken)
        XCTAssertEqual(queue.add("b"), .taken)
        XCTAssertEqual(queue.add("c"), .taken)
        XCTAssertEqual(queue.add("d"), .full)
        await finished(queue)
        XCTAssertEqual(record.events.filter { $0.hasPrefix("start") }, ["start a", "start b", "start c"])
    }

    func testThereIsRoomAgainOnceLinksHaveBeenCarriedOut() async {
        let record = Record()
        let queue = queue(limit: 1, into: record)
        queue.start()
        XCTAssertEqual(queue.add("a"), .taken)
        XCTAssertEqual(queue.add("b"), .taken)
        XCTAssertEqual(queue.add("c"), .full)
        await finished(queue)
        XCTAssertEqual(queue.add("c"), .taken)
        await finished(queue)
        XCTAssertEqual(record.events.filter { $0.hasPrefix("start") }, ["start a", "start b", "start c"])
    }

    func testALinkThatRepeatsTheOneInFrontOfItIsDropped() async {
        // A button pressed five times is one change, not five.
        let record = Record()
        let queue = queue(into: record)
        XCTAssertEqual(queue.add("a"), .taken)
        XCTAssertEqual(queue.add("a"), .alreadyWaiting)
        XCTAssertEqual(queue.add("a"), .alreadyWaiting)
        XCTAssertEqual(queue.add("b"), .taken)
        // Not a repeat of the one in front of it: `a`, `b`, `a` ends on `a`.
        XCTAssertEqual(queue.add("a"), .taken)
        queue.start()
        await finished(queue)
        XCTAssertEqual(record.events.filter { $0.hasPrefix("start") }, ["start a", "start b", "start a"])
    }

    func testARepeatOfTheLinkBeingCarriedOutStillWaits() async {
        // That one is half done and may yet fail, so the repeat is kept.
        let record = Record()
        let queue = queue(into: record)
        queue.start()
        XCTAssertEqual(queue.add("a"), .taken)
        XCTAssertEqual(queue.add("a"), .taken)
        await finished(queue)
        XCTAssertEqual(record.events, ["start a", "end a", "start a", "end a"])
    }
}

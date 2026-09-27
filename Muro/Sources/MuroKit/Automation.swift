import Foundation

/// A schedule of wallpapers. Where a playlist rotates on one fixed interval,
/// an automation gives every wallpaper its own duration, or its own slot on
/// the clock.
///
/// Stored as automations.json beside playlists.json in the library root.
public struct Automation: Codable, Identifiable, Equatable {
    public enum Mode: String, Codable, CaseIterable {
        /// Wallpaper 1 for 10 seconds, wallpaper 2 for 20 minutes, then back
        /// to the top. Per wallpaper duration.
        case timer
        /// Wallpaper 1 from 07:00 to 20:00, wallpaper 2 from 20:00 to 21:00,
        /// repeating daily. Windows may wrap past midnight.
        case clock
    }

    /// One wallpaper's place in the schedule. `seconds` is used in timer mode,
    /// the two minute marks in clock mode; the unused pair simply stays nil so
    /// switching a mode back and forth never loses what was typed.
    public struct Step: Codable, Identifiable, Equatable {
        public var id: String
        public var wallpaperID: String
        public var seconds: Int?
        public var startMinute: Int?
        public var endMinute: Int?

        public init(
            id: String = UUID().uuidString.lowercased(),
            wallpaperID: String,
            seconds: Int? = nil,
            startMinute: Int? = nil,
            endMinute: Int? = nil
        ) {
            self.id = id
            self.wallpaperID = wallpaperID
            self.seconds = seconds
            self.startMinute = startMinute
            self.endMinute = endMinute
        }

        /// Clamped to something the scheduler can actually run: 10 seconds is
        /// the shortest useful step, 24 hours the longest meaningful one.
        public var duration: Int { min(max(seconds ?? 600, 10), 86_400) }
        public var start: Int { normalizedMinute(startMinute ?? 0) }
        public var end: Int { normalizedMinute(endMinute ?? 0) }

        /// Length of a clock window in minutes, counting a wrap past midnight
        /// (22:00 to 06:00 is 480, not a negative number).
        public var clockLength: Int {
            let span = end - start
            return span > 0 ? span : span + 1440
        }

        /// Whether `minute` falls inside this window.
        ///
        /// The same from and to time means the whole day, not nothing. A
        /// window of zero length would be useless, and setting both ends the
        /// same is the only way the editor can say "this one, always", which
        /// is also what `clockLength` already reports.
        public func covers(minute: Int) -> Bool {
            let now = normalizedMinute(minute)
            guard start != end else { return true }
            return start < end
                ? (now >= start && now < end)
                : (now >= start || now < end)
        }

        /// Minutes from `minute` until this window opens, 0 if it is open now.
        public func minutesUntilStart(from minute: Int) -> Int {
            let delta = start - minute
            return delta >= 0 ? delta : delta + 1440
        }
    }

    public var id: String
    public var name: String
    public var mode: Mode
    public var steps: [Step]
    public var enabled: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        mode: Mode = .timer,
        steps: [Step] = [],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.steps = steps
        self.enabled = enabled
    }

    /// How long one full pass through a timer automation takes.
    public var cycleSeconds: Int {
        steps.reduce(0) { $0 + $1.duration }
    }

    /// Gaps in a clock schedule, as (fromMinute, toMinute) pairs. A gap is not
    /// an error: whatever was playing simply stays. The editor shows them so a
    /// loose schedule is a choice rather than a surprise.
    public var uncoveredWindows: [(start: Int, end: Int)] {
        guard mode == .clock, !steps.isEmpty else { return [] }
        var covered = [Bool](repeating: false, count: 1440)
        for step in steps {
            for offset in 0..<step.clockLength {
                covered[(step.start + offset) % 1440] = true
            }
        }
        var gaps: [(start: Int, end: Int)] = []
        var minute = 0
        while minute < 1440 {
            guard !covered[minute] else { minute += 1; continue }
            let start = minute
            while minute < 1440 && !covered[minute] { minute += 1 }
            gaps.append((start, minute % 1440))
        }
        // A gap that runs over midnight is one gap. Reported as two, an
        // evening schedule would say "00:00 to 07:00" and "21:00 to 00:00"
        // instead of the "21:00 to 07:00" a person would say out loud.
        if gaps.count > 1, gaps[0].start == 0, gaps[gaps.count - 1].end == 0 {
            let tail = gaps.removeLast()
            gaps[0] = (start: tail.start, end: gaps[0].end)
        }
        return gaps
    }

    /// Minutes until the next moment the answer could change: the nearest
    /// window edge ahead. The scheduler sets one timer from this, so a whole
    /// day's schedule costs one wake rather than one per window.
    ///
    /// Never zero, so a boundary that has just passed cannot spin the timer.
    public func minutesToNextBoundary(from minute: Int) -> Int {
        var best = 1440
        for step in steps where step.start != step.end {
            for boundary in [step.start, step.end] {
                let delta = boundary - normalizedMinute(minute)
                best = min(best, delta > 0 ? delta : delta + 1440)
            }
        }
        return max(1, best)
    }

    /// The step that should be showing at `minute` of the day. First match
    /// wins on overlap, which is the rule the editor states.
    public func clockStep(at minute: Int) -> Step? {
        steps.first { $0.covers(minute: minute) }
    }
}

public enum AutomationStore {
    public static func url(root: URL) -> URL {
        root.appendingPathComponent("automations.json")
    }

    public static func load(root: URL) -> [Automation] {
        guard let data = try? Data(contentsOf: url(root: root)) else { return [] }
        return (try? JSONDecoder().decode([Automation].self, from: data)) ?? []
    }

    public static func save(_ automations: [Automation], root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(automations).write(to: url(root: root), options: .atomic)
    }

    /// Same job as `PlaylistStore.pruned`: a deleted wallpaper must not be
    /// left behind as a step pointing at a file that is gone.
    public static func pruned(
        _ automations: [Automation],
        removing ids: Set<String>
    ) -> (automations: [Automation], emptied: [String]) {
        var emptied: [String] = []
        let out = automations.map { automation -> Automation in
            var copy = automation
            copy.steps.removeAll { ids.contains($0.wallpaperID) }
            if copy.steps.isEmpty, !automation.steps.isEmpty { emptied.append(automation.id) }
            return copy
        }
        return (out, emptied)
    }
}

/// Minutes of the day, wrapped into 0 ..< 1440.
public func normalizedMinute(_ minute: Int) -> Int {
    let wrapped = minute % 1440
    return wrapped < 0 ? wrapped + 1440 : wrapped
}

/// "07:00", "20:30" in the user's own clock format.
public func clockLabel(_ minute: Int) -> String {
    var components = DateComponents()
    components.hour = normalizedMinute(minute) / 60
    components.minute = normalizedMinute(minute) % 60
    let calendar = Calendar.current
    guard let date = calendar.date(from: components) else { return "00:00" }
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: date)
}

/// "10 s", "5 min", "2 h", "1 h 30 min".
public func durationLabel(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) s" }
    if seconds < 3600 {
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
}

public extension Automation {
    /// Lays a clock schedule end to end across the day, in list order, in equal
    /// slices.
    ///
    /// Adding a wallpaper to a full day used to drop it on top of whatever was
    /// already there, because a new step arrived with no times of its own and
    /// the seeding only filled in the ones that were missing. A schedule is
    /// supposed to describe a whole day, so every time the set of wallpapers
    /// changes the day is divided again: two get twelve hours each, three get
    /// eight, five get four and a half. Nothing overlaps, and nothing is left
    /// uncovered, whatever the count.
    ///
    /// One wallpaper is stored as the same start and end, which this type
    /// already reads as all day.
    ///
    /// A count that does not divide 1440 evenly leaves its remainder on the
    /// last window rather than spreading a rounding error through all of them.
    static func fittedToDay(_ steps: [Step]) -> [Step] {
        guard steps.count > 1 else {
            guard var only = steps.first else { return steps }
            only.startMinute = 0
            only.endMinute = 0
            return [only]
        }
        let slice = 1440 / steps.count
        return steps.enumerated().map { index, step in
            var copy = step
            copy.startMinute = index * slice
            copy.endMinute = index == steps.count - 1 ? 0 : (index + 1) * slice
            return copy
        }
    }

    /// Whether a step is the whole day, which is the one window with no edge
    /// to drag.
    static func isAllDay(_ step: Step) -> Bool { step.start == step.end }

    /// Where a wallpaper goes when it is added to a clock schedule.
    ///
    /// Two different things are wanted here and they only look like one.
    ///
    /// **If the day still has room**, the new window takes the largest free
    /// run and nothing that was already arranged moves. Someone who set one
    /// wallpaper to 00:00 to 03:00 and another to 03:00 to 09:00 and then adds
    /// a third means it to land in the 09:00 to 24:00 that is still empty.
    /// Re-dividing at that point would throw away the arrangement they just
    /// made in order to make room that was already there.
    ///
    /// **If the day is already full** there is no room to take, so the only
    /// way to add anything is to divide the day again: one wallpaper becomes
    /// two halves, two become three thirds. Adding always works, whatever the
    /// day looks like; a full day used to mean the new window had nowhere to
    /// go and effectively did not arrive.
    static func fittedAdding(_ step: Step, to steps: [Step]) -> [Step] {
        guard !steps.isEmpty else { return fittedToDay([step]) }
        let existing = Automation(name: "", mode: .clock, steps: steps)
        let widest = existing.uncoveredWindows
            .map { gap -> (start: Int, length: Int) in
                let length = gap.end > gap.start
                    ? gap.end - gap.start
                    : gap.end + 1440 - gap.start
                return (gap.start, length)
            }
            .max { $0.length < $1.length }
        guard let widest, widest.length > 0 else {
            return fittedToDay(steps + [step])
        }
        var placed = step
        placed.startMinute = normalizedMinute(widest.start)
        placed.endMinute = normalizedMinute(widest.start + widest.length)
        return steps + [placed]
    }

    /// Moving a wallpaper up or down the list.
    ///
    /// In clock mode a slot belongs to the **place in the list**, not to the
    /// wallpaper sitting in it, so `carryingSlots` puts the moved wallpaper
    /// into the hours of the row it was dropped on and shuffles the others
    /// through the remaining rows. Dragging the second wallpaper above the
    /// first used to take its own hours up with it, which left the day drawn
    /// exactly as it was and made the drag look as though nothing had
    /// happened. In timer mode each wallpaper owns its own length, so the
    /// order is all that changes.
    static func reordered(_ steps: [Step], from: Int, to: Int, carryingSlots: Bool) -> [Step] {
        guard steps.indices.contains(from), steps.indices.contains(to), from != to else {
            return steps
        }
        let slots = steps.map { (start: $0.startMinute, end: $0.endMinute) }
        var moved = steps
        moved.insert(moved.remove(at: from), at: to)
        guard carryingSlots else { return moved }
        for index in moved.indices {
            moved[index].startMinute = slots[index].start
            moved[index].endMinute = slots[index].end
        }
        return moved
    }

    /// What a clock schedule looks like after one of its wallpapers is taken
    /// out.
    ///
    /// The freed minutes go to whichever window ended where the removed one
    /// started, so the day stays as covered as it was and nothing else moves.
    /// Dividing the day again would be the tidier answer and the wrong one: it
    /// would re-space windows that were placed by hand, as a consequence of an
    /// action that said nothing about them. With one wallpaper left there is
    /// nothing to arrange, so it takes the whole day.
    static func fittedRemoving(_ step: Step, from steps: [Step]) -> [Step] {
        var rest = steps.filter { $0.id != step.id }
        guard rest.count > 1 else { return fittedToDay(rest) }
        // A whole-day window overlapped everything, so there are no minutes to
        // hand back: what is left already owns what it owns.
        guard !isAllDay(step) else { return rest }
        if let index = rest.firstIndex(where: { !isAllDay($0) && $0.end == step.start }) {
            rest[index].endMinute = step.end
        }
        return rest
    }
}

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

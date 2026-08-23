import Foundation
import AppKit
import MuroKit

/// Runs one automation, and the playlist rotation too.
///
/// This replaces the old playlist timer rather than sitting beside it. That
/// timer counted ticks on the default run loop mode, so it stalled while a
/// menu was open, never fired across sleep, drifted, and forgot where it was
/// on every relaunch. All four are fixed here in one place:
///
/// - absolute deadlines held as a `Date`, never a tick count, so nothing drifts
/// - the timer is added in `.common` mode, so menus and scrolling cannot delay it
/// - it re-evaluates on wake, so sleeping through a step lands on the wallpaper
///   that should be showing now rather than the next one in the list
/// - where it is and when the step started are persisted, so quitting mid step
///   resumes in the right place
///
/// Only one schedule runs at a time. Starting a playlist stops any automation
/// and the other way round, because both drive the same one wallpaper.
@MainActor
final class AutomationScheduler {
    /// What the scheduler should apply, handed back to the store rather than
    /// applied here, so there is still exactly one place that sets wallpapers.
    var apply: ((String) -> Void)?
    var currentIDForOrdering: (() -> String?)?

    private(set) var automations: [Automation] = []
    private(set) var playlists: [Playlist] = []

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private(set) var activeAutomationID: String? {
        didSet { defaults.set(activeAutomationID, forKey: Keys.automation) }
    }
    private(set) var activePlaylistID: String? {
        didSet { defaults.set(activePlaylistID, forKey: Keys.playlist) }
    }
    private var stepIndex: Int {
        didSet { defaults.set(stepIndex, forKey: Keys.stepIndex) }
    }
    private var stepStartedAt: Date {
        didSet { defaults.set(stepStartedAt.timeIntervalSince1970, forKey: Keys.stepStarted) }
    }

    private enum Keys {
        static let automation = "activeAutomation"
        static let playlist = "activePlaylist"
        static let stepIndex = "automationStepIndex"
        static let stepStarted = "automationStepStartedAt"
    }

    init() {
        activeAutomationID = defaults.string(forKey: Keys.automation)
        activePlaylistID = defaults.string(forKey: Keys.playlist)
        stepIndex = defaults.integer(forKey: Keys.stepIndex)
        let stored = defaults.double(forKey: Keys.stepStarted)
        stepStartedAt = stored > 0 ? Date(timeIntervalSince1970: stored) : Date()

        // A Mac that slept through three steps must wake up showing the right
        // wallpaper, not carry on from where it dozed off.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        }
    }

    // MARK: - What is running

    var activeAutomation: Automation? {
        automations.first { $0.id == activeAutomationID }
    }

    var activePlaylist: Playlist? {
        playlists.first { $0.id == activePlaylistID }
    }

    var runningName: String? {
        activeAutomation?.name ?? activePlaylist?.name
    }

    /// Called whenever the library's schedules change on disk or in the app.
    func update(automations: [Automation], playlists: [Playlist]) {
        self.automations = automations
        self.playlists = playlists
        // A schedule that was edited, emptied or deleted while running must
        // not keep a stale timer alive.
        if activeAutomationID != nil, activeAutomation?.steps.isEmpty ?? true {
            stopAutomation()
        } else if activePlaylistID != nil, activePlaylist?.wallpaperIDs.isEmpty ?? true {
            stopPlaylist()
        } else {
            schedule()
        }
    }

    // MARK: - Start and stop

    func startAutomation(_ automation: Automation) {
        guard !automation.steps.isEmpty else { return }
        activePlaylistID = nil
        activeAutomationID = automation.id
        stepIndex = 0
        stepStartedAt = Date()
        applyCurrent(of: automation)
        schedule()
    }

    func stopAutomation() {
        activeAutomationID = nil
        cancelTimer()
    }

    func startPlaylist(_ playlist: Playlist) {
        guard !playlist.wallpaperIDs.isEmpty else { return }
        activeAutomationID = nil
        activePlaylistID = playlist.id
        stepIndex = 0
        stepStartedAt = Date()
        apply?(playlist.wallpaperIDs[0])
        schedule()
    }

    func stopPlaylist() {
        activePlaylistID = nil
        cancelTimer()
    }

    func stopEverything() {
        activeAutomationID = nil
        activePlaylistID = nil
        cancelTimer()
    }

    /// Manual step, used by the menu bar's next/previous.
    func advancePlaylist(forward: Bool) {
        guard let playlist = activePlaylist else { return }
        let ids = playlist.wallpaperIDs
        guard !ids.isEmpty else { return }
        if playlist.shuffle {
            apply?(ids.filter { $0 != currentIDForOrdering?() }.randomElement() ?? ids[0])
        } else {
            let current = currentIDForOrdering?().flatMap { ids.firstIndex(of: $0) } ?? 0
            let step = forward ? 1 : ids.count - 1
            apply?(ids[(current + step) % ids.count])
        }
        stepStartedAt = Date()
        schedule()
    }

    // MARK: - The clock

    /// Works out what should be showing now and when to wake up next. Called
    /// on every start, edit, fire and wake, so there is one path and it is
    /// always driven by absolute time.
    private func reevaluate() {
        if let automation = activeAutomation {
            switch automation.mode {
            case .clock:
                applyCurrent(of: automation)
            case .timer:
                // Catch up through however many steps elapsed while asleep,
                // rather than stepping once and being wrong all day.
                var elapsed = Date().timeIntervalSince(stepStartedAt)
                var guardCount = 0
                let total = Double(automation.cycleSeconds)
                if total > 0, elapsed > total {
                    // Whole cycles are irrelevant, only the remainder matters.
                    elapsed = elapsed.truncatingRemainder(dividingBy: total)
                    stepStartedAt = Date().addingTimeInterval(-elapsed)
                }
                while elapsed >= Double(automation.steps[safe: stepIndex]?.duration ?? 0),
                      guardCount < automation.steps.count * 2 {
                    elapsed -= Double(automation.steps[safe: stepIndex]?.duration ?? 1)
                    stepIndex = (stepIndex + 1) % automation.steps.count
                    guardCount += 1
                }
                stepStartedAt = Date().addingTimeInterval(-max(0, elapsed))
                applyCurrent(of: automation)
            }
        } else if activePlaylist != nil {
            advancePlaylist(forward: true)
            return
        }
        schedule()
    }

    private func applyCurrent(of automation: Automation) {
        switch automation.mode {
        case .timer:
            guard let step = automation.steps[safe: stepIndex] else { return }
            apply?(step.wallpaperID)
        case .clock:
            // A gap keeps whatever is playing, which is the documented rule.
            if let step = automation.clockStep(at: Self.minuteOfDay()) {
                apply?(step.wallpaperID)
            }
        }
    }

    /// One timer, always. A 24 hour clock schedule costs a single wake at the
    /// next boundary, not one per window.
    private func schedule() {
        cancelTimer()
        guard let interval = nextInterval(), interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
        // .common, so an open menu or a scroll cannot hold the wallpaper back.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() {
        if let automation = activeAutomation, automation.mode == .timer {
            stepIndex = (stepIndex + 1) % max(1, automation.steps.count)
            stepStartedAt = Date()
            applyCurrent(of: automation)
            schedule()
        } else {
            reevaluate()
        }
    }

    private func nextInterval() -> TimeInterval? {
        if let automation = activeAutomation {
            switch automation.mode {
            case .timer:
                guard let step = automation.steps[safe: stepIndex] else { return nil }
                let deadline = stepStartedAt.addingTimeInterval(Double(step.duration))
                return max(1, deadline.timeIntervalSinceNow)
            case .clock:
                return Double(automation.minutesToNextBoundary(from: Self.minuteOfDay())) * 60
                    - Double(Calendar.current.component(.second, from: Date()))
            }
        }
        if let playlist = activePlaylist {
            let interval = Double(max(1, playlist.intervalMinutes) * 60)
            let deadline = stepStartedAt.addingTimeInterval(interval)
            return max(1, deadline.timeIntervalSinceNow)
        }
        return nil
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Time helpers

    static func minuteOfDay(_ date: Date = Date()) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import Foundation

/// The one decidable piece of pausing a running schedule: where the current
/// step's clock resumes from.
///
/// A pause must not cost the schedule any progress and must not hand it any.
/// Holding for `heldFor` seconds pushes the step's start forward by exactly
/// that much, so the time left on the step when the pause ends is the time
/// that was left when it began. `AutomationScheduler` owns the timer; this
/// owns the arithmetic so it can be tested without one.
public enum SchedulePause {
    public static func rebasedStepStart(
        _ start: Date, heldFor seconds: TimeInterval
    ) -> Date {
        start.addingTimeInterval(max(0, seconds))
    }
}
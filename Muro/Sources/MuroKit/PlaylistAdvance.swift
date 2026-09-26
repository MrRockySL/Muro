import Foundation

/// The next step a rotating playlist should show, kept pure so it can be
/// tested without a running scheduler.
///
/// Mirrors `Automation`'s own persisted `stepIndex` (D8): the scheduler
/// tracks "where a playlist is" itself, updated every time it actually
/// applies a step, rather than re-deriving "current" from any single
/// surface's applied state. That derivation (`Store.currentAppliedID`, which
/// only ever reads the desktop) is the id of the stuck-step bug — a
/// `.lockscreen`-only playlist never writes it, `firstIndex(of:)` never
/// matches, "current" falls back to `0` on every tick, and every step
/// computes the same "next" from the same starting point.
public enum PlaylistAdvance {
    /// The wallpaper id to apply next, given what the playlist is currently
    /// on. `nil` only when `ids` is empty — callers already guard against
    /// starting an empty playlist, so this is a defensive nicety, not a real
    /// path.
    public static func next(
        ids: [String],
        current: String?,
        shuffle: Bool,
        forward: Bool
    ) -> String? {
        guard !ids.isEmpty else { return nil }
        if shuffle {
            return ids.filter { $0 != current }.randomElement() ?? ids[0]
        }
        let currentIndex = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        let step = forward ? 1 : ids.count - 1
        return ids[(currentIndex + step) % ids.count]
    }
}

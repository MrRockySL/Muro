import Foundation

/// How long a wallpaper keeps moving before it freezes on a frame.
///
/// Issue #3: "I like to have some wallpapers that can move too fast from time
/// to times and it's disturbing when I'm focus on something... when it changes
/// wallpaper or it gets unlocked, then it keeps moving for x sec then pause."
///
/// The rule has one trap in it, and this type exists so that trap is written
/// down and tested rather than living in an expression halfway through
/// `EngineController.reconcile`:
///
/// - a wallpaper with **no** value of its own follows the global setting
/// - a wallpaper set to **zero** never freezes, and must NOT fall back to the
///   global setting. "Never pause" is a decision, not an absence
/// - a global setting of zero or nil means nothing freezes on its own
///
/// The difference between "no value" and "zero" is the whole feature: get it
/// wrong and a wallpaper the user explicitly asked to keep playing starts
/// freezing the moment they set a global default, which is the opposite of
/// what they asked for and is invisible until they notice it standing still.
public enum PauseAfter {
    /// Seconds to play before freezing, or nil for "keep playing".
    ///
    /// - Parameters:
    ///   - wallpaper: the wallpaper's own override. Nil means it has none.
    ///   - global: the app-wide setting.
    public static func resolve(wallpaper: Int?, global: Int?) -> Int? {
        normalise(wallpaper ?? global)
    }

    /// Anything at or below zero means "never freeze". The engine only ever
    /// wants a positive duration or nothing, so collapse the rest here instead
    /// of leaving every caller to remember it.
    public static func normalise(_ seconds: Int?) -> Int? {
        guard let seconds, seconds > 0 else { return nil }
        return seconds
    }
}


/// The frame rate to show and filter by: the nearest standard rate.
///
/// Wallpapers report their exact rate, and many are a little off a round
/// number (59.94, 29.97) or irregular (67, 69, 37, 34, 33). Shown as is, the
/// detail said "59" for a 60 fps wallpaper and Explore's FPS filter listed odd
/// rates nobody chooses between, with "60" also holding wallpapers that said
/// 59 (full check, 2026-10-01). Everything that names a frame rate uses this,
/// so the label and the filter always agree.
public func standardFrameRate(_ fps: Double) -> Int {
    let standard = [24, 25, 30, 50, 60, 72, 90, 120, 144, 240]
    guard fps.isFinite, fps > 0 else { return 0 }
    return standard.min { abs(Double($0) - fps) < abs(Double($1) - fps) } ?? Int(fps.rounded())
}

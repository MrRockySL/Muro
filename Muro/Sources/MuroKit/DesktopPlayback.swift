import Foundation

/// Issue #22: "Add options/settings to continue playing when desktop is
/// focused". Two separate switches, both off by default:
///
/// - **Play only on desktop** freezes a screen's wallpaper while any app
///   window is open on that screen, and lets it play while its desktop is
///   clear. Each screen decides for itself.
/// - **Replay on clear desktop** makes Pause After count again every time a
///   screen's desktop becomes clear, so the wallpaper plays for that long and
///   then freezes. Off, Pause After counts only after a start, an unlock or a
///   wallpaper change, as it always has.
///
/// The rules live here rather than in the window controller so they are
/// written down and tested, not implied by the order of a few calls.
public enum DesktopPlayback {
    /// Whether the engine needs to look at windows at all. Nobody pays for
    /// the check unless one of the switches is on.
    public static func needsWindowCheck(playOnlyOnDesktop: Bool, replayOnClearDesktop: Bool) -> Bool {
        playOnlyOnDesktop || replayOnClearDesktop
    }

    /// Whether a screen's wallpaper is held because a window is open on it.
    /// A screen nobody has looked at yet is never held.
    public static func holds(isCovered: Bool?, playOnlyOnDesktop: Bool) -> Bool {
        playOnlyOnDesktop && isCovered == true
    }

    /// Whether this reading makes Pause After count again. Only a real change
    /// from covered to clear does: the first reading after a start is not the
    /// desktop clearing, and a desktop that simply stays clear has to be
    /// allowed to run out and freeze.
    public static func restartsPauseAfter(
        wasCovered: Bool?, isCovered: Bool?, replayOnClearDesktop: Bool
    ) -> Bool {
        replayOnClearDesktop && wasCovered == true && isCovered == false
    }
}

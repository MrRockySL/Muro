import Foundation

/// How long the Mac sits idle before its screen saver starts.
///
/// Muro can already be the screen saver, so sending the user into System
/// Settings for the one number that decides when it runs was the last errand
/// left in the feature. This is that number.
///
/// **It is Apple's preference, not one of Muro's**, so it is read and written
/// exactly where Apple keeps it and nowhere else: the key `idleTime` in
/// `com.apple.screensaver`, current user, **current host**. The by-host part
/// is not a detail. `CFPreferencesCopyAppValue` searches current-host before
/// any-host, so a value written to the any-host domain is shadowed by the
/// by-host one Apple's own panel writes, and would be silently ignored. There
/// is no system-wide default file either: `/Library/Preferences` and
/// `/Library/Managed Preferences` both have no `com.apple.screensaver.plist`,
/// so this one by-host key is the whole story.
///
/// **Everything below was measured on macOS 26.6.2 on 2026-09-10, before any
/// of it was written, rather than assumed:**
///
/// - **An ad-hoc signed binary can write it.** Tested with a throwaway tool
///   signed the same way Muro is. Muro is not sandboxed, so there is no
///   entitlement to acquire and no prompt for the user to answer.
/// - **macOS adopts the new value live. No logout, nothing to restart, no
///   process to kill.** `loginwindow`'s `ScreenSaverDaemon` calls
///   `CFPreferencesAppSynchronize` at the top of `idleTimePreference`, on
///   every single idle check, so it cannot read a stale value. Watched in the
///   system log: the preference was changed to 1800 at 15:53:22, and at
///   15:53:42 the daemon logged `idleTime: 1800`, `targetUserIdle = 1800.0`
///   and rescheduled its timer for 1739.9s, where the previous value of 60
///   would have started the screen saver on the spot.
/// - **Zero means never**, and that was read out of loginwindow rather than
///   guessed at. `_checkUserIdleDuringReset:` compares the target it just
///   read against one second (`fmov d0, #1.0` / `fcmp d8, d0` / `b.mi`) and
///   takes the bail branch, which returns without arming a timer and without
///   launching anything. Nothing under a second ever starts the screen saver.
/// - **Apple's own settings panel does this and nothing more.** Its binary,
///   `Wallpaper.appex`, calls `CFPreferencesSetValue` and contains no
///   `notify_post` at all, so there is no nudge to the daemon being missed
///   here. Both Apple and Muro leave the daemon to notice at its next idle
///   check, which any key press or mouse movement brings on.
public enum ScreenSaverDelay {
    private static let domain = "com.apple.screensaver" as CFString
    private static let key = "idleTime" as CFString

    /// The value that stops the screen saver ever starting.
    ///
    /// Apple's menu calls it "Never". loginwindow has no separate concept for
    /// it: it is just a target below one second, which its own guard refuses
    /// to act on.
    public static let never = 0

    /// The same durations Apple's menu offers, in Apple's order.
    ///
    /// Read off the real menu rather than invented, so a user who knows the
    /// system panel finds the list they expect. Nothing stops another value
    /// being written by hand, and `label` renders those too, but Muro only
    /// ever offers these.
    public static let choices: [Int] = [
        60, 120, 180, 300, 600, 1200, 1800,
        3600, 5400, 7200, 9000, 10800,
        never,
    ]

    /// What the row says when the preference is absent.
    ///
    /// It genuinely is absent on a Mac where nobody has ever touched the
    /// setting: there is no system-wide plist to fall back to, and loginwindow
    /// uses a number compiled into itself that it does not publish anywhere.
    /// Muro says so instead of inventing a duration and showing it as fact.
    public static let systemDefaultLabel = "System default"

    /// The menu wording for a delay, or for not knowing one.
    public static func label(_ seconds: Int?) -> String {
        guard let seconds else { return systemDefaultLabel }
        return seconds <= 0 ? "Never" : durationLabel(seconds)
    }

    /// What macOS will actually wait, or nil when nobody has ever set it.
    public static func current() -> Int? {
        let value = CFPreferencesCopyValue(
            key, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        return (value as? NSNumber)?.intValue
    }

    /// Sets it, then reports what is actually there.
    ///
    /// The read-back is the point of the return value: the UI shows what macOS
    /// holds rather than what Muro hoped to write, so a refusal shows up in
    /// the row instead of being invisible until the screen saver misbehaves.
    @discardableResult
    public static func set(_ seconds: Int) -> Int? {
        CFPreferencesSetValue(
            key, NSNumber(value: max(0, seconds)), domain,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        return current()
    }
}

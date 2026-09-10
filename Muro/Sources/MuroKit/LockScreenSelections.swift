import Foundation

/// What Muro is holding on the lock screen, per display.
///
/// **The bug this exists to stop.** Applying a lock screen replaced the whole
/// record with a single entry, whatever it had been applied to. So setting one
/// wallpaper on the MacBook and a different one on an external display left
/// only the second: the first display's entry was gone, its staged video was
/// swept as unreferenced, and the desktop-still writer, which skips a display
/// only while Muro's record says it owns that display's slot, then wrote a
/// picture straight into it. The user saw the right wallpaper on that screen,
/// frozen, and there was nothing in any log to say why (owner's Mac,
/// 2026-09-10, MacBook plus a DELL P2219H).
///
/// **Why it was written that way, which still matters.** Every staged
/// wallpaper appears as its own row in System Settings, and keeping a
/// selection per apply grew that list a row at a time until it read as
/// leftovers nobody could clear. That was #25, #26 and #27. Replacing
/// everything fixed it and cost the second display.
///
/// So the rule is one selection per **connected display**, not one for the
/// whole Mac and not one per apply. Two displays can hold two, which is the
/// point, and nothing else can accumulate: an entry for a display that is not
/// plugged in now is dropped, so unplugging a monitor cleans up after itself.
public enum LockScreenSelections {
    /// The key that stands for every display at once.
    public static let allKey = "all"

    /// The record after applying `wallpaperID` to `targetKey`.
    ///
    /// - Parameters:
    ///   - current: what is held now, keyed by display UUID or `all`.
    ///   - targetKey: a display UUID, or `all`.
    ///   - connectedDisplays: the UUIDs plugged in right now. An entry for
    ///     anything else is dropped, which is what keeps this bounded.
    public static func afterApply(
        current: [String: String],
        targetKey: String,
        wallpaperID: String,
        connectedDisplays: Set<String>
    ) -> [String: String] {
        // Every display at once supersedes each of them individually, so it
        // stands alone. This is the case that was already right.
        if targetKey == allKey { return [allKey: wallpaperID] }
        // `all` is kept beside a per-display entry on purpose: it is still
        // what any display without one of its own is reading, so dropping it
        // would tell the still writer those screens are free when they are not.
        var next = current.filter { key, _ in
            key == allKey || connectedDisplays.contains(key)
        }
        next[targetKey] = wallpaperID
        return next
    }
}

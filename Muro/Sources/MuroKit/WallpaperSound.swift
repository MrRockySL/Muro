import Foundation

/// Issue #54: which displays' live wallpapers play their sound.
///
/// Every display has a sound of its own, turned off and on by the sound
/// button on that display's page in the menu bar. A live wallpaper with sound
/// is heard as it is applied, and the other displays' go quiet, so the one
/// applied last is the one heard. Another display's can be turned back on
/// from its page, and then both play.
///
/// One live wallpaper on several displays is one sound: played from every one
/// of them it would be heard twice, a moment out of step. So it plays from
/// the first display showing it whose sound is on, the main display first.
///
/// Only a video the person added keeps its sound. Every live wallpaper Muro
/// publishes is silent, so none of this changes anything for them.
public enum WallpaperSound {
    /// The displays whose live wallpaper plays its sound. Empty is silence.
    ///
    /// - Parameters:
    ///   - enabled: "Live Wallpaper Sound" in Settings.
    ///   - off: `EngineConfig.soundOff`, the displays whose sound button in
    ///     the menu bar is off.
    ///   - displays: the displays showing a live wallpaper, main first.
    ///   - wallpaper: the live wallpaper on a display.
    ///   - hasSound: whether a display's live wallpaper has sound.
    public static func displays(
        enabled: Bool,
        off: Set<String>,
        displays: [String],
        wallpaper: (String) -> String?,
        hasSound: (String) -> Bool
    ) -> Set<String> {
        guard enabled else { return [] }
        var heard: Set<String> = []
        var playing: Set<String> = []
        for display in displays where hasSound(display) && !off.contains(display) {
            guard let id = wallpaper(display) else { continue }
            if playing.insert(id).inserted { heard.insert(display) }
        }
        return heard
    }

    /// `EngineConfig.soundOff` after a live wallpaper with sound is applied by
    /// hand. It is heard wherever it shows, and every other display with
    /// sound goes quiet, so two never start playing over each other.
    ///
    /// - Parameters:
    ///   - id: the live wallpaper applied, already on its displays.
    ///   - off: the displays whose sound was off before.
    ///   - displays: the displays showing a live wallpaper.
    public static func off(
        afterApplying id: String,
        off: Set<String>,
        displays: [String],
        wallpaper: (String) -> String?,
        hasSound: (String) -> Bool
    ) -> Set<String> {
        var off = off
        for display in displays {
            if wallpaper(display) == id {
                off.remove(display)
            } else if hasSound(display) {
                off.insert(display)
            }
        }
        return off
    }
}

import Foundation

/// Issue #54: which display's live wallpaper plays its sound.
///
/// One sound at a time, however many displays there are. Two live wallpapers
/// with sound would play over each other, and one live wallpaper on every
/// display would play twice, a moment out of step. So exactly one display
/// plays: the one a live wallpaper with sound was applied to last. When that
/// display's live wallpaper has none, the sound comes from the next display
/// that has some, the main display first, and the others stay silent.
///
/// Only a video the person added keeps its sound. Every live wallpaper Muro
/// publishes is silent, so none of this changes anything for them.
public enum WallpaperSound {
    /// The display whose live wallpaper plays its sound, or nil for silence.
    ///
    /// - Parameters:
    ///   - enabled: "Live Wallpaper Sound" in Settings.
    ///   - preferred: `EngineConfig.soundDisplay`, where a live wallpaper with
    ///     sound was applied last.
    ///   - displays: the displays showing a live wallpaper, main first.
    ///   - hasSound: whether a display's live wallpaper has sound.
    public static func display(
        enabled: Bool,
        preferred: String?,
        displays: [String],
        hasSound: (String) -> Bool
    ) -> String? {
        guard enabled else { return nil }
        if let preferred, displays.contains(preferred), hasSound(preferred) {
            return preferred
        }
        return displays.first(where: hasSound)
    }
}

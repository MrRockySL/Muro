import Foundation

/// Where a wallpaper is being put.
///
/// `all` was called "Both" while there were two of them. The screen saver is
/// the third, and it is a separate key in Apple's own store from the one the
/// lock screen renders, so it is set separately here too.
///
/// Lives in `MuroKit` and is `Codable` because `Playlist` and `Automation`
/// carry it: a schedule records which surface it drives. The raw values are
/// persisted in `playlists.json` / `automations.json` and MUST NOT be renamed.
public enum ApplySurface: String, CaseIterable, Codable, Sendable {
    case all = "All", desktop = "Desktop", lockscreen = "Lockscreen"
    case screensaver = "Screensaver"

    /// The surfaces a playlist or automation may target. The screen saver is
    /// never rotated by a schedule (it ships as its own static surface), so a
    /// schedule's `all` means desktop + lock screen only.
    public static let scheduleCases: [ApplySurface] = [.desktop, .lockscreen, .all]

    /// Whether this choice covers Muro's own desktop engine.
    public var coversDesktop: Bool { self == .desktop || self == .all }
    /// Whether it covers the Apple-managed surface the lock screen renders.
    public var coversLockScreen: Bool { self == .lockscreen || self == .all }
    /// Whether it covers the screen saver.
    public var coversScreenSaver: Bool { self == .screensaver || self == .all }

    /// The Apple store roles this choice writes, in the order they are applied.
    public var appleSurfaces: [AppleWallpaperStore.Surface] {
        var out: [AppleWallpaperStore.Surface] = []
        if coversLockScreen { out.append(.desktop) }
        if coversScreenSaver { out.append(.screenSaver) }
        return out
    }

    /// Whether macOS 26 is needed for this choice.
    public var needsAppleExtension: Bool { self != .desktop }

    /// Human label for the schedule pickers, cards and menu bar. `rawValue`
    /// ("Lockscreen", "All") is the persisted token, not for display.
    public var scheduleLabel: String {
        switch self {
        case .desktop: return "Desktop"
        case .lockscreen: return "Lock Screen"
        case .all: return "Desktop + Lock Screen"
        case .screensaver: return "Screen Saver"
        }
    }
}

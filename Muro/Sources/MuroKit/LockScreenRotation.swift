import Foundation

/// The rules behind a playlist or an automation on the lock screen or the
/// screen saver, kept pure so they can be tested without Apple's wallpaper
/// store or a real extension container.
///
/// Each of the two places has **one fixed id**. The first step writes Apple's
/// store with it, like applying a wallpaper by hand. Every step after that only
/// swaps the video staged behind the id, so the store is not written again,
/// `WallpaperAgent` is not restarted and nothing flashes. The id is the same
/// for every playlist, so moving from one to another on the same place is a
/// swap as well. `LockScreenService` owns the store and the files; this type
/// owns the names and the one decision about what an id stands for.
public enum LockScreenRotation {
    /// The id Apple's store holds while a schedule plays on the lock screen.
    public static let lockScreenID = "muro-rotation-lockscreen"
    /// The same for the screen saver.
    public static let screenSaverID = "muro-rotation-screensaver"

    /// The extension recognises a rotation by this, so everything it does for
    /// one stays away from wallpapers applied by hand.
    public static let idPrefix = "muro-rotation-"

    /// The fixed id for one role.
    public static func fixedID(for role: AppleWallpaperStore.Surface) -> String {
        role == .screenSaver ? screenSaverID : lockScreenID
    }

    /// The key a role's current wallpaper is recorded under in `lockscreen.json`.
    public static func stateKey(for role: AppleWallpaperStore.Surface) -> String {
        role == .screenSaver ? "screenSaver" : "lockScreen"
    }

    public static func isRotationID(_ id: String?) -> Bool {
        id?.hasPrefix(idPrefix) ?? false
    }

    /// The wallpaper a selection stands for.
    ///
    /// A selection holding the fixed id stands for whichever wallpaper was last
    /// staged behind it, so "is wallpaper X on the lock screen" is answered
    /// through `currentStepID`. Any other value is a wallpaper id already and
    /// stands for itself.
    public static func resolvedWallpaperID(
        selectionValue: String?,
        rotationID: String?,
        currentStepID: String?
    ) -> String? {
        guard let selectionValue else { return nil }
        if let rotationID, selectionValue == rotationID { return currentStepID }
        return selectionValue
    }
}

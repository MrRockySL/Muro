import Foundation

/// The decisions behind a rotating lock-screen wallpaper, kept pure so they
/// can be tested without the Apple wallpaper store or a real extension
/// container.
///
/// A playlist or automation that covers the lock screen writes Apple's store
/// **once**, under a wallpaper id that never changes for the schedule's life:
/// the schedule's own id (`Playlist.id` / `Automation.id`, a bare lowercased
/// UUID, the same shape as a `WallpaperEntry.id`). Every tick then swaps the
/// staged video behind that fixed id rather than rewriting the store, so macOS
/// never restarts `WallpaperAgent` and the lock screen never flashes.
/// `LockScreenService` owns the store and the file IO; this type owns the
/// rules it follows.
public enum LockScreenRotation {
    /// The wallpaper id Apple's store is written with while `scheduleID` drives
    /// the lock screen. It is the schedule id itself, fixed for the run, so the
    /// store is written once and only the file behind it moves afterwards.
    public static func storeID(scheduleID: String) -> String { scheduleID }

    /// The wallpaper a query should be compared against.
    ///
    /// When the live selection is the rotation's fixed id, "is wallpaper X on
    /// the lock screen" means "is X the step the schedule is showing right
    /// now", so the comparison resolves through `currentStepID`. Any other
    /// selection value is a plain wallpaper id and stands for itself.
    public static func resolvedWallpaperID(
        selectionValue: String?,
        rotationID: String?,
        currentStepID: String?
    ) -> String? {
        guard let selectionValue else { return nil }
        if let rotationID, selectionValue == rotationID { return currentStepID }
        return selectionValue
    }

    /// Whether a recorded rotation id belongs to no running schedule and must
    /// be torn down. A crash between "schedule stopped" and "lock screen
    /// restored" leaves the fixed id in the store with its last frame staged;
    /// `healIfNeeded` uses this to strip it on the next launch.
    public static func isOrphaned(
        rotationID: String?,
        runningScheduleIDs: Set<String>
    ) -> Bool {
        guard let rotationID else { return false }
        return !runningScheduleIDs.contains(rotationID)
    }
}

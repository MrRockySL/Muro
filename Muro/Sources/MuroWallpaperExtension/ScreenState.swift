import CoreGraphics
import Foundation

/// Whether the screen this extension is drawing on is one nobody has logged
/// in to yet, or one that is locked.
///
/// **Why this is needed.** The extension learns it is locked from two places,
/// and after a restart neither of them says anything. `update` carries a
/// presentation mode, but only once macOS decides to send one, and the
/// `com.apple.screenIsLocked` notification is a *transition*: it is posted
/// when a running Mac locks, never when one boots straight to the login
/// window. So the first wallpaper of the day was acquired with the extension
/// believing the desktop was showing, which means it drew the desktop's still
/// picture over the lock wallpaper's video. Restart the Mac and the lock
/// screen showed the desktop wallpaper, frozen; it only came right once Muro
/// started and the Mac was locked again by hand.
///
/// The session dictionary answers it directly, without waiting to be told.
/// Both keys are read rather than one: `CGSSessionScreenIsLocked` covers a
/// Mac that locked, and `kCGSessionLoginDoneKey` covers the login window,
/// where that first key is absent because nothing has been locked.
///
/// Deliberately not keyed on `kCGSSessionOnConsoleKey`, which is also 0 for a
/// perfectly ordinary session that a fast user switch moved off screen.
enum ScreenState {
    /// True while the wallpaper cannot be the desktop: the login window, or a
    /// locked screen. False when it cannot be told, so nothing here can make
    /// a normal desktop start playing.
    static func isCovered() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return true }
        if let locked = session["CGSSessionScreenIsLocked"] as? Int, locked != 0 { return true }
        if let done = session["kCGSessionLoginDoneKey"] as? Bool { return !done }
        if let done = session["kCGSessionLoginDoneKey"] as? Int { return done == 0 }
        return false
    }
}

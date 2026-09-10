import CoreGraphics
import Foundation
import ImageIO

/// The picture the desktop shows when Muro itself is not there to show one.
///
/// macOS keeps a single wallpaper per display and a lock-screen apply puts
/// this extension on it, so this extension is also what the desktop falls back
/// to once Muro's own window is gone. Two things were wrong with letting the
/// video layer be that fallback on its own. It freezes a frame of the *lock*
/// wallpaper, which is not the wallpaper the desktop was set to. And when the
/// first frame fails to composite it draws nothing at all, which is the black
/// desktop reported after quitting Muro.
///
/// So the app stages the desktop's own still here, the extension draws it
/// underneath the video, and the video is hidden whenever it is not playing.
/// Restaged whenever the desktop wallpaper changes, including on every
/// playlist and automation step.
/// **One picture per display.** A Mac with two screens has two desktop
/// wallpapers, and this used to hand every surface the same one: whatever the
/// main display was set to. So after quitting Muro the second display showed
/// the first display's picture, which reads as the wallpapers having swapped
/// (owner, 2026-09-10). The app stages one file per display now, named by the
/// same `CGDirectDisplayID` macOS puts in the acquire request, and the
/// unnumbered file stays as the fallback for a surface that names no display.
enum DesktopStill {
    /// The file for one display, or the shared one, whichever exists.
    static func url(displayID: UInt32?) -> URL? {
        let manager = FileManager.default
        if let displayID {
            let perDisplay = documentsURL
                .appendingPathComponent("desktop-still-\(displayID).jpg")
            if manager.fileExists(atPath: perDisplay.path) { return perDisplay }
        }
        let shared = documentsURL.appendingPathComponent("desktop-still.jpg")
        return manager.fileExists(atPath: shared.path) ? shared : nil
    }

    /// Whether there is any picture staged at all. For the log line only.
    static var url: URL? { url(displayID: nil) }

    /// The last decode, kept against the file it came from.
    ///
    /// The app asks for this again on every apply, every playlist step and
    /// every launch, and the surface asks for it again itself after it is
    /// built. That is a 4K JPEG each time, for a picture that usually has not
    /// changed, so it is decoded once per version of the file. Size and
    /// modification date together are what change when the app stages a new
    /// one, since it copies the picture in rather than writing it.
    /// Keyed by file path now, because two displays decode two files and one
    /// slot would make them evict each other on every reassert.
    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var memory: [String: (key: String, image: CGImage)] = [:]

    static func current(displayID: UInt32? = nil) -> CGImage? {
        guard let url = url(displayID: displayID) else { return nil }
        let path = url.path
        let key = identity(of: url)
        memoryLock.lock()
        let remembered = memory[path]?.key == key ? memory[path]?.image : nil
        memoryLock.unlock()
        if let remembered { return remembered }

        guard let decoded = image(at: url) else { return nil }
        memoryLock.lock()
        memory[path] = (key, decoded)
        memoryLock.unlock()
        return decoded
    }

    /// Drops decodes for files the app has taken away, so a display that is
    /// unplugged does not keep a 4K bitmap alive for the life of the process.
    static func forgetMissingFiles() {
        memoryLock.lock()
        memory = memory.filter { FileManager.default.fileExists(atPath: $0.key) }
        memoryLock.unlock()
    }

    /// What the file is right now, cheaply: its size and modification date.
    private static func identity(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        return "\(size)-\(modified)"
    }

    /// ImageIO rather than AppKit: this is decoded on the renderer's own queue
    /// and `NSImage` is not the thing to reach for off the main thread.
    ///
    /// Decoded here rather than the first time it is drawn. ImageIO hands back
    /// a picture that decodes lazily, and the first draw is inside the commit
    /// that gives macOS the surface: a 4K JPEG decoded there is time the
    /// desktop spends with nothing on it. It also means the copies handed to
    /// the layer afterwards share one decoded bitmap.
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

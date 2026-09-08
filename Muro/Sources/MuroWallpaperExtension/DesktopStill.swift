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
enum DesktopStill {
    static var url: URL? {
        let url = documentsURL.appendingPathComponent("desktop-still.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The last decode, kept against the file it came from.
    ///
    /// The app asks for this again on every apply, every playlist step and
    /// every launch, and the surface asks for it again itself after it is
    /// built. That is a 4K JPEG each time, for a picture that usually has not
    /// changed, so it is decoded once per version of the file. Size and
    /// modification date together are what change when the app stages a new
    /// one, since it copies the picture in rather than writing it.
    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var memory: (key: String, image: CGImage)?

    static func current() -> CGImage? {
        guard let url else {
            memoryLock.lock()
            memory = nil
            memoryLock.unlock()
            return nil
        }
        let key = identity(of: url)
        memoryLock.lock()
        let remembered = memory?.key == key ? memory?.image : nil
        memoryLock.unlock()
        if let remembered { return remembered }

        guard let decoded = image(at: url) else { return nil }
        memoryLock.lock()
        memory = (key, decoded)
        memoryLock.unlock()
        return decoded
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
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

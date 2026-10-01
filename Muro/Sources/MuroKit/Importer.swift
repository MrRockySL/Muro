import AVFoundation
import CryptoKit
import Foundation

/// The category a video imported into the app is filed under. The app reads
/// it to keep a person's own videos in the Library and out of Explore.
public let importedVideoCategory = "My Videos"

/// A short identity for a video file: its size and a hash of its first and
/// last megabyte. Enough to tell the same file imported twice from two
/// different ones without reading a whole video, which can be gigabytes.
public func videoFingerprint(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let chunk: UInt64 = 1 << 20
    var hasher = SHA256()
    hasher.update(data: withUnsafeBytes(of: size.bigEndian) { Data($0) })
    try? handle.seek(toOffset: 0)
    guard let head = try? handle.read(upToCount: Int(min(chunk, size))) else { return nil }
    hasher.update(data: head)
    if size > chunk {
        try? handle.seek(toOffset: size - min(chunk, size - chunk))
        guard let tail = try? handle.readToEnd() else { return nil }
        hasher.update(data: tail)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// The library entry `source` was already imported as, or nil.
///
/// Importing one video twice made two identical wallpapers, while a second
/// `.saver` was already turned away with "already added" (full check,
/// 2026-10-01). An import made since then carries its file's fingerprint; an
/// older one is matched by the same name and the same length instead.
public func alreadyImported(
    source: URL, fingerprint: String?, in entries: [WallpaperEntry]
) -> WallpaperEntry? {
    if let fingerprint, let match = entries.first(where: { $0.sourceFingerprint == fingerprint }) {
        return match
    }
    let title = source.deletingPathExtension().lastPathComponent
    let older = entries.filter {
        $0.sourceFingerprint == nil && $0.category == importedVideoCategory && $0.title == title
    }
    guard !older.isEmpty else { return nil }
    let duration = CMTimeGetSeconds(AVURLAsset(url: source).duration)
    guard duration.isFinite, duration > 0 else { return nil }
    return older.first { abs($0.duration - duration) < 0.1 }
}

/// Brings a video into the library: master, thumbnail, p720 preview,
/// manifest append. Shared by muro-import and the app's drop-to-import.
/// Blocking — call off the main thread.
///
/// `preserveOriginal` decides what the master is made of. Off, the default,
/// re-encodes to HEVC, which is how every wallpaper published before
/// 2026-08-29 was made and what keeps a user's own dropped video from filling
/// their disk. On, the video stream is copied across untouched, so the master
/// is the source picture to the bit. That is the mode published wallpapers use
/// now: the owner's rule is that nobody downloads a wallpaper worse than the
/// clip it came from.
@discardableResult
public func importVideo(
    source: URL,
    title: String? = nil,
    category: String? = nil,
    root: URL = LibraryManifest.defaultRoot(),
    preserveOriginal: Bool = false,
    sourceFingerprint: String? = nil,
    progress: ((Double) -> Void)? = nil
) throws -> WallpaperEntry {
    let mastersDir = root.appendingPathComponent("Masters", isDirectory: true)
    let thumbsDir = root.appendingPathComponent("Thumbnails", isDirectory: true)
    let previewsDir = root.appendingPathComponent("Previews", isDirectory: true)
    for dir in [mastersDir, thumbsDir, previewsDir] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let id = UUID().uuidString.lowercased()
    let masterURL = mastersDir.appendingPathComponent("\(id).mov")
    let thumbURL = thumbsDir.appendingPathComponent("\(id).jpg")
    let previewURL = previewsDir.appendingPathComponent("\(id)-p720.mov")

    do {
        // The encode is nearly all of an import's time, so it is most of the
        // bar; the picture and the preview after it are the last few percent.
        let result = try preserveOriginal
            ? copyVideoStream(source: source, destination: masterURL)
            : transcodeToHEVC(source: source, destination: masterURL) { progress?($0 * 0.95) }
        // A missing thumbnail costs the card its picture and nothing more, so
        // like the preview below it must not fail an import whose master
        // transcoded perfectly well.
        do {
            try generateThumbnail(video: masterURL, destination: thumbURL)
        } catch {
            // Left deliberately silent: the card falls back to a plain tile.
        }
        // A missing preview only degrades the remote detail view to a static
        // thumbnail, so it must not fail the whole import.
        let preview = try? generatePreview(
            source: masterURL, destination: previewURL, spec: .p720
        )
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: masterURL.path)[.size] as? Int64) ?? 0

        let entry = WallpaperEntry(
            id: id,
            title: title ?? source.deletingPathExtension().lastPathComponent,
            category: category ?? importedVideoCategory,
            file: "Masters/\(id).mov",
            previewFile: preview != nil ? "Previews/\(id)-p720.mov" : nil,
            thumbnail: "Thumbnails/\(id).jpg",
            width: result.width,
            height: result.height,
            fps: result.fps,
            duration: result.duration,
            sizeBytes: sizeBytes ?? 0,
            sourceFingerprint: sourceFingerprint
        )
        try LibraryWriter.update(root: root) { manifest in
            manifest.wallpapers.append(entry)
        }
        return entry
    } catch {
        try? FileManager.default.removeItem(at: masterURL)
        try? FileManager.default.removeItem(at: thumbURL)
        try? FileManager.default.removeItem(at: previewURL)
        throw error
    }
}

import Foundation

/// Brings a video into the library: HEVC transcode (video only, fps
/// preserved), thumbnail, p720 preview, manifest append. Shared by
/// muro-import and the app's drop-to-import. Blocking — call off the main
/// thread.
@discardableResult
public func importVideo(
    source: URL,
    title: String? = nil,
    category: String? = nil,
    root: URL = LibraryManifest.defaultRoot()
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
        let result = try transcodeToHEVC(source: source, destination: masterURL)
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
            category: category ?? "My Videos",
            file: "Masters/\(id).mov",
            previewFile: preview != nil ? "Previews/\(id)-p720.mov" : nil,
            thumbnail: "Thumbnails/\(id).jpg",
            width: result.width,
            height: result.height,
            fps: result.fps,
            duration: result.duration,
            sizeBytes: sizeBytes ?? 0
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

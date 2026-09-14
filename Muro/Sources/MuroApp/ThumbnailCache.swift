import Foundation
import ImageIO

/// Disk copies of the catalog thumbnails for wallpapers that are not
/// downloaded.
///
/// Explore used to hand these straight to `AsyncImage`, which keeps nothing.
/// A card that scrolled out of the grid lost its picture, and scrolling back
/// fetched it again, so on a slow connection every card went black on the way
/// back up. Each thumbnail is now saved the first time it arrives and read
/// from disk after that, relaunches included.
///
/// Lives in ~/Library/Caches beside the previews, because it can always be
/// downloaded again, and Clear empties it with them. A thumbnail at a given id
/// never changes, so a saved copy is always right and never expires. A
/// thumbnail is about 127 KB, so the whole catalog is small enough to need no
/// cap.
enum ThumbnailCache {
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muro/Thumbnails", isDirectory: true)
    }

    /// Where the saved copy lives, whether or not it has been saved yet.
    /// Touches nothing on disk, so it is cheap enough for `body`.
    static func path(id: String) -> String {
        directory.appendingPathComponent("\(id).jpg").path
    }

    /// Downloads that have started and not finished, so a card that appears
    /// again waits for the download already running instead of starting one.
    @MainActor private static var inFlight: [String: Task<String?, Never>] = [:]

    /// The saved thumbnail's path, downloading it first when it has never been
    /// saved. `nil` when it could not be fetched, so the next attempt tries
    /// again.
    ///
    /// The download runs in its own task rather than the caller's. A card that
    /// scrolls away cancels its own work, and on a slow connection that threw
    /// away downloads that were nearly finished.
    @MainActor
    static func fetch(id: String, from remote: URL) async -> String? {
        let saved = path(id: id)
        if FileManager.default.fileExists(atPath: saved) { return saved }
        if let running = inFlight[id] { return await running.value }
        let task = Task.detached(priority: .utility) {
            await download(id: id, from: remote)
        }
        inFlight[id] = task
        let result = await task.value
        inFlight[id] = nil
        return result
    }

    /// Removes a saved copy that could not be read, so it is fetched again.
    static func discard(id: String) {
        try? FileManager.default.removeItem(atPath: path(id: id))
    }

    private static func download(id: String, from remote: URL) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: remote) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        // Only a real picture is kept. A busy CDN can answer with a short
        // error page, and saving that would leave the card blank for good.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let destination = URL(fileURLWithPath: path(id: id))
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            return nil
        }
        return destination.path
    }

    /// Everything the saved thumbnails take up, counted in the Storage row's
    /// Clear alongside the previews.
    static func sizeOnDisk() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

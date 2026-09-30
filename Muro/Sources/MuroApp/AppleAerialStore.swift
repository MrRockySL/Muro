import Foundation
import MuroKit

/// Muro's side of Apple's aerial library. Issue #7, asked for by n3rvino.
///
/// **The whole feature is removable.** Everything it adds lives in a handful
/// of new files, Muro's own aerial downloads (`Masters/apple-*.mov`), one cache
/// folder of pictures and facts, and clearly marked hooks in files that
/// already existed. `library.json` is never written, Apple's own store is
/// never written, and the ids it uses are recognisable on sight
/// (`AppleAerials.idPrefix`).
///
/// **What it does not do**, all deliberate:
///
/// - It does not copy Apple's videos into Muro's library. An aerial macOS
///   downloaded for itself is played where it lies.
/// - It does not write into `com.apple.wallpaper`. Aerials Muro fetches go
///   beside Muro's own wallpapers, so Muro only ever deletes its own files.
/// - It does not generate Efficient variants. Apple ships these at 240 fps and
///   an Efficient pass would transcode hundreds of megabytes into
///   `library.json`, which is the one file this feature promised not to touch.
@MainActor
final class AppleAerialModel: ObservableObject {

    /// Everything Apple lists on this Mac. Nil until a load has been tried,
    /// and nil afterwards when there is no store to read: those are different
    /// answers and the gallery says different things about them.
    @Published private(set) var aerials: [AppleAerial]?
    @Published private(set) var loaded = false

    private let libraryRoot: URL

    init(libraryRoot: URL = LibraryManifest.defaultRoot()) {
        self.libraryRoot = libraryRoot
    }

    // MARK: - Loading

    func load() {
        let root = libraryRoot
        Task.detached(priority: .userInitiated) {
            let found = AppleAerials.cachedAerials(libraryRoot: root)
            await MainActor.run {
                self.aerials = found
                self.loaded = true
                if let found { AppleAerialFetcher.shared.prefetchSizes(for: found) }
            }
        }
    }

    /// Apple's categories, in Apple's order, and only the ones that actually
    /// have something in them on this Mac.
    var categories: [String] {
        var seen = Set<String>()
        return (aerials ?? [])
            .map(\.category)
            .filter { seen.insert($0).inserted }
    }

    func aerials(in category: String, matching search: String) -> [AppleAerial] {
        (aerials ?? []).filter { aerial in
            if category != "All", aerial.category != category { return false }
            if !search.isEmpty,
               !aerial.name.localizedCaseInsensitiveContains(search),
               !aerial.category.localizedCaseInsensitiveContains(search) {
                return false
            }
            return true
        }
    }

    func aerial(id: String) -> AppleAerial? {
        aerials?.first { $0.id == id }
    }
}

// MARK: - Becoming an ordinary Muro wallpaper

extension AppleAerial {
    /// What is known about this aerial's video, from Apple's own servers.
    var facts: AppleAerialInfo.Facts? {
        AppleAerialInfo.facts(assetID: assetID, video: videoURL)
    }

    /// The catalog row an Apple aerial pretends to be, so every card, filter
    /// and preview in Muro can read it without knowing what it is.
    ///
    /// `video` is Apple's CDN address, which is what a download reads and the
    /// reason this feature costs Muro's own bucket nothing. The size, length
    /// and resolution are the real ones once they have been read, and a
    /// stand-in until then. `thumbnail` points at Muro's sharp picture once it
    /// has been taken: it is part of the row so a card redraws the moment the
    /// picture lands.
    var catalogEntry: CatalogEntry {
        let facts = facts
        let sharp = AppleAerialInfo.hasFrame(assetID: assetID)
            ? URL(fileURLWithPath: AppleAerialInfo.framePath(assetID: assetID))
            : nil
        // A picture or one macOS draws has no frame rate and no length.
        let isVideo = kind == .video
        return CatalogEntry(
            id: id,
            title: name,
            category: category,
            width: facts?.width ?? knownWidth ?? AppleAerials.Format.width,
            height: facts?.height ?? knownHeight ?? AppleAerials.Format.height,
            fps: isVideo ? (facts?.fps ?? AppleAerials.Format.fps) : 0,
            duration: isVideo ? (facts?.duration ?? AppleAerials.Format.duration) : 0,
            sizeBytes: facts?.bytes ?? knownBytes ?? (isVideo ? AppleAerials.Format.approximateBytes : 0),
            video: videoURL,
            thumbnail: sharp ?? previewImageURL
                ?? thumbnailPath.map { URL(fileURLWithPath: $0) } ?? videoURL,
            preview720: nil,
            // Never new. These are Apple's and have been on every Mac for
            // years; a NEW badge on them would be a lie.
            publishedAt: nil
        )
    }

    /// `local` is set only when the video is genuinely on disk, which is what
    /// makes `isDownloaded`, the Apply button and the engine agree.
    var wallpaperItem: WallpaperItem {
        WallpaperItem(
            local: isDownloaded ? AppleAerials.entry(for: self) : nil,
            remote: catalogEntry
        )
    }
}

// MARK: - What the app store has to know about them

extension AppStore {

    /// The best picture of this aerial on this Mac: Muro's sharp one once it
    /// has been taken, otherwise the small still macOS keeps.
    ///
    /// Apple writes one still per aerial whether or not the video was ever
    /// downloaded, which is why a gallery of 162 costs nothing to show before
    /// the sharp pictures arrive.
    func appleAerialThumbnailPath(id: String) -> String? {
        if id.hasPrefix(AppleScreenSavers.idPrefix) {
            guard let saver = AppleScreenSavers.cached().first(where: { $0.id == id }) else { return nil }
            // Muro's own picture of it once fetched, Apple's small one until then.
            return AppleAerialInfo.hasFrame(assetID: saver.assetID)
                ? AppleAerialInfo.framePath(assetID: saver.assetID)
                : saver.thumbnailPath
        }
        guard let aerial = AppleAerials.cachedAerials(libraryRoot: root)?
            .first(where: { $0.id == id })
        else { return nil }
        let path = AppleAerials.sharpestThumbnail(for: aerial)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Makes sure a downloaded aerial has a picture on disk before the lock
    /// screen or the screen saver is given it, since both carry one beside
    /// the video. Almost always already true: macOS keeps a still for every
    /// aerial it lists. When it does not, one frame is taken from the video
    /// on disk, which takes a fraction of a second.
    func ensureAerialThumbnail(_ entry: WallpaperEntry) {
        guard AppleAerials.isAppleID(entry.id),
              !FileManager.default.fileExists(atPath: entry.thumbnail),
              FileManager.default.fileExists(atPath: entry.file)
        else { return }
        let destination = URL(fileURLWithPath: entry.thumbnail)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? generateThumbnail(
            video: URL(fileURLWithPath: entry.file), destination: destination,
            at: 1.0, maxDimension: 1920
        )
    }

    /// Every aerial on this Mac, as wallpapers.
    var downloadedAppleItems: [WallpaperItem] {
        (AppleAerials.cachedAerials(libraryRoot: root) ?? [])
            .filter(\.isDownloaded)
            .map(\.wallpaperItem)
    }

    /// What a playlist or an automation can be made of: everything
    /// downloaded, Muro's own first, then any of Apple's aerials on this Mac.
    /// A playlist only holds ids, and every place that plays one already
    /// finds an aerial by its id, so nothing downstream had to change.
    var scheduleItems: [WallpaperItem] {
        localItems + downloadedAppleItems
    }

    /// Fetches one aerial from Apple's CDN, beside Muro's own wallpapers.
    ///
    /// Two things this is careful about. It never touches Apple's store, so a
    /// user who later removes the download loses Muro's copy and keeps
    /// whatever macOS had. And it does nothing at all when macOS already holds
    /// the file, so an aerial a Mac already has is never pulled twice.
    ///
    /// Progress goes through the same `downloads` dictionary the catalog uses,
    /// which is what makes the existing button, bar and percentage work here
    /// without knowing what they are showing.
    func downloadAppleAerial(_ item: WallpaperItem) {
        guard let aerial = AppleAerials.cachedAerials(libraryRoot: root)?
            .first(where: { $0.id == item.id }),
            !aerial.isDownloaded,
            downloads[item.id] == nil
        else { return }

        downloads[item.id] = 0
        let id = item.id
        let source = aerial.videoURL
        let destination = URL(fileURLWithPath: aerial.cachePath)
        let directory = destination.deletingLastPathComponent()
        // Asked now, so the progress reads "of 441 MB" rather than a guess
        // on a page that was opened straight into the detail view.
        AppleAerialFetcher.shared.ensureSize(for: aerial)

        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try await fetchMaster(from: source, to: destination) { progress in
                    Task { @MainActor in AppStore.shared.downloads[id] = progress }
                }
                // The file is the truth about its size.
                if let bytes = (try? FileManager.default.attributesOfItem(
                    atPath: destination.path)[.size] as? NSNumber)?.int64Value {
                    AppleAerialInfo.record(
                        AppleAerialInfo.Facts(video: source.absoluteString, bytes: bytes),
                        assetID: aerial.assetID
                    )
                }
                await MainActor.run {
                    AppStore.shared.downloads[id] = nil
                    AppStore.shared.finishedAppleAerialChange()
                    // Taken from the file now on disk, so it costs nothing.
                    AppleAerialFetcher.shared.requestFrame(for: aerial)
                }
            } catch {
                // A part-written file is worse than none: it would read as
                // downloaded and then fail to play.
                try? FileManager.default.removeItem(at: destination)
                await MainActor.run {
                    AppStore.shared.downloads[id] = nil
                    AppStore.shared.applyError =
                        "That aerial could not be downloaded from Apple. \(error.localizedDescription)"
                }
            }
        }
    }

    /// Gives back the space Muro's own copy takes.
    ///
    /// **Only Muro's copy.** If macOS has its own, the aerial stays playable
    /// afterwards and the button is not offered in the first place, because
    /// there is nothing of Muro's to reclaim.
    func removeAppleAerialDownload(_ item: WallpaperItem) {
        guard let aerial = AppleAerials.cachedAerials(libraryRoot: root)?
            .first(where: { $0.id == item.id }),
            aerial.hasMuroCopy
        else { return }

        // Off the screen first, the same order `performDelete` uses: a
        // wallpaper whose file disappears underneath a playing window is how
        // the desktop ends up showing nothing.
        if config.allDisplays?.wallpaperID == item.id { config.allDisplays = nil }
        let kept = config.perDisplay.filter { $0.value.wallpaperID != item.id }
        let changed = kept.count != config.perDisplay.count
        if changed { config.perDisplay = kept }
        if changed || config.allDisplays == nil { saveConfig() }

        try? FileManager.default.removeItem(atPath: aerial.cachePath)
        finishedAppleAerialChange()
    }

    /// What every write to Muro's aerial downloads ends with.
    ///
    /// `isDownloaded` is read off the file system rather than remembered, so
    /// there is no list to correct; this exists to make the interface look
    /// again and to nudge the engine, whose watcher fires on the library
    /// directory and would not have seen a write inside a subfolder.
    func finishedAppleAerialChange() {
        AppleAerials.invalidateCache()
        objectWillChange.send()
        recomputeSize()
    }

    /// Whether Muro has a copy of this aerial that Muro may delete.
    ///
    /// False when the only copy is macOS's, which is the usual case for the
    /// handful a Mac ships with, and false when the aerial is not downloaded
    /// at all. Only true when there is space Muro can actually give back.
    func hasMuroCopyOfAerial(id: String) -> Bool {
        AppleAerials.cachedAerials(libraryRoot: root)?
            .first { $0.id == id }?
            .hasMuroCopy ?? false
    }
}

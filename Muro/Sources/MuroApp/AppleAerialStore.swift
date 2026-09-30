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
        // A downloaded picture is one side of what Apple sent: Apple's
        // download holds every picture of the day, Muro keeps the one this
        // card stands for. From then on that file is its size, everywhere.
        let kept = kind == .picture
            ? (try? FileManager.default.attributesOfItem(atPath: cachePath)[.size] as? NSNumber)?
                .int64Value
            : nil
        return CatalogEntry(
            id: id,
            title: name,
            category: category,
            width: facts?.width ?? knownWidth ?? AppleAerials.Format.width,
            height: facts?.height ?? knownHeight ?? AppleAerials.Format.height,
            fps: isVideo ? (facts?.fps ?? AppleAerials.Format.fps) : 0,
            duration: isVideo ? (facts?.duration ?? AppleAerials.Format.duration) : 0,
            sizeBytes: kept ?? facts?.bytes ?? knownBytes
                ?? (isVideo ? AppleAerials.Format.approximateBytes : 0),
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
            .map(appleWallpaperItem)
    }

    /// One of Apple's, as a wallpaper, with its heart. A like is kept by id
    /// like every other (`likedIDs`), so it works before anything is
    /// downloaded, the same as in Explore.
    func appleWallpaperItem(_ aerial: AppleAerial) -> WallpaperItem {
        var item = aerial.wallpaperItem
        item.liked = likedIDs.contains(aerial.id)
        return item
    }

    /// What was downloaded in the Apple section, in Apple's order, for the
    /// Library's Downloaded tab (owner, 2026-09-30). Only Muro's own
    /// downloads: an aerial macOS keeps for itself is not Muro's to delete,
    /// and a tab of downloads is where things get deleted.
    var appleLibraryItems: [WallpaperItem] {
        let ids = appleDownloadedIDs
        guard !ids.isEmpty else { return [] }
        return (AppleAerials.cachedAerials(libraryRoot: root) ?? [])
            .filter { ids.contains($0.id) }
            .map(appleWallpaperItem)
    }

    /// Everything liked in the Apple section, Apple's screen savers too, for
    /// the Library's Liked tab. The person's own screen savers have their own
    /// group there.
    var likedAppleItems: [WallpaperItem] {
        let ids = likedIDs.filter(AppleAerials.isAppleID)
        guard !ids.isEmpty else { return [] }
        let aerials = (AppleAerials.cachedAerials(libraryRoot: root) ?? []).filter { ids.contains($0.id) }
        let savers = AppleScreenSavers.cachedApple().filter { ids.contains($0.id) }
        return (aerials + savers).map(appleWallpaperItem)
    }

    /// Whether this wallpaper is ready on this Mac, for the download arrow.
    /// A still picture of Apple's is ready once its side has been
    /// downloaded, though it is never a video Muro plays.
    func isOnThisMac(_ item: WallpaperItem) -> Bool {
        if item.id.hasPrefix(AppleAerials.picturePrefix) { return appleDownloadFile(id: item.id) != nil }
        return item.isDownloaded
    }

    /// Muro's own file for something downloaded in the Apple section: an
    /// aerial's video or one side of a still picture. Nil for everything
    /// else, macOS's own copies above all, so nothing of Apple's is ever
    /// deleted through it.
    func appleDownloadFile(id: String) -> URL? {
        guard AppleAerials.isAppleID(id),
              let aerial = AppleAerials.cachedAerials(libraryRoot: root)?.first(where: { $0.id == id }),
              aerial.hasMuroCopy
        else { return nil }
        return URL(fileURLWithPath: aerial.cachePath)
    }

    /// An aerial macOS keeps a copy of plays from that copy, so deleting
    /// Muro's leaves it on screen.
    func macOSKeepsAerial(_ id: String) -> Bool {
        guard let aerial = AppleAerials.cachedAerials(libraryRoot: root)?.first(where: { $0.id == id }),
              aerial.kind == .video, !aerial.applePath.isEmpty
        else { return false }
        return FileManager.default.fileExists(atPath: aerial.applePath)
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
            aerial.kind == .video,
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

    /// Copies `.saver` files into `~/Library/Screen Savers`, where macOS
    /// itself looks for them, so they work from System Settings too. They
    /// then show in the Library under Your Screen Savers. Dropped on the
    /// Library's import bar or picked from it, beside videos (owner,
    /// 2026-09-30).
    ///
    /// Only ever copies: the file the person chose stays where it was, and a
    /// screen saver already there is left alone rather than replaced.
    @discardableResult
    func addScreenSavers(_ urls: [URL]) -> (added: [String], already: [String]) {
        let folder = AppleScreenSavers.installedFolders[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var added: [String] = []
        var already: [String] = []
        for url in urls where url.pathExtension.lowercased() == "saver" {
            let name = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent
            let target = folder.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) {
                already.append(name)
                continue
            }
            do {
                try FileManager.default.copyItem(at: url, to: target)
                added.append(name)
            } catch {
                importError = "\(url.lastPathComponent) could not be added. \(error.localizedDescription)"
            }
        }
        if !added.isEmpty { refreshImportedScreenSavers() }
        return (added, already)
    }

    /// Reads the person's own screen savers again.
    func refreshImportedScreenSavers() {
        AppleScreenSavers.refresh()
        importedScreenSavers = AppleScreenSavers.cachedInstalled()
    }

    /// Whether this is one of the person's own screen savers that Muro may
    /// put in the Trash: only from their own `~/Library/Screen Savers`, where
    /// the import bar puts them. One in `/Library`, for every user of the
    /// Mac, needs an administrator and stays.
    func canDeleteScreenSaver(_ id: String) -> Bool {
        guard id.hasPrefix(AppleScreenSavers.installedIDPrefix),
              let saver = importedScreenSavers.first(where: { $0.id == id })
        else { return false }
        return saver.videoURL.deletingLastPathComponent().standardizedFileURL.path
            == AppleScreenSavers.installedFolders[0].standardizedFileURL.path
    }

    /// Puts the person's own screen savers in the Trash, as System Settings
    /// does, so one can be put back from there (owner, 2026-09-30). Any place
    /// macOS shows one in gets macOS's own wallpaper back first, so macOS is
    /// never left looking for a screen saver that is gone.
    func deleteScreenSavers(_ ids: [String]) async {
        var gone: Set<String> = []
        for id in ids {
            guard canDeleteScreenSaver(id),
                  let saver = importedScreenSavers.first(where: { $0.id == id })
            else { continue }
            do {
                if !macOSWallpapers.desktopTargets(of: id).isEmpty {
                    try await macOSWallpapers.remove(id: id, surface: .desktop, targetKey: "all")
                }
                if macOSWallpapers.isScreenSaver(id) {
                    try await macOSWallpapers.remove(id: id, surface: .screenSaver, targetKey: "all")
                }
                try FileManager.default.trashItem(at: saver.videoURL, resultingItemURL: nil)
                gone.insert(id)
            } catch {
                applyError = "\(saver.name) could not be deleted. \(error.localizedDescription)"
            }
        }
        if recentIDs.contains(where: { gone.contains($0) }) {
            recentIDs.removeAll { gone.contains($0) }
            UserDefaults.standard.set(recentIDs, forKey: "recents")
        }
        refreshImportedScreenSavers()
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

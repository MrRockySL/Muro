import AppKit
import SwiftUI
import MuroKit

/// Static wallpapers in the app: still pictures from their own list on the
/// server (`HostedStatics`). Explore lists them under Static (owner,
/// 2026-11-27), each card says STATIC, and one is downloaded only when the
/// person asks.
///
/// Once downloaded, Muro shows one the way it shows a live wallpaper (owner,
/// 2026-11-27): on the desktop in the engine's own window, as a picture, and
/// on the lock screen and the screen saver as a still video made from it. So
/// a static on the desktop leaves the lock screen alone, Remove gives back
/// what was there, and the menu bar, Applied, two screens and quitting Muro
/// all work as they do for a live wallpaper. macOS's own wallpaper setting is
/// never used for them.
extension AppStore {

    // MARK: - The list

    /// Where their list is read: beside the catalog, or the `staticsListURL`
    /// default when it is set for testing, the way `catalogURL` can be.
    var hostedStaticsListURL: URL? {
        let override = UserDefaults.standard.string(forKey: "staticsListURL") ?? ""
        return URL(string: override)
            ?? URL(string: catalogURLString).map(HostedStatics.listURL(catalogURL:))
    }

    /// Reads the list again, at the same moments as the catalog. Offline, or
    /// with a list that cannot be read, the last one read stays.
    func refreshHostedStatics() async {
        guard let listURL = hostedStaticsListURL,
              let list = try? await HostedStatics.fetchList(from: listURL)
        else { return }
        guard list != hostedStatics else { return }
        hostedStatics = list
        try? HostedStatics.saveLocalList(list, root: root)
        objectWillChange.send()
    }

    func staticEntry(id: String) -> HostedStatics.Entry? {
        guard HostedStatics.isStatic(id) else { return nil }
        return hostedStatics.wallpapers.first { $0.id == id && HostedStatics.isUsable($0) }
    }

    /// The Static section's order for these items: the pinned first, then
    /// newest first (`HostedStatics.sorted`).
    func staticOrder(_ items: [WallpaperItem]) -> [WallpaperItem] {
        let rank = Dictionary(
            HostedStatics.sorted(hostedStatics.wallpapers).enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: - On this Mac

    /// Downloaded, which for a static is having a library entry: built from
    /// its files whenever the list of wallpapers is (`HostedStatics`).
    func isStaticDownloaded(_ item: WallpaperItem) -> Bool {
        item.isStatic && item.local != nil
    }

    /// The downloaded picture.
    func staticPictureFile(_ item: WallpaperItem) -> URL? {
        guard item.isStatic, let entry = item.local else { return nil }
        let url = resolveLibraryFile(entry.file, root: root)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The downloaded card picture, for cards that work offline.
    func staticThumbnailPath(_ item: WallpaperItem) -> String? {
        guard item.isStatic, let entry = item.local else { return nil }
        let path = resolveLibraryFile(entry.thumbnail, root: root).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Download

    /// The Download button: fetches the picture without setting it.
    func downloadStaticNow(_ item: WallpaperItem) {
        guard let entry = staticEntry(id: item.id) else { return }
        Task {
            do {
                try await downloadStatic(entry)
            } catch {
                applyError = error.localizedDescription
            }
        }
    }

    /// Set Wallpaper on one that is not here yet: downloaded first, then set
    /// exactly as if it had been.
    func applyStaticAfterDownload(
        _ item: WallpaperItem, mode: String, target: ApplyTarget,
        surface: ApplySurface?, fromSchedule: Bool
    ) {
        guard let entry = staticEntry(id: item.id) else { return }
        Task {
            do {
                try await downloadStatic(entry)
            } catch {
                applyError = error.localizedDescription
                return
            }
            guard let downloaded = self.item(id: item.id), downloaded.local != nil else { return }
            setWallpaper(downloaded, mode: mode, target: target, surface: surface, fromSchedule: fromSchedule)
        }
    }

    /// Fetches one picture and its card picture, checked against the list,
    /// with the same progress every other download shows.
    func downloadStatic(_ entry: HostedStatics.Entry) async throws {
        let root = self.root
        guard !HostedStatics.isDownloaded(entry, root: root) else {
            staticFilesChanged()
            return
        }
        guard downloads[entry.id] == nil,
              let base = hostedStaticsListURL?.deletingLastPathComponent()
        else { return }
        let id = entry.id
        downloads[id] = 0
        defer { downloads[id] = nil }
        let folder = HostedStatics.folder(root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".download-\(id)-\(entry.version)")
        do {
            try await fetchMaster(from: HostedStatics.fileURL(base: base, entry: entry, file: entry.picture), to: partial) { progress in
                Task { @MainActor in
                    guard AppStore.shared.downloads[id] != nil else { return }
                    AppStore.shared.downloads[id] = min(progress, 0.98)
                }
            }
            let request = URLRequest(
                url: HostedStatics.fileURL(base: base, entry: entry, file: entry.thumbnail),
                cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            let (thumbnail, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            try await Task.detached(priority: .userInitiated) {
                try HostedStatics.install(entry, picture: partial, thumbnail: thumbnail, root: root)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        staticFilesChanged()
    }

    // MARK: - Lock screen and screen saver

    /// The still video Muro's lock screen and screen saver play for a static
    /// wallpaper, made from its picture the first time it is needed and kept
    /// beside it. Nil when it cannot be made.
    func staticStillVideo(for entry: WallpaperEntry) async -> URL? {
        let root = self.root
        let video = HostedStatics.stillVideoFile(for: entry, root: root)
        if FileManager.default.fileExists(atPath: video.path) { return video }
        let picture = resolveLibraryFile(entry.file, root: root)
        guard FileManager.default.fileExists(atPath: picture.path) else { return nil }
        do {
            try await Task.detached(priority: .userInitiated) {
                try await StaticStill.makeVideo(from: picture, to: video)
            }.value
            return video
        } catch {
            return nil
        }
    }
}

/// A static wallpaper on its page: the card picture at once, then the
/// downloaded picture, sharp, once it is here.
struct StaticPicture: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem
    @State private var picture: NSImage?

    var body: some View {
        let file = store.staticPictureFile(item)
        ZStack {
            ThumbImage(item: item, maxPixels: ImageCache.fullPixels)
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: picture != nil)
        .task(id: file?.path) {
            picture = nil
            guard let path = file?.path else { return }
            picture = await Task.detached(priority: .userInitiated) {
                ImageCache.load(path: path, maxPixels: 2880)
            }.value
        }
    }
}

/// Marks a static wallpaper on its card, wherever cards are shown (owner,
/// 2026-11-27: "mark it with the label Static"). The same small dark tag as
/// `InteractiveBadge`.
struct StaticBadge: View {
    var body: some View {
        HStack(spacing: 4.5) {
            Image(systemName: "photo")
                .font(.system(size: 8.5, weight: .bold))
            Text(L("STATIC"))
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.9)
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.leading, 8)
        .padding(.trailing, 9.5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

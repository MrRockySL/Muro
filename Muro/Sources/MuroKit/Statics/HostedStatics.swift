import Foundation

/// Static wallpapers: still pictures, hosted beside the live wallpapers in a
/// list of their own (owner, 2026-11-27: "a new section called Static").
///
/// On the server, beside catalog.json:
///
///     statics.json                          the list (`List`)
///     statics/<id>/<version>/<file>         each picture and its card picture
///
/// A Muro that does not know them never reads the list, and catalog.json
/// carries none of them, so no Muro can mistake a picture for a video.
///
/// Muro shows them itself, the way it shows a live wallpaper (owner,
/// 2026-11-27): on the desktop in its own window, as a picture, so nothing
/// plays; on the lock screen and the screen saver as a still video made from
/// the picture (`StaticStill`). macOS's own wallpaper setting is never
/// touched for them, so a static never takes the lock screen with it and
/// Remove gives back exactly what was there. Explore lists every one from
/// the list, and one is downloaded only when the person asks (Download, or
/// Set Wallpaper when it is not here yet), into `home(for:root:)`. Every file
/// is checked against its size and SHA-256 before it is used.
public enum HostedStatics {
    /// The category they are filed under. Shown as "Static".
    public static let category = "Static Wallpapers"
    /// Every static wallpaper's id starts with this.
    public static let idPrefix = "static-"
    /// The name of the list on the server and of its copy in the library.
    public static let listName = "statics.json"
    /// The folder inside the library the downloaded pictures live in.
    public static let folderName = "Statics"
    /// The card picture's name inside each wallpaper's folder.
    public static let thumbnailName = "thumb.jpg"
    /// Picture types macOS shows as a wallpaper.
    public static let pictureExtensions: Set<String> = ["jpg", "jpeg", "png", "heic"]
    public static let largestPicture: Int64 = 80 * 1024 * 1024
    public static let largestThumbnail: Int64 = 5 * 1024 * 1024

    public static func isStatic(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The list on the server.
    public struct List: Codable, Equatable {
        public var wallpapers: [Entry]

        public init(wallpapers: [Entry] = []) {
            self.wallpapers = wallpapers
        }

        private enum CodingKeys: String, CodingKey { case wallpapers }

        /// One entry this Muro cannot read is left out, never the whole list.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var items = try container.nestedUnkeyedContainer(forKey: .wallpapers)
            var read: [Entry] = []
            while !items.isAtEnd {
                if let entry = try? items.decode(Entry.self) {
                    read.append(entry)
                } else {
                    _ = try? items.decode(Skipped.self)
                }
            }
            wallpapers = read
        }

        private struct Skipped: Decodable {}
    }

    /// One picture in the list.
    public struct Entry: Codable, Equatable {
        public var id: String
        public var title: String
        /// Who made it, when that is known.
        public var author: String?
        /// The day it was first published, `yyyy-MM-dd`.
        public var added: String
        /// Pinned to the front of the Static section, lowest first. The rest
        /// follow newest first (owner, 2026-11-27: AJ's picture first).
        public var order: Int?
        public var width: Int
        public var height: Int
        /// Changes whenever either file does (`version(picture:thumbnail:)`).
        public var version: String
        public var picture: HostedInteractive.File
        public var thumbnail: HostedInteractive.File

        public init(
            id: String, title: String, author: String?, added: String, order: Int?,
            width: Int, height: Int, version: String,
            picture: HostedInteractive.File, thumbnail: HostedInteractive.File
        ) {
            self.id = id
            self.title = title
            self.author = author
            self.added = added
            self.order = order
            self.width = width
            self.height = height
            self.version = version
            self.picture = picture
            self.thumbnail = thumbnail
        }
    }

    /// The list sits beside catalog.json on the same server.
    public static func listURL(catalogURL: URL) -> URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent(listName)
    }

    /// Where one of a wallpaper's files is on the server whose list is at
    /// `base` (the folder the list is in).
    public static func fileURL(base: URL, entry: Entry, file: HostedInteractive.File) -> URL {
        base.appendingPathComponent("statics", isDirectory: true)
            .appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.version, isDirectory: true)
            .appendingPathComponent(file.path)
    }

    // MARK: - What the list may say

    public static func isSafeID(_ id: String) -> Bool {
        isStatic(id) && id.count > idPrefix.count && !id.contains("/")
            && HostedInteractive.isSafePath(id)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isSafeFile(_ file: HostedInteractive.File, largest: Int64) -> Bool {
        !file.path.contains("/") && HostedInteractive.isSafePath(file.path)
            && (1...largest).contains(file.size) && isSHA256(file.sha256)
    }

    /// Whether Muro will list and download this entry at all.
    public static func isUsable(_ entry: Entry) -> Bool {
        guard isSafeID(entry.id), HostedInteractive.isSafeVersion(entry.version),
              !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...16384).contains(entry.width), (1...16384).contains(entry.height),
              isSafeFile(entry.picture, largest: largestPicture),
              isSafeFile(entry.thumbnail, largest: largestThumbnail),
              entry.picture.path != entry.thumbnail.path,
              entry.thumbnail.path == thumbnailName,
              pictureExtensions.contains((entry.picture.path as NSString).pathExtension.lowercased())
        else { return false }
        return true
    }

    /// A wallpaper's version: the start of a SHA-256 over both files' names,
    /// sizes and SHA-256s, so a change to either gives a new one.
    public static func version(picture: HostedInteractive.File, thumbnail: HostedInteractive.File) -> String {
        HostedInteractive.version(of: [picture, thumbnail])
    }

    /// The Static section's order: the pinned ones first, lowest `order`
    /// first, then everything else newest first.
    public static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            switch (a.order, b.order) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.added != b.added { return a.added > b.added }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    // MARK: - Fetching

    /// The list, always from the network, never from a cache. A server with
    /// no list yet answers an empty one.
    public static func fetchList(from url: URL) async throws -> List {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return List() }
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        }
        return try JSONDecoder().decode(List.self, from: data)
    }

    /// The last list read, kept beside library.json.
    public static func saveLocalList(_ list: List, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: root.appendingPathComponent(listName), options: .atomic)
    }

    /// The list `saveLocalList` kept, so Explore lists them offline too.
    public static func loadLocalList(root: URL) -> List? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(listName)) else { return nil }
        return try? JSONDecoder().decode(List.self, from: data)
    }

    /// What Explore shows for one, in the shape of a live wallpaper's catalog
    /// entry: its card picture, its picture's size and the day it was
    /// published. `video` names the picture, which is never played.
    public static func catalogEntry(for entry: Entry, base: URL) -> CatalogEntry {
        let days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]
        return CatalogEntry(
            id: entry.id,
            title: entry.title,
            category: category,
            width: entry.width, height: entry.height, fps: 0, duration: 0,
            sizeBytes: entry.picture.size,
            video: fileURL(base: base, entry: entry, file: entry.picture),
            thumbnail: fileURL(base: base, entry: entry, file: entry.thumbnail),
            publishedAt: days.date(from: entry.added)
        )
    }

    // MARK: - The copies on this Mac

    public static func folder(root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    /// One version of one wallpaper. A new version goes in a folder of its
    /// own, so the file macOS is showing is never written over.
    public static func home(for entry: Entry, root: URL) -> URL {
        folder(root: root)
            .appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.version, isDirectory: true)
    }

    public static func pictureFile(for entry: Entry, root: URL) -> URL {
        home(for: entry, root: root).appendingPathComponent(entry.picture.path)
    }

    public static func thumbnailFile(for entry: Entry, root: URL) -> URL {
        home(for: entry, root: root).appendingPathComponent(entry.thumbnail.path)
    }

    /// Whether this version's picture is here at the size it should be.
    public static func isDownloaded(_ entry: Entry, root: URL) -> Bool {
        let path = pictureFile(for: entry, root: root).path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        else { return false }
        return size.int64Value == entry.picture.size
    }

    public enum InstallError: Error { case unusable, wrongSize, wrongChecksum }

    /// Moves a downloaded picture and card picture into place, once both
    /// match the list. `picture` is moved, never copied.
    public static func install(_ entry: Entry, picture: URL, thumbnail: Data, root: URL) throws {
        guard isUsable(entry) else { throw InstallError.unusable }
        let manager = FileManager.default
        let pictureData = try Data(contentsOf: picture, options: .mappedIfSafe)
        guard Int64(pictureData.count) == entry.picture.size else { throw InstallError.wrongSize }
        guard HostedInteractive.sha256(pictureData) == entry.picture.sha256 else { throw InstallError.wrongChecksum }
        guard Int64(thumbnail.count) == entry.thumbnail.size else { throw InstallError.wrongSize }
        guard HostedInteractive.sha256(thumbnail) == entry.thumbnail.sha256 else { throw InstallError.wrongChecksum }

        let home = home(for: entry, root: root)
        let incoming = home.deletingLastPathComponent()
            .appendingPathComponent(".incoming-\(entry.version)", isDirectory: true)
        try? manager.removeItem(at: incoming)
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        do {
            try thumbnail.write(to: incoming.appendingPathComponent(entry.thumbnail.path), options: .atomic)
            try JSONEncoder().encode(entry).write(to: incoming.appendingPathComponent(recordName), options: .atomic)
            try manager.moveItem(at: picture, to: incoming.appendingPathComponent(entry.picture.path))
            try? manager.removeItem(at: home)
            try manager.moveItem(at: incoming, to: home)
        } catch {
            try? manager.removeItem(at: incoming)
            throw error
        }
        // One version of a wallpaper on disk. Muro holds the picture in
        // memory and the lock screen has its own copy, so the older one can go.
        let versions = home.deletingLastPathComponent()
        for name in (try? manager.contentsOfDirectory(atPath: versions.path)) ?? []
        where name != entry.version && !name.hasPrefix(".") {
            try? manager.removeItem(at: versions.appendingPathComponent(name, isDirectory: true))
        }
    }

    /// The list entry kept beside a downloaded wallpaper's files, so the
    /// engine knows it without the list, offline or after the list changed.
    public static let recordName = "static.json"

    /// Every downloaded copy of one wallpaper, all versions.
    public static func removeDownloads(id: String, root: URL) {
        guard isSafeID(id) else { return }
        try? FileManager.default.removeItem(at: folder(root: root).appendingPathComponent(id, isDirectory: true))
    }

    /// The ids with a downloaded copy here, listed or not.
    public static func downloadedIDs(root: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(root: root).path)) ?? []
        return Set(names.filter(isSafeID))
    }

    // MARK: - Shown by Muro

    /// Every static wallpaper downloaded here, in the Static section's order,
    /// read from the files themselves: the record `install` keeps beside them,
    /// or the copy of the list for a download made before that record existed.
    public static func downloadedEntries(root: URL) -> [Entry] {
        let manager = FileManager.default
        let listed = loadLocalList(root: root)?.wallpapers ?? []
        var out: [Entry] = []
        for id in downloadedIDs(root: root) {
            let versions = folder(root: root).appendingPathComponent(id, isDirectory: true)
            var newest: (entry: Entry, date: Date)?
            for version in (try? manager.contentsOfDirectory(atPath: versions.path)) ?? []
            where !version.hasPrefix(".") && HostedInteractive.isSafeVersion(version) {
                let home = versions.appendingPathComponent(version, isDirectory: true)
                let recorded = (try? Data(contentsOf: home.appendingPathComponent(recordName)))
                    .flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
                guard let entry = recorded ?? listed.first(where: { $0.id == id && $0.version == version }),
                      entry.id == id, entry.version == version, isUsable(entry),
                      isDownloaded(entry, root: root),
                      manager.fileExists(atPath: thumbnailFile(for: entry, root: root).path)
                else { continue }
                let date = (try? home.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if newest == nil || date > newest!.date { newest = (entry, date) }
            }
            if let newest { out.append(newest.entry) }
        }
        return sorted(out)
    }

    /// A downloaded static wallpaper as a library entry, so the engine, the
    /// lock screen and the app treat it like any wallpaper Muro shows. Made
    /// each time from the files, never written into library.json.
    public static func libraryEntry(for entry: Entry) -> WallpaperEntry {
        let home = "\(folderName)/\(entry.id)/\(entry.version)"
        let days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]
        return WallpaperEntry(
            id: entry.id,
            title: entry.title,
            category: category,
            file: "\(home)/\(entry.picture.path)",
            thumbnail: "\(home)/\(entry.thumbnail.path)",
            width: entry.width, height: entry.height, fps: 0, duration: 0,
            sizeBytes: entry.picture.size,
            dateAdded: days.date(from: entry.added) ?? Date(timeIntervalSince1970: 0)
        )
    }

    /// Every downloaded static wallpaper as a library entry.
    public static func libraryEntries(root: URL) -> [WallpaperEntry] {
        downloadedEntries(root: root).map(libraryEntry(for:))
    }

    /// The video Muro's lock screen and screen saver play for a static
    /// wallpaper, beside its picture (`StaticStill.makeVideo`).
    public static func stillVideoFile(for entry: WallpaperEntry, root: URL) -> URL {
        resolveLibraryFile(entry.file, root: root)
            .deletingLastPathComponent()
            .appendingPathComponent("still.mov")
    }
}

extension WallpaperEntry {
    /// A static wallpaper: its file is a still picture, not a video.
    public var isStatic: Bool { HostedStatics.isStatic(id) }
}

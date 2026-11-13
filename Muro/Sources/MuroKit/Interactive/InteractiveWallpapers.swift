import CryptoKit
import Foundation

/// Interactive wallpapers (issue #59): a web page on the desktop that moves
/// with the pointer and with the Mac's sound, where a live wallpaper is a
/// video.
///
/// One is a folder with a page in it. In the library it is an ordinary entry
/// whose `file` is that page, which is the whole of how the rest of Muro tells
/// the two kinds apart (`WallpaperEntry.isInteractive`): nothing was added to
/// `library.json`, so a library written by this Muro still opens in an older
/// one.
///
/// Muro's own come inside the app and are never written into `library.json`,
/// like Apple's aerials. The ones a person adds are copied into the library's
/// `Interactive` folder.
public enum InteractiveWallpapers {
    /// The Explore category Muro's own are filed under.
    public static let category = "Interactive Wallpapers"
    /// Every one of Muro's own has an id that starts with this.
    public static let builtInPrefix = "interactive-muro-"
    /// The folder inside the library a person's own are copied into.
    public static let folderName = "Interactive"
    /// The still picture a wallpaper's folder may carry, for the desktop when
    /// Muro is not running. Without one its thumbnail is used.
    public static let stillName = "still.jpg"

    public static func isBuiltIn(_ id: String) -> Bool { id.hasPrefix(builtInPrefix) }

    // MARK: - Muro's own

    /// What `wallpaper.json` in each of Muro's own folders says.
    private struct Info: Decodable {
        var id: String
        var title: String
        var added: String
        var order: Int?
    }

    /// Where Muro's own are: `Interactive` in the app's resources. Nil for a
    /// bare build with no bundle, which then simply has none.
    public static var builtInFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(folderName, isDirectory: true)
    }

    private static let lock = NSLock()
    private static var cached: [WallpaperEntry]?

    /// Muro's own interactive wallpapers, in the order they are shown. Read
    /// once: what is inside the app does not change while it runs.
    public static func builtInEntries() -> [WallpaperEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let entries = builtInFolder.map(entries(in:)) ?? []
        cached = entries
        return entries
    }

    /// Every wallpaper folder directly inside `folder` that has a page and a
    /// `wallpaper.json`.
    public static func entries(in folder: URL) -> [WallpaperEntry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return [] }
        let days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]
        var found: [(order: Int, entry: WallpaperEntry)] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let home = folder.appendingPathComponent(name, isDirectory: true)
            let page = home.appendingPathComponent("index.html")
            guard manager.fileExists(atPath: page.path),
                  let data = try? Data(contentsOf: home.appendingPathComponent("wallpaper.json")),
                  let info = try? JSONDecoder().decode(Info.self, from: data),
                  isBuiltIn(info.id)
            else { continue }
            found.append((info.order ?? found.count, WallpaperEntry(
                id: info.id,
                title: info.title,
                category: category,
                file: page.path,
                thumbnail: home.appendingPathComponent("thumb.jpg").path,
                width: 0, height: 0, fps: 0, duration: 0,
                sizeBytes: folderSize(home),
                dateAdded: days.date(from: info.added) ?? .distantPast
            )))
        }
        return found.sorted { $0.order < $1.order }.map(\.entry)
    }

    // MARK: - Files

    /// The folder a wallpaper's page lives in.
    public static func folder(of entry: WallpaperEntry, root: URL) -> URL {
        resolveLibraryFile(entry.file, root: root).deletingLastPathComponent()
    }

    /// The picture to leave on the desktop for this wallpaper: the still its
    /// folder carries, otherwise its thumbnail, or nil when it has neither.
    public static func stillPicture(for entry: WallpaperEntry, root: URL) -> URL? {
        let manager = FileManager.default
        let still = folder(of: entry, root: root).appendingPathComponent(stillName)
        if manager.fileExists(atPath: still.path) { return still }
        let thumbnail = resolveLibraryFile(entry.thumbnail, root: root)
        return manager.fileExists(atPath: thumbnail.path) ? thumbnail : nil
    }

    public static func folderSize(_ folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: - A person's own

    public enum ImportError: Error, Equatable {
        /// A folder with no page in it.
        case noPage
        /// More than Muro will copy for one wallpaper.
        case tooLarge
    }

    /// The most one imported wallpaper may take on disk.
    public static let largestImport: Int64 = 500 * 1024 * 1024

    public static func isPage(_ url: URL) -> Bool {
        ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// Whether a dropped or picked file is one this can import: a page, or a
    /// folder with one in it.
    public static func canImport(_ url: URL) -> Bool {
        isPage(url) || (isDirectory(url) && page(inFolder: url) != nil)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    /// The page a folder opens with: `index.html`, or the only page in it.
    public static func page(inFolder folder: URL) -> URL? {
        let manager = FileManager.default
        for name in ["index.html", "index.htm"] {
            let candidate = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: candidate.path) { return candidate }
        }
        let pages = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter(isPage)
        return pages.count == 1 ? pages[0] : nil
    }

    /// What is copied for a picked file, and the page inside it.
    ///
    /// A folder is the wallpaper. A page by itself is copied alone, unless it
    /// is plainly the front page of a wallpaper folder (it is called `index`,
    /// or the folder carries the file Lively or Wallpaper Engine describes a
    /// wallpaper with), in which case the scripts and pictures beside it are
    /// part of it. A page sitting loose in Downloads, Documents or the Desktop
    /// never takes the folder with it.
    static func source(for picked: URL) -> (folder: URL?, page: URL)? {
        if isDirectory(picked) {
            return page(inFolder: picked).map { (picked, $0) }
        }
        guard isPage(picked) else { return nil }
        let parent = picked.deletingLastPathComponent()
        let manager = FileManager.default
        let described = ["LivelyInfo.json", "project.json"].contains {
            manager.fileExists(atPath: parent.appendingPathComponent($0).path)
        }
        let isFront = picked.deletingPathExtension().lastPathComponent.lowercased() == "index"
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL.path
        let shared = [home, home + "/Desktop", home + "/Documents", home + "/Downloads", "/", "/tmp"]
        let loose = shared.contains(parent.standardizedFileURL.path)
        return (described || isFront) && !loose ? (parent, picked) : (nil, picked)
    }

    /// The name a wallpaper folder gives itself, when it has one: Lively's
    /// and Wallpaper Engine's own files first, then the page's title.
    static func title(folder: URL?, page: URL) -> String {
        if let folder {
            for (file, key) in [("LivelyInfo.json", "Title"), ("project.json", "title")] {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(file)),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let title = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !title.isEmpty {
                    return title
                }
            }
        }
        if let html = try? String(contentsOf: page, encoding: .utf8),
           let open = html.range(of: "<title>", options: .caseInsensitive),
           let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex) {
            let title = html[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, title.count <= 60 { return title }
        }
        let name = page.deletingPathExtension().lastPathComponent
        if let folder, name.lowercased() == "index" { return folder.lastPathComponent }
        return name
    }

    /// A short identity for a page, so the same one added twice is noticed.
    public static func fingerprint(of picked: URL) -> String? {
        guard let page = source(for: picked)?.page, let data = try? Data(contentsOf: page) else { return nil }
        return "page-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies a page, or a folder with one, into the library and lists it.
    /// Its picture is taken afterwards by the app, which has the web view to
    /// take it with. Blocking: call off the main thread.
    @discardableResult
    public static func importPage(
        source picked: URL, root: URL = LibraryManifest.defaultRoot()
    ) throws -> WallpaperEntry {
        guard let source = source(for: picked) else { throw ImportError.noPage }
        let manager = FileManager.default
        let size = source.folder.map(folderSize)
            ?? Int64((try? source.page.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size <= largestImport else { throw ImportError.tooLarge }

        let id = UUID().uuidString.lowercased()
        let home = root.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try manager.createDirectory(
            at: home.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            let pageName: String
            if let folder = source.folder {
                try manager.copyItem(at: folder, to: home)
                pageName = source.page.lastPathComponent
            } else {
                try manager.createDirectory(at: home, withIntermediateDirectories: true)
                pageName = "index.html"
                try manager.copyItem(at: source.page, to: home.appendingPathComponent(pageName))
            }
            let entry = WallpaperEntry(
                id: id,
                title: title(folder: source.folder, page: source.page),
                category: importedVideoCategory,
                file: "\(folderName)/\(id)/\(pageName)",
                thumbnail: "Thumbnails/\(id).jpg",
                width: 0, height: 0, fps: 0, duration: 0,
                sizeBytes: size,
                sourceFingerprint: fingerprint(of: picked)
            )
            try LibraryWriter.update(root: root) { manifest in
                manifest.wallpapers.append(entry)
            }
            return entry
        } catch {
            try? manager.removeItem(at: home)
            throw error
        }
    }
}

extension WallpaperEntry {
    /// An interactive wallpaper: its file is a web page, not a video.
    public var isInteractive: Bool {
        let name = file.lowercased()
        return name.hasSuffix(".html") || name.hasSuffix(".htm")
    }
}

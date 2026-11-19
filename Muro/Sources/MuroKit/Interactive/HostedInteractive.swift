import CryptoKit
import Foundation

/// Interactive wallpapers hosted with the live wallpapers, so a new one reaches
/// every Muro without an app update.
///
/// On the server, beside catalog.json:
///
///     interactive.json                       the list (`List`)
///     interactive/<id>/<version>/<file>      each wallpaper's files
///
/// A wallpaper's files never change under one version: a changed page gets a
/// new version, so a cache that keeps files for a year can never hand an old
/// file to a new list.
///
/// They behave like live wallpapers (owner, 2026-11-19): Explore lists every
/// one from the list, and one is downloaded only when the person asks for it
/// (Download, Preview), into `folder(root:)`, one folder each, laid out the
/// way the ones inside the app used to be (`index.html`, `wallpaper.json`,
/// `thumb.jpg`, `still.jpg`), so everything else treats them exactly as
/// before. A copy is checked file by file against its size and SHA-256
/// before it is used, so nothing swapped on the server can run here.
///
/// Muro before 6.1.2 never reads the list: it keeps the three that came inside
/// it, and catalog.json carries no interactive wallpaper it could mistake for
/// a video.
public enum HostedInteractive {
    /// The list on the server.
    public struct List: Codable, Equatable {
        public var wallpapers: [Entry]

        public init(wallpapers: [Entry] = []) {
            self.wallpapers = wallpapers
        }

        private enum CodingKeys: String, CodingKey { case wallpapers }

        /// One entry this Muro cannot read is left out, never the whole list:
        /// a later Muro may add things to an entry that an older one does not
        /// know.
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

    /// One wallpaper in the list.
    public struct Entry: Codable, Equatable {
        public var id: String
        public var title: String
        /// Who made it, shown as "By …" on its page in the gallery, and
        /// nowhere else: never on a card and never on the desktop.
        public var author: String?
        /// The day it was first published, `yyyy-MM-dd`.
        public var added: String
        /// Where it sits among the others in Explore, lowest first.
        public var order: Int?
        /// Changes whenever any of its files does (`version(of:)`).
        public var version: String
        public var files: [File]

        public init(
            id: String, title: String, author: String?, added: String, order: Int?,
            version: String, files: [File]
        ) {
            self.id = id
            self.title = title
            self.author = author
            self.added = added
            self.order = order
            self.version = version
            self.files = files
        }

        public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    public struct File: Codable, Equatable {
        /// Inside the wallpaper's folder, `/` between folders.
        public var path: String
        public var size: Int64
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    /// The name of the list on the server and of its copy in the library.
    public static let listName = "interactive.json"
    /// The folder inside the library the copies live in.
    public static let folderName = "Hosted Interactive"
    /// What every hosted wallpaper carries: its page, its picture for the
    /// cards and its still for the desktop. `wallpaper.json` is written here
    /// from the list, never downloaded.
    public static let requiredFiles = ["index.html", "thumb.jpg", "still.jpg"]
    public static let largestFile: Int64 = 100 * 1024 * 1024
    public static let largestWallpaper: Int64 = 300 * 1024 * 1024
    /// More files than any real wallpaper has; a list asking for more is wrong.
    public static let mostFiles = 500

    public static func folder(root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The list sits beside catalog.json on the same server.
    public static func listURL(catalogURL: URL) -> URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent(listName)
    }

    /// Where one of a wallpaper's files is on the server whose list is at
    /// `base` (the folder the list is in).
    public static func fileURL(base: URL, entry: Entry, path: String) -> URL {
        var url = base
            .appendingPathComponent("interactive", isDirectory: true)
            .appendingPathComponent(entry.id, isDirectory: true)
            .appendingPathComponent(entry.version, isDirectory: true)
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    // MARK: - What the list may say

    /// A file name a hosted wallpaper may use: lower case letters, digits,
    /// dots, dashes and underscores, in folders, never leaving its own folder
    /// and never hidden. The server's keys follow the same rule.
    public static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 200 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-/")
        guard path.allSatisfy({ allowed.contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && !part.hasPrefix(".")
        }
    }

    public static func isSafeID(_ id: String) -> Bool {
        InteractiveWallpapers.isBuiltIn(id) && !id.contains("/") && isSafePath(id)
    }

    public static func isSafeVersion(_ version: String) -> Bool {
        (6...64).contains(version.count) && version.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Whether Muro will download this entry at all.
    public static func isUsable(_ entry: Entry) -> Bool {
        guard isSafeID(entry.id), isSafeVersion(entry.version),
              !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...mostFiles).contains(entry.files.count),
              entry.totalSize <= largestWallpaper
        else { return false }
        let paths = entry.files.map(\.path)
        guard Set(paths).count == paths.count,
              requiredFiles.allSatisfy(paths.contains),
              !paths.contains(InteractiveWallpapers.infoName)
        else { return false }
        return entry.files.allSatisfy {
            isSafePath($0.path) && (0...largestFile).contains($0.size) && isSHA256($0.sha256)
        }
    }

    /// A wallpaper's version: the start of a SHA-256 over every file's name,
    /// size and SHA-256, so a change to any file gives a new one.
    public static func version(of files: [File]) -> String {
        let lines = files.sorted { $0.path < $1.path }
            .map { "\($0.path) \($0.size) \($0.sha256)\n" }
            .joined()
        return String(sha256(Data(lines.utf8)).prefix(16))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// The last list read, kept beside library.json. Writing it is also what
    /// tells the engine, which watches that folder, to look again.
    public static func saveLocalList(_ list: List, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: root.appendingPathComponent(listName), options: .atomic)
    }

    /// The list `saveLocalList` kept, so Explore lists them offline too. Nil
    /// when there is none or it cannot be read.
    public static func loadLocalList(root: URL) -> List? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(listName)) else { return nil }
        return try? JSONDecoder().decode(List.self, from: data)
    }

    /// What Explore shows for one that is not downloaded, in the shape of a
    /// live wallpaper's catalog entry: its picture is its thumbnail on the
    /// server, its size is all of its files and its date is the day it was
    /// published. `video` names its page, which is never played as a video.
    public static func catalogEntry(for entry: Entry, base: URL) -> CatalogEntry {
        let days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]
        return CatalogEntry(
            id: entry.id,
            title: entry.title,
            category: InteractiveWallpapers.category,
            width: 0, height: 0, fps: 0, duration: 0,
            sizeBytes: entry.totalSize,
            video: fileURL(base: base, entry: entry, path: "index.html"),
            thumbnail: fileURL(base: base, entry: entry, path: "thumb.jpg"),
            publishedAt: days.date(from: entry.added)
        )
    }

    // MARK: - Keeping the copies

    public struct SyncResult: Equatable, Sendable {
        public var added: [String] = []
        public var updated: [String] = []
        public var removed: [String] = []
        public var failed: [String] = []
        public var changed: Bool { !(added.isEmpty && updated.isEmpty && removed.isEmpty) }

        public init() {}
    }

    /// The version of the copy in `folder`, when every file the list names is
    /// there at the size it should be.
    static func installedVersion(of entry: Entry, in home: URL) -> String? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(InteractiveWallpapers.infoName)),
              let info = try? JSONDecoder().decode(InstalledInfo.self, from: data)
        else { return nil }
        let manager = FileManager.default
        for file in entry.files {
            let url = home.appendingPathComponent(file.path)
            guard let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.int64Value == file.size
            else { return nil }
        }
        return info.version
    }

    private struct InstalledInfo: Decodable {
        var version: String?
    }

    /// What is written as `wallpaper.json` into a copy: everything
    /// `InteractiveWallpapers.entries(in:)` reads, plus the version.
    private struct WrittenInfo: Encodable {
        var id: String
        var title: String
        var author: String?
        var added: String
        var order: Int?
        var version: String
    }

    /// Brings the copies in line with what the person has.
    ///
    /// `wanted` is every one the person has: in the Library, on a screen, in
    /// a playlist or an automation. Those are downloaded when they are
    /// missing (an update from 6.1.1, where they came inside the app) or
    /// changed on the server. Every file is checked against its size and
    /// SHA-256, and only then is the folder swapped in: until a new copy is
    /// complete and checked, the old one stays where it is. Nothing else is
    /// downloaded, and a copy nobody has any more is removed, listed or not.
    ///
    /// Never run beside `download` or another sync: the caller takes them
    /// one at a time.
    public static func sync(
        list: List, base: URL, root: URL, wanted: Set<String>,
        session: URLSession = .shared
    ) async -> SyncResult {
        var result = SyncResult()
        let manager = FileManager.default
        let home = folder(root: root)
        try? manager.createDirectory(at: home, withIntermediateDirectories: true)

        // Leftovers of a download that was cut short.
        for name in (try? manager.contentsOfDirectory(atPath: home.path)) ?? [] where name.hasPrefix(".") {
            try? manager.removeItem(at: home.appendingPathComponent(name))
        }

        var listed = Set<String>()
        for entry in list.wallpapers {
            guard isUsable(entry), listed.insert(entry.id).inserted else {
                result.failed.append(entry.id)
                continue
            }
            guard wanted.contains(entry.id) else { continue }
            let target = home.appendingPathComponent(entry.id, isDirectory: true)
            let existed = manager.fileExists(atPath: target.path)
            if installedVersion(of: entry, in: target) == entry.version { continue }
            do {
                try await install(entry, base: base, into: home, session: session, progress: nil)
                if existed { result.updated.append(entry.id) } else { result.added.append(entry.id) }
            } catch {
                result.failed.append(entry.id)
            }
        }

        // One in use stays even when the list drops it.
        for name in (try? manager.contentsOfDirectory(atPath: home.path)) ?? []
        where !name.hasPrefix(".") && !wanted.contains(name) {
            if (try? manager.removeItem(at: home.appendingPathComponent(name))) != nil {
                result.removed.append(name)
            }
        }
        return result
    }

    /// Downloads one wallpaper the person asked for, checked like `sync`
    /// checks, telling `progress` how far it is from 0 to 1. A copy already
    /// here at this version is left as it is.
    ///
    /// Never run beside `sync` or another download: the caller takes them
    /// one at a time.
    public static func download(
        _ entry: Entry, base: URL, root: URL, session: URLSession = .shared,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard isUsable(entry) else { throw InstallError.unusable }
        let home = folder(root: root)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let target = home.appendingPathComponent(entry.id, isDirectory: true)
        if installedVersion(of: entry, in: target) == entry.version {
            progress?(1)
            return
        }
        try await install(entry, base: base, into: home, session: session, progress: progress)
    }

    enum InstallError: Error { case unusable, badResponse, wrongSize, wrongChecksum }

    private static func install(
        _ entry: Entry, base: URL, into home: URL, session: URLSession,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let manager = FileManager.default
        let incoming = home.appendingPathComponent(".incoming-\(entry.id)", isDirectory: true)
        try? manager.removeItem(at: incoming)
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        let total = max(entry.totalSize, 1)
        var done: Int64 = 0
        do {
            for file in entry.files {
                let request = URLRequest(
                    url: fileURL(base: base, entry: entry, path: file.path),
                    cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60
                )
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw InstallError.badResponse
                }
                guard Int64(data.count) == file.size else { throw InstallError.wrongSize }
                guard sha256(data) == file.sha256 else { throw InstallError.wrongChecksum }
                let destination = incoming.appendingPathComponent(file.path)
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
                done += file.size
                progress?(min(1, Double(done) / Double(total)))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let info = WrittenInfo(
                id: entry.id, title: entry.title, author: entry.author,
                added: entry.added, order: entry.order, version: entry.version
            )
            try encoder.encode(info).write(
                to: incoming.appendingPathComponent(InteractiveWallpapers.infoName), options: .atomic
            )

            let target = home.appendingPathComponent(entry.id, isDirectory: true)
            if manager.fileExists(atPath: target.path) {
                let old = home.appendingPathComponent(".old-\(entry.id)-\(UUID().uuidString)", isDirectory: true)
                try manager.moveItem(at: target, to: old)
                do {
                    try manager.moveItem(at: incoming, to: target)
                } catch {
                    try? manager.moveItem(at: old, to: target)
                    throw error
                }
                try? manager.removeItem(at: old)
            } else {
                try manager.moveItem(at: incoming, to: target)
            }
        } catch {
            try? manager.removeItem(at: incoming)
            throw error
        }
    }

    // MARK: - Checking a page before it is published

    /// Every place a page's code reaches outside its own folder: web
    /// addresses, network calls, scripts or styles from elsewhere. The page
    /// is shut in when it runs (`InteractivePage`), so this is for the person
    /// publishing: a wallpaper that tries any of it is not one to host.
    public static func outsideReferences(in text: String) -> [String] {
        let patterns = [
            #"(?i)\b(https?|wss?|ftp):\/\/[^\s"'<>)]+"#,
            #"(?i)(src|href)\s*=\s*["']?\/\/[^\s"'<>]+"#,
            #"(?i)url\(\s*["']?\/\/[^\s"')]+"#,
            #"\bfetch\s*\("#,
            #"\bXMLHttpRequest\b"#,
            #"\bWebSocket\b"#,
            #"\bEventSource\b"#,
            #"\bsendBeacon\b"#,
            #"\bimportScripts\s*\("#,
            #"\bimport\s*\("#,
            #"\bwindow\.open\s*\("#,
        ]
        // Names in markup that only look like addresses: nothing is fetched.
        let harmless = ["http://www.w3.org/", "https://www.w3.org/"]
        // Pictures built into the page are data, not code, and long runs of
        // it can spell anything by chance.
        let text = text.replacingOccurrences(
            of: #"data:[a-zA-Z0-9.+/-]+(;base64)?,[A-Za-z0-9+/=%]+"#, with: "data:",
            options: .regularExpression
        )
        var found: [String] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                guard let span = Range(match.range, in: text) else { continue }
                let hit = String(text[span])
                if harmless.contains(where: hit.hasPrefix) { continue }
                if !found.contains(hit) { found.append(hit) }
            }
        }
        return found
    }
}

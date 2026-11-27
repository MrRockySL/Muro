import Foundation

/// Colour options: a few live wallpapers offered in three more colours beside
/// their original (owner, 2026-11-27: "original plus 3 for each").
///
/// On the server, beside catalog.json:
///
///     colors.json                                    the list (`List`)
///     colors/<wallpaper id>/<key>/<version>/<file>   each colour's files
///
/// A Muro that does not know them never reads the list, and catalog.json
/// carries none of them, so an older Muro sees only the original colour.
///
/// Each colour is a live wallpaper of its own, with its own id
/// (`id(family:key:)`) and its own master, 720p preview and card picture,
/// made once from the original with the same colour change on every frame.
/// It is downloaded and set exactly like any other live wallpaper, so the
/// desktop, the lock screen, the screen saver and every display can each show
/// a different colour, at the same low CPU. The original stays the catalog's
/// own wallpaper, untouched.
public enum HostedColors {
    /// The name of the list on the server and of its copy in the library.
    public static let listName = "colors.json"
    /// Every colour's id starts with this.
    public static let idPrefix = "color-"
    /// The folder on the server the colours' files live in.
    public static let serverFolder = "colors"
    /// Explore's section for them, after Static. Not a category: every
    /// wallpaper keeps its own. Shown as "Colors".
    public static let section = "Colors"
    /// The file names inside each colour's folder on the server.
    public static let masterName = "master.mov"
    public static let previewName = "p720.mov"
    public static let thumbnailName = "thumb.jpg"
    public static let largestMaster: Int64 = 1024 * 1024 * 1024
    public static let largestPreview: Int64 = 40 * 1024 * 1024
    public static let largestThumbnail: Int64 = 5 * 1024 * 1024
    /// At most this many colours beside the original.
    public static let mostColors = 7

    /// The list on the server.
    public struct List: Codable, Equatable {
        public var wallpapers: [Family]

        public init(wallpapers: [Family] = []) {
            self.wallpapers = wallpapers
        }

        private enum CodingKeys: String, CodingKey { case wallpapers }

        /// One entry this Muro cannot read is left out, never the whole list.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var items = try container.nestedUnkeyedContainer(forKey: .wallpapers)
            var read: [Family] = []
            while !items.isAtEnd {
                if let family = try? items.decode(Family.self) {
                    read.append(family)
                } else {
                    _ = try? items.decode(Skipped.self)
                }
            }
            wallpapers = read
        }

        private struct Skipped: Decodable {}
    }

    /// One live wallpaper and its colours.
    public struct Family: Codable, Equatable {
        /// The live wallpaper in catalog.json, the original colour.
        public var id: String
        /// The original's own colour, for its dot.
        public var original: Swatch
        /// The other colours, in the order their dots show.
        public var colors: [Variant]
        /// Pinned to the front of the Colors section, lowest first.
        public var order: Int?
        /// The day its colours were first published, `yyyy-MM-dd`.
        public var added: String

        public init(id: String, original: Swatch, colors: [Variant], order: Int?, added: String) {
            self.id = id
            self.original = original
            self.colors = colors
            self.order = order
            self.added = added
        }
    }

    /// A colour's name and its dot.
    public struct Swatch: Codable, Equatable {
        /// Lower case, a to z, as in its id: "red".
        public var key: String
        /// In English, the way the list names it: "Red".
        public var name: String
        /// The dot's colour, "#RRGGBB".
        public var hex: String

        public init(key: String, name: String, hex: String) {
            self.key = key
            self.name = name
            self.hex = hex
        }
    }

    /// One more colour of the family's live wallpaper.
    public struct Variant: Codable, Equatable {
        public var key: String
        public var name: String
        public var hex: String
        /// Changes whenever any of its files does (`version(master:preview:thumbnail:)`).
        public var version: String
        public var width: Int
        public var height: Int
        public var fps: Double
        public var duration: Double
        public var master: HostedInteractive.File
        public var preview: HostedInteractive.File
        public var thumbnail: HostedInteractive.File

        public init(
            key: String, name: String, hex: String, version: String,
            width: Int, height: Int, fps: Double, duration: Double,
            master: HostedInteractive.File, preview: HostedInteractive.File,
            thumbnail: HostedInteractive.File
        ) {
            self.key = key
            self.name = name
            self.hex = hex
            self.version = version
            self.width = width
            self.height = height
            self.fps = fps
            self.duration = duration
            self.master = master
            self.preview = preview
            self.thumbnail = thumbnail
        }

        public var swatch: Swatch { Swatch(key: key, name: name, hex: hex) }
    }

    // MARK: - Ids

    /// A colour's own id: "color-red-<the original's id>".
    public static func id(family: String, key: String) -> String {
        "\(idPrefix)\(key)-\(family)"
    }

    public static func isColor(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The colour's key and its original's id, from a colour's id.
    public static func parse(_ id: String) -> (key: String, family: String)? {
        guard isColor(id) else { return nil }
        let rest = id.dropFirst(idPrefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let key = String(rest[..<dash])
        let family = String(rest[rest.index(after: dash)...])
        guard isSafeKey(key), isSafeFamilyID(family) else { return nil }
        return (key, family)
    }

    /// The original's id for any member of a family: itself for the
    /// original, the part after the key for a colour.
    public static func familyID(of id: String) -> String {
        parse(id)?.family ?? id
    }

    // MARK: - What the list may say

    public static func isSafeKey(_ key: String) -> Bool {
        (1...16).contains(key.count) && key.allSatisfy { ("a"..."z").contains($0) }
    }

    public static func isSafeFamilyID(_ id: String) -> Bool {
        id.count <= 128 && !id.contains("/") && !isColor(id) && HostedInteractive.isSafePath(id)
    }

    public static func isHex(_ value: String) -> Bool {
        value.count == 7 && value.first == "#"
            && value.dropFirst().allSatisfy { "0123456789abcdefABCDEF".contains($0) }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isSafeFile(_ file: HostedInteractive.File, name: String, largest: Int64) -> Bool {
        file.path == name && (1...largest).contains(file.size) && isSHA256(file.sha256)
    }

    private static func isSafeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 24
    }

    public static func isUsable(_ swatch: Swatch) -> Bool {
        isSafeKey(swatch.key) && isSafeName(swatch.name) && isHex(swatch.hex)
    }

    public static func isUsable(_ variant: Variant) -> Bool {
        isUsable(variant.swatch) && HostedInteractive.isSafeVersion(variant.version)
            && (1...16384).contains(variant.width) && (1...16384).contains(variant.height)
            && variant.fps > 0 && variant.fps <= 240
            && variant.duration > 0 && variant.duration <= 3600
            && isSafeFile(variant.master, name: masterName, largest: largestMaster)
            && isSafeFile(variant.preview, name: previewName, largest: largestPreview)
            && isSafeFile(variant.thumbnail, name: thumbnailName, largest: largestThumbnail)
    }

    /// Whether Muro will offer this family's colours at all. One colour it
    /// cannot use takes the whole family out, so the dots never disagree
    /// with the COLORS label.
    public static func isUsable(_ family: Family) -> Bool {
        guard isSafeFamilyID(family.id), isUsable(family.original),
              (1...mostColors).contains(family.colors.count),
              family.added.count == 10,
              family.colors.allSatisfy(isUsable)
        else { return false }
        let keys = [family.original.key] + family.colors.map(\.key)
        return Set(keys).count == keys.count
    }

    /// A colour's version: the start of a SHA-256 over its files' names,
    /// sizes and SHA-256s, so a change to any of them gives a new one.
    public static func version(
        master: HostedInteractive.File, preview: HostedInteractive.File, thumbnail: HostedInteractive.File
    ) -> String {
        HostedInteractive.version(of: [master, preview, thumbnail])
    }

    /// The Colors section's order: the pinned ones first, lowest `order`
    /// first, then everything else newest first.
    public static func sorted(_ families: [Family]) -> [Family] {
        families.sorted { a, b in
            switch (a.order, b.order) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if a.added != b.added { return a.added > b.added }
                return a.id < b.id
            }
        }
    }

    // MARK: - Where things are

    /// The list sits beside catalog.json on the same server.
    public static func listURL(catalogURL: URL) -> URL {
        catalogURL.deletingLastPathComponent().appendingPathComponent(listName)
    }

    /// Where one of a colour's files is on the server whose list is at
    /// `base` (the folder the list is in).
    public static func fileURL(base: URL, family: String, variant: Variant, file: HostedInteractive.File) -> URL {
        base.appendingPathComponent(serverFolder, isDirectory: true)
            .appendingPathComponent(family, isDirectory: true)
            .appendingPathComponent(variant.key, isDirectory: true)
            .appendingPathComponent(variant.version, isDirectory: true)
            .appendingPathComponent(file.path)
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

    /// The list `saveLocalList` kept, so the colours show offline too.
    public static func loadLocalList(root: URL) -> List? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(listName)) else { return nil }
        return try? JSONDecoder().decode(List.self, from: data)
    }

    // MARK: - As live wallpapers

    /// One colour in the shape of a catalog entry, so it is downloaded,
    /// listed and set like any live wallpaper: the original's title and
    /// category, its own files and size.
    public static func catalogEntry(
        for variant: Variant, family: Family, original: CatalogEntry, base: URL
    ) -> CatalogEntry {
        let days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]
        return CatalogEntry(
            id: id(family: family.id, key: variant.key),
            title: original.title,
            category: original.category,
            width: variant.width, height: variant.height,
            fps: variant.fps, duration: variant.duration,
            sizeBytes: variant.master.size,
            video: fileURL(base: base, family: family.id, variant: variant, file: variant.master),
            thumbnail: fileURL(base: base, family: family.id, variant: variant, file: variant.thumbnail),
            preview720: fileURL(base: base, family: family.id, variant: variant, file: variant.preview),
            publishedAt: days.date(from: family.added)
        )
    }

    /// Every colour of every usable family whose original is in the catalog,
    /// as catalog entries.
    public static func catalogEntries(list: List, catalog: [CatalogEntry], base: URL) -> [CatalogEntry] {
        let originals = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [CatalogEntry] = []
        var seen = Set<String>()
        for family in sorted(list.wallpapers) where isUsable(family) && seen.insert(family.id).inserted {
            guard let original = originals[family.id] else { continue }
            for variant in family.colors {
                out.append(catalogEntry(for: variant, family: family, original: original, base: base))
            }
        }
        return out
    }
}

extension WallpaperEntry {
    /// One of a live wallpaper's other colours (`HostedColors`).
    public var isColor: Bool { HostedColors.isColor(id) }
}

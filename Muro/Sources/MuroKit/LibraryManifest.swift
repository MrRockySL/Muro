import Foundation

/// One wallpaper in the Muro library. Paths are relative to the library root
/// so the whole library folder can be moved without breaking the manifest.
public struct WallpaperEntry: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var category: String
    public var file: String        // e.g. "Masters/<id>.mov"
    public var efficientFile: String?  // lazy 30 fps variant, once generated
    public var previewFile: String?    // short 720p loop, e.g. "Previews/<id>-p720.mov"
    public var thumbnail: String   // e.g. "Thumbnails/<id>.jpg"
    public var width: Int
    public var height: Int
    public var fps: Double
    public var duration: Double
    public var sizeBytes: Int64
    public var liked: Bool
    public var dateAdded: Date
    /// Per wallpaper "pause after", overriding the global setting. Nil means
    /// follow the setting; a value here wins for this wallpaper only.
    public var pauseAfterSeconds: Int?

    public init(
        id: String, title: String, category: String, file: String,
        efficientFile: String? = nil, previewFile: String? = nil,
        thumbnail: String, width: Int,
        height: Int, fps: Double, duration: Double, sizeBytes: Int64,
        liked: Bool = false, dateAdded: Date = Date(),
        pauseAfterSeconds: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.file = file
        self.efficientFile = efficientFile
        self.previewFile = previewFile
        self.thumbnail = thumbnail
        self.width = width
        self.height = height
        self.fps = fps
        self.duration = duration
        self.sizeBytes = sizeBytes
        self.liked = liked
        self.dateAdded = dateAdded
        self.pauseAfterSeconds = pauseAfterSeconds
    }

    /// Every file this wallpaper owns inside the library root. Deleting a
    /// wallpaper means deleting exactly these, and each place that built the
    /// list by hand was one more chance to forget the preview or the
    /// efficient variant and leave it on disk forever.
    public var relativeFiles: [String] {
        [file, efficientFile, previewFile, thumbnail].compactMap { $0 }
    }
}

public struct LibraryManifest: Codable {
    public var wallpapers: [WallpaperEntry]

    public init(wallpapers: [WallpaperEntry] = []) {
        self.wallpapers = wallpapers
    }

    // MARK: - Location

    /// Default library root: ~/Library/Application Support/Muro
    public static func defaultRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Muro", isDirectory: true)
    }

    public static func manifestURL(root: URL) -> URL {
        root.appendingPathComponent("library.json")
    }

    // MARK: - Load / save

    public static func load(root: URL) -> LibraryManifest {
        loadIfPresent(root: root) ?? LibraryManifest()
    }

    /// `nil` when there is no manifest to read: none written yet, or one on
    /// disk that does not decode.
    ///
    /// `load` answers both with an empty manifest, which is what a caller
    /// about to add a wallpaper wants and the opposite of what a caller
    /// wanting to know what is in use wants. To the second kind, "no entries"
    /// and "I could not read the entries" have to be different answers, or a
    /// library it simply failed to open looks like a library holding nothing.
    public static func loadIfPresent(root: URL) -> LibraryManifest? {
        let url = manifestURL(root: root)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibraryManifest.self, from: data)
    }

    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: LibraryManifest.manifestURL(root: root), options: .atomic)
    }
}

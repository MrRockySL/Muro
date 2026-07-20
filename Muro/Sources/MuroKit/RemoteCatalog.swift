import Foundation

/// One wallpaper in the hosted catalog (catalog.json on a static host,
/// e.g. GitHub Releases). Mirrors WallpaperEntry metadata plus the URLs
/// needed to stream the thumbnail and download the video on demand.
public struct CatalogEntry: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var category: String
    public var width: Int
    public var height: Int
    public var fps: Double
    public var duration: Double
    public var sizeBytes: Int64
    public var video: URL
    public var thumbnail: URL
    /// Short 720p loop for the detail view. Optional so catalogs published
    /// before previews existed keep decoding — absent means the detail view
    /// falls back to the static thumbnail.
    public var preview720: URL?

    public init(
        id: String, title: String, category: String, width: Int, height: Int,
        fps: Double, duration: Double, sizeBytes: Int64, video: URL, thumbnail: URL,
        preview720: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.width = width
        self.height = height
        self.fps = fps
        self.duration = duration
        self.sizeBytes = sizeBytes
        self.video = video
        self.thumbnail = thumbnail
        self.preview720 = preview720
    }
}

public struct RemoteCatalog: Codable {
    public var wallpapers: [CatalogEntry]

    public init(wallpapers: [CatalogEntry] = []) {
        self.wallpapers = wallpapers
    }

    /// Always goes to the network. catalog.json is served with
    /// `Cache-Control: max-age=300`, and URLSession's default policy honors
    /// that from a *disk* cache — so newly published wallpapers would stay
    /// invisible for five minutes even across app relaunches, and every
    /// relaunch in that window would be a no-op. Ignoring the local cache
    /// leaves only the CDN's own ~5 minute window, which we can't bypass
    /// (raw.githubusercontent.com keys its cache without the query string,
    /// so a cache-busting parameter does nothing).
    public static func fetch(from url: URL) async throws -> RemoteCatalog {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(RemoteCatalog.self, from: data)
    }
}

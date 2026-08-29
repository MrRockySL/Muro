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
    /// When this wallpaper first reached the catalog, stamped once by
    /// muro-publish and preserved across republishes. Without it the app has
    /// no way to tell a wallpaper published today from one published a year
    /// ago — a local `dateAdded` only says when *this user* downloaded it.
    /// Optional so catalogs published before the field existed still decode.
    public var publishedAt: Date?

    public init(
        id: String, title: String, category: String, width: Int, height: Int,
        fps: Double, duration: Double, sizeBytes: Int64, video: URL, thumbnail: URL,
        preview720: URL? = nil, publishedAt: Date? = nil
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
        self.publishedAt = publishedAt
    }
}

public struct RemoteCatalog: Codable {
    public var wallpapers: [CatalogEntry]

    public init(wallpapers: [CatalogEntry] = []) {
        self.wallpapers = wallpapers
    }

    /// Reader and writer must agree on how `publishedAt` is encoded, and they
    /// live in different targets (the app decodes, muro-publish encodes), so
    /// both come from here rather than each constructing its own coder.
    /// ISO-8601 keeps catalog.json readable by eye.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Always goes to the network. catalog.json is served with
    /// `Cache-Control: max-age=300`, and URLSession's default policy honors
    /// that from a *disk* cache — so newly published wallpapers would stay
    /// invisible for five minutes even across app relaunches, and every
    /// relaunch in that window would be a no-op. Ignoring the local cache
    /// leaves only the CDN's own ~5 minute window, which we can't bypass
    /// (raw.githubusercontent.com keys its cache without the query string,
    /// so a cache-busting parameter does nothing).
    ///
    /// Throws a `CatalogError`, never a raw transport or decoding error. The
    /// caller has to tell a blocked connection apart from a rate limited CDN
    /// apart from a catalog it simply could not read, because those are three
    /// different sentences to put in front of a person.
    public static func fetch(from url: URL) async throws -> RemoteCatalog {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CatalogError.classify(error)
        }

        // The status used to be discarded, and that is the whole bug. Every
        // error a static host returns arrives as a body: r2.dev answers a rate
        // limit or a missing key with a 27 KB HTML page. Handing that to the
        // decoder produced a decoding failure, which the app swallowed, so a
        // throttled CDN and an empty catalog were the same thing to it.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.server(status: http.statusCode)
        }

        do {
            return try makeDecoder().decode(RemoteCatalog.self, from: data)
        } catch {
            throw CatalogError.unreadable
        }
    }
}

/// Why the catalog did not arrive, in the three shapes a person can act on.
///
/// Explore used to answer all of them with "Nothing matches that", which
/// blames the user's filters for something they cannot see and cannot fix by
/// changing a filter. A user reported exactly that: an empty Explore reads as
/// a broken app rather than a blocked connection.
public enum CatalogError: LocalizedError, Equatable {
    /// Nothing reached the server at all: offline, a host that will not
    /// resolve, a timeout, or a VPN, firewall or DNS filter in the way.
    case unreachable
    /// The server answered, and not with the catalog. 429 is the r2.dev rate
    /// limit, 5xx is the CDN being unwell, 404 is a bucket that has moved.
    case server(status: Int)
    /// A 200 that was not the wallpaper list. A captive portal sign in page
    /// and a filter's block page both arrive looking exactly like this.
    case unreadable

    /// The headline. Short enough to sit under an icon.
    public var title: String {
        switch self {
        case .unreachable: return "Muro cannot reach the internet"
        case .server: return "The wallpaper catalog is not answering"
        case .unreadable: return "Something is blocking the wallpaper catalog"
        }
    }

    /// What to do about it. Never blames the filters, always names the causes
    /// people actually hit.
    public var detail: String {
        switch self {
        case .unreachable:
            return """
            Check that you are online, then try again. A VPN, a firewall or a \
            DNS filter can also stop Muro reaching its wallpapers.
            """
        case .server(let status):
            return """
            The server answered with an error (\(status)). This is usually \
            temporary, so try again in a minute.
            """
        case .unreadable:
            return """
            Muro reached the catalog but what came back was not the wallpaper \
            list. A VPN, a company network or a DNS filter can do this.
            """
        }
    }

    public var errorDescription: String? { "\(title). \(detail)" }

    /// Everything that can go wrong on the way to a catalog, sorted into the
    /// three cases. Anything unrecognised counts as unreachable, which is the
    /// safe guess: it sends the user to look at their connection rather than
    /// at a filter that was never the problem.
    public static func classify(_ error: Error) -> CatalogError {
        if let catalogError = error as? CatalogError { return catalogError }
        if error is DecodingError { return .unreadable }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badServerResponse, .cannotParseResponse, .zeroByteResource:
                return .unreadable
            default:
                return .unreachable
            }
        }
        return .unreachable
    }
}

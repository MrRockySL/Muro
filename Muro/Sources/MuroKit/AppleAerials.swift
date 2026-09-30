import Foundation

/// Apple's own aerial wallpapers, read from the store macOS already keeps on
/// the Mac.
///
/// **Why this exists.** n3rvino asked for it in issue #7: a Mac already ships
/// with Apple's aerials, and Muro is the app people are looking at when they
/// want a moving wallpaper. Rebuilding that library would mean hosting a few
/// hundred gigabytes of Apple's video, which is neither legal nor affordable.
///
/// **So nothing here is copied.** Everything below reads files macOS put on
/// the Mac itself and points at them where they lie:
///
/// - `manifest/entries.json` is Apple's own catalogue, about 190 KB, listing
///   every aerial with its id, category and two URLs on Apple's CDN.
/// - `thumbnails/<id>.png` is one still per aerial, about 40 KB. Measured on
///   the owner's Mac 2026-09-08: **164 aerials, 164 thumbnails, 4 videos**.
///   That is the whole point. The gallery is free to show; only the one
///   wallpaper somebody actually picks is ever fetched.
/// - `videos/<id>.mov` is there only for aerials this Mac has downloaded.
///
/// **The download is Apple's, not ours.** `videoURL` is the address in Apple's
/// own manifest, served from Apple's CDN, so a user pulling a 400 MB aerial
/// costs Muro's R2 bucket nothing.
///
/// **Two locations, because Apple moved it.** macOS 26 and later keep this per
/// user under `com.apple.wallpaper`; older releases kept it system-wide under
/// `com.apple.idleassetsd`. Both are checked, newest first.
///
/// ⚠️ **Every one is 240 fps.** Counted on a real file, 28,804 frames in 120
/// seconds. They are nothing like the 4K30 Muro publishes, and that is why
/// `WallpaperEntry.fps` below reports the truth rather than a comfortable
/// number. Sizes, lengths and resolutions vary a lot; see `Format`.
public enum AppleAerials {

    // MARK: - Where macOS keeps it

    /// Every root worth looking in, newest layout first.
    ///
    /// Returned rather than resolved to one so a Mac carrying both (an
    /// upgrade that never cleaned up) is read from the current one.
    public static func candidateRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
                .appendingPathComponent("aerials", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer",
                isDirectory: true)
        ]
    }

    /// The first root that actually holds a manifest we can read.
    public static func resolvedRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        candidateRoots(home: home).first { manifestURL(root: $0) != nil }
    }

    /// `entries.json` inside a root, wherever Apple put it in that layout.
    public static func manifestURL(root: URL) -> URL? {
        let candidates = [
            root.appendingPathComponent("manifest/entries.json"),
            root.appendingPathComponent("entries.json")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The localisation table that turns `localizedNameKey` into a real title.
    ///
    /// Optional on purpose. A missing table costs the gallery its names, which
    /// is a worse gallery, not a broken one, and `AppleAerial.name` falls back
    /// through `accessibilityLabel` to the key itself.
    public static func stringsURL(root: URL) -> URL? {
        let bundle = "manifest/TVIdleScreenStrings.bundle/Contents/Resources"
        let candidates = [
            root.appendingPathComponent("\(bundle)/Localizable.nocache.loctable"),
            root.appendingPathComponent(
                "TVIdleScreenStrings.bundle/Contents/Resources/Localizable.nocache.loctable")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where Muro keeps aerials it fetched itself: the same `Masters` folder
    /// as every other wallpaper video, so they go wherever the person chose
    /// to keep their wallpapers (see `DownloadFolder`). An aerial is 37 MB to
    /// 1.5 GB, which is exactly the kind of file someone moves to another
    /// drive, and a move of that folder carries these along with the rest.
    ///
    /// **Muro never writes into Apple's store.** macOS owns
    /// `com.apple.wallpaper`, deletes from it on its own schedule, and an app
    /// putting files there would be reaching into somebody else's data with no
    /// way to be sure of the shape. Muro's own copies go here, where they can
    /// be counted, shown as reclaimable space, and removed with the feature.
    ///
    /// One file per aerial, named `apple-<Apple's id>.mov`, and no manifest:
    /// the file's own presence is the record, so nothing can disagree with the
    /// disk. The prefix is what keeps `LibraryWriter.sweepOrphans` off them,
    /// since `library.json` never lists them.
    public static func cacheDir(libraryRoot: URL) -> URL {
        DownloadFolder.mastersURL(root: libraryRoot)
    }

    /// The name of Muro's own copy of one aerial inside `cacheDir`.
    public static func downloadFileName(assetID: String) -> String {
        "\(idPrefix)\(assetID).mov"
    }

    /// Everything Muro downloaded from Apple, and nothing else in the
    /// folder: aerials (`.mov`) and the light and dark cuts of Apple's still
    /// pictures (`.heic`). Each file is named after the card it belongs to,
    /// so its name without the extension is that card's id.
    public static func downloadedFiles(libraryRoot: URL) -> [URL] {
        let dir = cacheDir(libraryRoot: libraryRoot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.hasPrefix(idPrefix) && ($0.hasSuffix(".mov") || $0.hasSuffix(".heic")) }
            .map { dir.appendingPathComponent($0) }
    }

    /// Everything this feature has ever put on disk, for removing it.
    ///
    /// Muro's own aerial downloads and the pictures and facts kept in the
    /// cache. Nothing is written to `library.json`, nothing to Apple's store,
    /// nothing to `UserDefaults` beyond the pill the gallery was last left on.
    /// Every other video in `Masters` is left exactly where it is.
    @discardableResult
    public static func purgeCache(libraryRoot: URL) -> Int64 {
        let size = cacheSize(libraryRoot: libraryRoot)
        for file in downloadedFiles(libraryRoot: libraryRoot) {
            try? FileManager.default.removeItem(at: file)
        }
        AppleAerialInfo.clear()
        invalidateCache()
        return size
    }

    public static func cacheSize(libraryRoot: URL) -> Int64 {
        downloadedFiles(libraryRoot: libraryRoot).reduce(Int64(0)) { total, file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            return total + (((attributes?[.size]) as? NSNumber)?.int64Value ?? 0)
        }
    }

    public static func thumbnailsDir(root: URL) -> URL {
        root.appendingPathComponent("thumbnails", isDirectory: true)
    }

    public static func videosDir(root: URL) -> URL {
        root.appendingPathComponent("videos", isDirectory: true)
    }

    // MARK: - Ids

    /// Muro's id for an Apple aerial: Apple's UUID behind a prefix.
    ///
    /// Three jobs at once. It cannot collide with a Muro wallpaper id, which
    /// is a bare UUID. It is safe in a path, which a colon would not be, and
    /// `LockScreenService` builds a directory out of this. And it makes every
    /// trace of this feature findable in `config.json`, playlists and
    /// automations with one string compare, which is what lets the feature be
    /// removed cleanly (see `isAppleID`).
    public static let idPrefix = "apple-"

    public static func muroID(assetID: String) -> String { idPrefix + assetID }

    public static func isAppleID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Ids of the Dynamic Wallpapers only macOS can show: still pictures and
    /// the ones drawn by code. Muro never downloads or plays these itself.
    public static let picturePrefix = idPrefix + "picture-"
    public static let drawnPrefix = idPrefix + "drawn-"
    /// The ones found beside Apple's list that are videos, like Tahoe.
    public static let dynamicVideoPrefix = idPrefix + "dynamic-"

    public static func isMacOSOnly(_ id: String) -> Bool {
        id.hasPrefix(picturePrefix) || id.hasPrefix(drawnPrefix)
            || id.hasPrefix(AppleScreenSavers.idPrefix)
    }

    public static func assetID(fromMuroID id: String) -> String? {
        guard isAppleID(id) else { return nil }
        return String(id.dropFirst(idPrefix.count))
    }
}

// MARK: - One aerial

/// One of Apple's aerials, as Muro sees it.
public struct AppleAerial: Identifiable, Equatable, Sendable {
    /// Muro's id, `apple-<Apple's UUID>`.
    public let id: String
    /// Apple's own UUID, which names its files.
    public let assetID: String
    public let name: String
    /// The display name of Apple's top-level category, already localised:
    /// "Landscape", "Cityscape", "Underwater", "Earth", "Mac",
    /// "Dynamic Wallpapers".
    public let category: String
    /// Where Apple's category sits in Apple's own order, so Muro's pills read
    /// in the order System Settings uses rather than alphabetically.
    public let categoryOrder: Int
    /// Apple's own order within the category.
    public let order: Int
    /// The still already on this Mac. Absolute. Nil only when macOS has not
    /// laid one down.
    public let thumbnailPath: String?
    /// Apple's CDN preview image, the fallback when there is no local still.
    public let previewImageURL: URL?
    /// Apple's CDN address for the 4K video. This is what a download reads.
    public let videoURL: URL
    /// Where macOS keeps the video, if macOS has ever downloaded it.
    /// Absolute, inside Apple's own store, and **read only to Muro**.
    public let applePath: String
    /// Where Muro keeps its own copy, when it is Muro that fetched it.
    /// Absolute, inside Muro's library, and the only one Muro may delete.
    public let cachePath: String
    /// Apple ships its four dynamic wallpapers in two cuts, a wide one for a
    /// Mac and a tall one for an iPad. The tall one is no use on a desktop and
    /// is filtered out, so this exists only to recognise it.
    public let isPortrait: Bool
    /// True when `thumbnailPath` is a picture of this video at some moment,
    /// which is so for everything in Apple's aerial list. The dynamic
    /// wallpapers found elsewhere carry a picture of the light and dark cuts
    /// side by side instead, so there is no moment of the video to match it
    /// to, and the sharp picture is simply the first frame.
    public let stillMatchesVideo: Bool
    /// Whether Muro plays it, or only macOS can show it. See `Kind`.
    public let kind: Kind
    /// What is known without asking Apple's servers, from the file macOS
    /// keeps about it. Only Apple's still pictures have this.
    public let knownWidth: Int?
    public let knownHeight: Int?
    public let knownBytes: Int64?

    /// Apple's Dynamic Wallpapers come in three kinds, and only the first is
    /// a video Muro can play.
    public enum Kind: String, Sendable {
        /// A video: every aerial, and Golden Gate, Tahoe and Sonoma.
        case video
        /// Drawn live by code inside macOS, like Sequoia and Macintosh. There
        /// is no video to play; only macOS can show it.
        case drawn
        /// A still picture that changes between light and dark, some by the
        /// time of day, like Big Sur or The Beach.
        case picture
        /// A screen saver, Apple's own or an installed `.saver`. Only macOS
        /// runs it. See `AppleScreenSavers`.
        case screenSaver
    }
    /// The copy to play, Apple's first.
    ///
    /// Apple's is preferred so a Mac that already holds the aerial never
    /// downloads hundreds of megabytes of it a second time. Nil when neither
    /// is there.
    ///
    /// Deliberately re-read rather than stored: macOS deletes its copies on
    /// its own when space runs short, which is the failure this has to
    /// survive. Nothing may assume a video seen once is still there.
    public var playablePath: String? {
        guard kind == .video else { return nil }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: applePath) { return applePath }
        if fileManager.fileExists(atPath: cachePath) { return cachePath }
        return nil
    }

    public var isDownloaded: Bool { playablePath != nil }

    /// True when the copy on disk is Muro's own, which is the only case where
    /// anything may be deleted. Apple's copy belongs to macOS.
    public var hasMuroCopy: Bool {
        FileManager.default.fileExists(atPath: cachePath)
    }

    public init(
        id: String, assetID: String, name: String, category: String,
        categoryOrder: Int, order: Int, thumbnailPath: String?,
        previewImageURL: URL?, videoURL: URL, applePath: String, cachePath: String,
        isPortrait: Bool = false, stillMatchesVideo: Bool = true, kind: Kind = .video,
        knownWidth: Int? = nil, knownHeight: Int? = nil, knownBytes: Int64? = nil
    ) {
        self.id = id
        self.assetID = assetID
        self.name = name
        self.category = category
        self.categoryOrder = categoryOrder
        self.order = order
        self.thumbnailPath = thumbnailPath
        self.previewImageURL = previewImageURL
        self.videoURL = videoURL
        self.applePath = applePath
        self.cachePath = cachePath
        self.isPortrait = isPortrait
        self.stillMatchesVideo = stillMatchesVideo
        self.kind = kind
        self.knownWidth = knownWidth
        self.knownHeight = knownHeight
        self.knownBytes = knownBytes
    }
}

// MARK: - Reading Apple's manifest

extension AppleAerials {

    /// Everything Apple lists on this Mac, in Apple's own order.
    ///
    /// Nil, rather than an empty list, when there is no manifest to read: a
    /// Mac that has never shown System Settings' wallpaper pane has no store
    /// at all, and "Apple lists nothing" and "I could not find Apple's list"
    /// have to reach the interface as different answers. The same distinction
    /// `LibraryManifest.state` draws, for the same reason.
    public static func load(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        libraryRoot: URL = LibraryManifest.defaultRoot()
    ) -> [AppleAerial]? {
        guard let root = resolvedRoot(home: home) else { return nil }
        return load(root: root, cacheDir: cacheDir(libraryRoot: libraryRoot))
    }

    public static func load(root: URL, cacheDir: URL? = nil) -> [AppleAerial]? {
        guard let manifestURL = manifestURL(root: root),
              let data = try? Data(contentsOf: manifestURL)
        else { return nil }
        let strings = loadStrings(root: root)
        return parse(
            manifest: data, root: root, strings: strings,
            cacheDir: cacheDir ?? self.cacheDir(libraryRoot: LibraryManifest.defaultRoot())
        )
    }

    /// Apple's id for the category System Settings calls Dynamic Wallpapers.
    static let dynamicCategoryID = "dynamic-aerials"

    /// That category's name in the user's language and its place in Apple's
    /// order, read the same way `parse` reads every category.
    static func dynamicCategory(
        manifest data: Data, strings: [String: String]
    ) -> (name: String, rank: Int)? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        for (index, raw) in ((top["categories"] as? [[String: Any]]) ?? []).enumerated()
        where raw["id"] as? String == dynamicCategoryID {
            let key = raw["localizedNameKey"] as? String
            return (key.flatMap { strings[$0] } ?? key ?? dynamicCategoryID,
                    raw["preferredOrder"] as? Int ?? index)
        }
        return nil
    }

    /// Split out from `load` so the parsing can be tested against a manifest
    /// built in a temporary directory, without Apple's store being present.
    public static func parse(
        manifest data: Data, root: URL, strings: [String: String], cacheDir: URL
    ) -> [AppleAerial]? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawAssets = top["assets"] as? [[String: Any]]
        else { return nil }

        // Apple's category order, by its own `preferredOrder`. A category the
        // assets mention but the manifest never declares still has to land
        // somewhere, so unknown ids sort after every declared one.
        var categoryName: [String: String] = [:]
        var categoryRank: [String: Int] = [:]
        // What System Settings calls a group of aerials, like "Golden Gate".
        var subcategoryName: [String: String] = [:]
        for (index, raw) in ((top["categories"] as? [[String: Any]]) ?? []).enumerated() {
            guard let id = raw["id"] as? String else { continue }
            let key = raw["localizedNameKey"] as? String
            categoryName[id] = key.flatMap { strings[$0] } ?? key ?? id
            categoryRank[id] = raw["preferredOrder"] as? Int ?? index
            for sub in (raw["subcategories"] as? [[String: Any]]) ?? [] {
                guard let subID = sub["id"] as? String,
                      let subKey = sub["localizedNameKey"] as? String,
                      let subName = strings[subKey]
                else { continue }
                subcategoryName[subID] = subName
            }
        }

        let thumbs = thumbnailsDir(root: root)
        let videos = videosDir(root: root)
        let fileManager = FileManager.default

        var aerials: [AppleAerial] = []
        for raw in rawAssets {
            guard let assetID = raw["id"] as? String else { continue }
            // The only thing that makes an entry usable. Apple has shipped
            // manifest rows with no video before a release lands; those are
            // not wallpapers yet and must not reach the grid as dead cards.
            guard let videoURL = videoAddress(in: raw) else { continue }

            let nameKey = raw["localizedNameKey"] as? String
            var name = nameKey.flatMap { strings[$0] }
                ?? raw["accessibilityLabel"] as? String
                ?? nameKey
                ?? assetID
            // A light and a dark cut of one wallpaper are named only "Light"
            // and "Dark" in Apple's list; System Settings puts them under
            // their group's name. Muro shows both cuts, so each carries both:
            // "Golden Gate Light", "Golden Gate Dark".
            if (raw["variant"] as? [String: Any])?["appearance"] != nil,
               let group = (raw["subcategories"] as? [String])?.lazy
                .compactMap({ subcategoryName[$0] }).first,
               !name.localizedCaseInsensitiveContains(group) {
                name = "\(group) \(name)"
            }

            let categoryID = (raw["categories"] as? [String])?.first
            let category = categoryID.flatMap { categoryName[$0] }
                ?? categoryID.map { categoryName[$0] ?? $0 }
                ?? "Aerial"
            let rank = categoryID.flatMap { categoryRank[$0] } ?? Int.max

            let thumbnail = thumbs.appendingPathComponent("\(assetID).png")
            let hasThumbnail = fileManager.fileExists(atPath: thumbnail.path)

            // Light before dark, the way every other light and dark pair on
            // the page reads.
            let appearance = (raw["variant"] as? [String: Any])?["appearance"] as? String
            let order = (raw["preferredOrder"] as? Int ?? 0) * 10 + (appearance == "dark" ? 1 : 0)

            aerials.append(AppleAerial(
                id: muroID(assetID: assetID),
                assetID: assetID,
                name: name,
                category: category,
                categoryOrder: rank,
                order: order,
                thumbnailPath: hasThumbnail ? thumbnail.path : nil,
                previewImageURL: (raw["previewImage"] as? String).flatMap(URL.init(string:)),
                videoURL: videoURL,
                applePath: videos.appendingPathComponent("\(assetID).mov").path,
                cachePath: cacheDir.appendingPathComponent(downloadFileName(assetID: assetID)).path,
                isPortrait: (raw["variant"] as? [String: Any])?["orientation"] as? String
                    == "portrait"
            ))
        }

        return aerials.sorted(by: appleOrder)
    }

    /// Apple's order: category first, then the order inside it, then the
    /// name so two aerials sharing a rank never swap places between runs.
    static func appleOrder(_ a: AppleAerial, _ b: AppleAerial) -> Bool {
        if a.categoryOrder != b.categoryOrder { return a.categoryOrder < b.categoryOrder }
        if a.order != b.order { return a.order < b.order }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// Apple names the video key after the format, `url-4K-SDR-240FPS` today.
    /// Read by shape rather than by that exact string, so a future manifest
    /// that renames it, or offers HDR beside SDR, still finds a video.
    private static func videoAddress(in raw: [String: Any]) -> URL? {
        let keys = raw.keys.filter { $0.hasPrefix("url") }.sorted()
        // SDR first: HDR on a display that cannot show it looks washed out,
        // and Muro has no HDR path.
        let preferred = keys.first { $0.localizedCaseInsensitiveContains("SDR") } ?? keys.first
        guard let key = preferred, let value = raw[key] as? String else { return nil }
        return URL(string: value)
    }

    /// English titles out of Apple's `.loctable`.
    ///
    /// The file is a binary plist of language to key to string, 45 languages
    /// and 1.8 MB. Only one language is kept, and only the language the user
    /// actually runs in, so this costs a few hundred keys rather than 30,000.
    public static func loadStrings(root: URL) -> [String: String] {
        guard let url = stringsURL(root: root),
              let data = try? Data(contentsOf: url),
              let table = (try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)) as? [String: Any]
        else { return [:] }

        for code in preferredLanguageCodes() {
            if let strings = table[code] as? [String: String] { return strings }
        }
        // Better a table in a language nobody asked for than aerials named
        // GG_A_SUNSET_NAME.
        if let any = table["en"] as? [String: String] { return any }
        return (table.values.first { $0 is [String: String] } as? [String: String]) ?? [:]
    }

    /// The user's languages, most wanted first, in the shapes Apple's table
    /// uses: `en_GB` before `en`.
    static func preferredLanguageCodes(
        preferred: [String] = Locale.preferredLanguages
    ) -> [String] {
        var codes: [String] = []
        for tag in preferred {
            let underscored = tag.replacingOccurrences(of: "-", with: "_")
            if !codes.contains(underscored) { codes.append(underscored) }
            if let base = underscored.split(separator: "_").first.map(String.init),
               !codes.contains(base) {
                codes.append(base)
            }
        }
        if !codes.contains("en") { codes.append("en") }
        return codes
    }
}

// MARK: - Apple's format

extension AppleAerials {
    /// What to assume about an aerial before its own facts have been read.
    ///
    /// **Only ever a stand-in.** Measured 2026-09-30 across all 164 Apple
    /// lists: most are 3840 by 2160, the macOS dynamic ones 4480 by 3088 and
    /// the Mac ones 5632 by 3524; 30 seconds to 7 minutes long; 37 MB to
    /// 1.5 GB, 441 MB typical. Every one is 240 fps. The first version used
    /// the numbers of the four videos that happened to be on one Mac for all
    /// of them and showed 170 MB on a download that came to 391 MB, so the
    /// real facts (`AppleAerialInfo`) replace these the moment they are read.
    ///
    /// The frame rate is not a typo, and it is the one number to keep in view
    /// when judging what these cost to play: it is eight times what Muro
    /// publishes.
    public enum Format {
        public static let width = 3840
        public static let height = 2160
        public static let fps: Double = 240
        public static let duration: Double = 120
        /// The typical size, used only until the real one is known.
        public static let approximateBytes: Int64 = 441_000_000
    }

    /// An Apple aerial dressed as an ordinary Muro wallpaper.
    ///
    /// **This is the whole trick, and why the feature is small.** Everything
    /// downstream of here already works: the engine resolves a video, the
    /// cards draw a thumbnail, apply writes an assignment, playlists and
    /// automations hold ids, the lock screen stages a file. None of it needs
    /// to learn what an Apple aerial is, because it never sees one.
    ///
    /// The one thing that had to change for this to be true is that `file` and
    /// `thumbnail` are **absolute paths**, into Apple's own store or into
    /// Muro's cache, not paths relative to Muro's library root.
    /// `resolveLibraryFile` is what makes both kinds work, and it is the only
    /// line of Muro that had to bend.
    ///
    /// `dateAdded` is deliberately `.distantPast`: these are Apple's, they are
    /// not new, and nothing about them should ever carry a NEW badge or float
    /// to the top of a list sorted by arrival.
    public static func entry(for aerial: AppleAerial) -> WallpaperEntry {
        let playable = aerial.playablePath
        let size = playable
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] }
            .flatMap { ($0 as? NSNumber)?.int64Value }
        let facts = AppleAerialInfo.facts(assetID: aerial.assetID, video: aerial.videoURL)
        return WallpaperEntry(
            id: aerial.id,
            title: aerial.name,
            category: aerial.category,
            file: playable ?? aerial.cachePath,
            efficientFile: nil,
            previewFile: nil,
            thumbnail: sharpestThumbnail(for: aerial),
            width: facts?.width ?? aerial.knownWidth ?? Format.width,
            height: facts?.height ?? aerial.knownHeight ?? Format.height,
            fps: facts?.fps ?? Format.fps,
            duration: facts?.duration ?? Format.duration,
            sizeBytes: size ?? facts?.bytes ?? aerial.knownBytes ?? Format.approximateBytes,
            liked: false,
            dateAdded: .distantPast
        )
    }

    /// The best picture of an aerial on this Mac: Muro's sharp frame once it
    /// has been taken, otherwise the 214 by 130 still macOS keeps, otherwise
    /// where the sharp frame will go.
    ///
    /// Never empty. An empty path resolves to the library folder itself,
    /// which exists, and the lock screen would copy that folder as the
    /// picture. A path with nothing at it fails the check before an apply
    /// instead, and `AppStore.ensureAerialThumbnail` makes the picture first.
    public static func sharpestThumbnail(for aerial: AppleAerial) -> String {
        let frame = AppleAerialInfo.framePath(assetID: aerial.assetID)
        if FileManager.default.fileExists(atPath: frame) { return frame }
        if let still = aerial.thumbnailPath { return still }
        return frame
    }

    /// Every downloaded aerial as a library entry, for the engine to resolve
    /// an assignment against.
    ///
    /// Only the downloaded ones, on purpose. An entry whose file is not there
    /// is a wallpaper the engine would log as missing on every reconcile.
    public static func libraryEntries(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        libraryRoot: URL = LibraryManifest.defaultRoot()
    ) -> [WallpaperEntry] {
        (cachedAerials(home: home, libraryRoot: libraryRoot) ?? [])
            .filter(\.isDownloaded)
            .map(entry(for:))
    }

    // MARK: - Cache

    /// Apple's manifest, re-read only when it actually changes.
    ///
    /// `EngineController.reconcile` runs on every config write and every
    /// display change, and this parses 190 KB of JSON and picks a language out
    /// of a 1.8 MB property list. Cheap once, wasteful on a loop, so the
    /// manifest's size and modification date decide when to do it again, the
    /// same identity check `DesktopStill` uses for the same reason.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (key: String, aerials: [AppleAerial])?

    public static func cachedAerials(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        libraryRoot: URL = LibraryManifest.defaultRoot()
    ) -> [AppleAerial]? {
        guard let root = resolvedRoot(home: home),
              let manifestURL = manifestURL(root: root)
        else { return nil }

        let values = try? manifestURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(root.path)|\(libraryRoot.path)|\(values?.fileSize ?? -1)|"
            + "\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)"

        cacheLock.lock()
        let remembered = cache?.key == key ? cache?.aerials : nil
        cacheLock.unlock()
        if let remembered { return remembered }

        guard var loaded = load(root: root, cacheDir: cacheDir(libraryRoot: libraryRoot))
        else { return nil }
        // System Settings shows these under Dynamic Wallpapers beside the
        // ones in Apple's list, so they join the same category, after them.
        let dynamic = (try? Data(contentsOf: manifestURL))
            .flatMap { dynamicCategory(manifest: $0, strings: loadStrings(root: root)) }
        loaded += DynamicWallpapers.found(
            category: dynamic?.name ?? "Dynamic Wallpapers",
            categoryOrder: dynamic?.rank ?? ((loaded.map(\.categoryOrder).max() ?? 0) + 1),
            cacheDir: cacheDir(libraryRoot: libraryRoot)
        )
        loaded.sort(by: appleOrder)
        // Apple's dynamic wallpapers ship a portrait cut for iPad beside the
        // landscape one. On a Mac desktop that is a tall video in a wide
        // window, so it is left out rather than shown and cropped to ruin.
        let landscape = loaded.filter { !$0.isPortrait }
        cacheLock.lock()
        cache = (key, landscape)
        cacheLock.unlock()
        return landscape
    }

    /// Forgets the cached manifest, so the next read goes to disk.
    public static func invalidateCache() {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }
}

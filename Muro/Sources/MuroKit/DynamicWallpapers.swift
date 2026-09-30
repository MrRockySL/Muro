import Foundation

/// Apple's Dynamic Wallpapers that are not in Apple's aerial list.
///
/// **Why this exists.** System Settings shows 35 Dynamic Wallpapers on
/// macOS 27, and only one of them, Golden Gate, is in the aerial list the
/// rest of the Apple section reads. The other 34 are kept in three other
/// places, found on the owner's Mac on 2026-09-30:
///
/// - **Videos**, which Muro plays like any wallpaper. Tahoe comes from Apple's
///   servers (the address is in its wallpaper extension's `manifest.json`);
///   Sonoma is already on every Mac, in `Desktop Pictures/.wallpapers`.
/// - **Drawn live by code**, Sequoia and Macintosh. Their extensions carry
///   Metal shaders and 3D meshes and no video, so only macOS can show them.
/// - **Still pictures**, the other 30, from Big Sur to Iridescence. Each is a
///   picture that changes between light and dark, some by the time of day.
///   macOS downloads them from Apple's servers when one is chosen.
///
/// Each one appears twice, once Light and once Dark, the way the owner asked
/// for them (2026-09-30), except Solar Gradients, which only changes with the
/// time of day and has no light or dark of its own, and Sequoia and
/// Macintosh, which follow the Mac's own light or dark mode (see `drawn`). The order is System
/// Settings' own: Golden Gate, Tahoe, Sequoia, Macintosh, Sonoma, then the
/// pictures in the order `.orderedPictures.plist` gives them.
///
/// Nothing here writes anything. It only reads what macOS already keeps.
public enum DynamicWallpapers {

    static let desktopPictures = URL(
        fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
    static let extensions = URL(
        fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
    static let systemWallpapers = URL(
        fileURLWithPath: "/System/Library/Wallpapers", isDirectory: true)
    static let assetCatalog = URL(fileURLWithPath:
        "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture/"
        + "com_apple_MobileAsset_DesktopPicture.xml")

    /// Where each one sits in the category, after Golden Gate.
    private enum Slot {
        static let tahoe = 1000, sequoia = 1010, macintosh = 1020, sonoma = 1030
        static let firstPicture = 1100
    }

    /// Every Dynamic Wallpaper this Mac has beyond Apple's aerial list.
    public static func found(category: String, categoryOrder: Int, cacheDir: URL) -> [AppleAerial] {
        let maker = Maker(category: category, categoryOrder: categoryOrder, cacheDir: cacheDir)
        var out: [AppleAerial] = []
        out += streamedVideos(maker)
        out += drawn(maker)
        let local = localVideos(maker)
        out += local.aerials
        // Sonoma is also listed as a picture; the video is the real thing.
        out += pictures(maker, skipping: local.names)
        return out
    }

    // MARK: - Videos on Apple's servers (Tahoe)

    /// Wallpaper extensions whose `manifest.json` names a light and a dark
    /// video, which is how Tahoe is shipped. Read by shape, so the next one
    /// Apple ships this way is found too.
    static func streamedVideos(_ maker: Maker) -> [AppleAerial] {
        var out: [AppleAerial] = []
        for appex in appexes() {
            let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
            guard let data = try? Data(contentsOf: resources.appendingPathComponent("manifest.json")),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let light = (manifest["lightLandscapeRemoteURL"] as? String).flatMap(URL.init(string:)),
                  let dark = (manifest["darkLandscapeRemoteURL"] as? String).flatMap(URL.init(string:))
            else { continue }
            let strings = localizedStrings(resources.appendingPathComponent("Localizable.loctable"))
            let identifier = manifest["identifier"] as? String ?? appex.deletingPathExtension().lastPathComponent
            let name = strings["SETTINGS_LABEL_ONE"] ?? identifier
            let words = lightDarkWords(strings)
            let thumbnail = existing(resources.appendingPathComponent("thumbnail.heic"))
            for (index, (url, word)) in [(light, words.light), (dark, words.dark)].enumerated() {
                let slug = "\(slugged(identifier))-\(index == 0 ? "light" : "dark")"
                out.append(maker.video(
                    slug: slug, name: "\(name) \(word)", order: Slot.tahoe + index,
                    thumbnail: thumbnail, videoURL: url, applePath: ""
                ))
            }
        }
        return out
    }

    // MARK: - Videos already on the Mac (Sonoma)

    /// `Desktop Pictures/.wallpapers/<Name>/<…> Light Landscape.mov` and its
    /// dark twin. Sonoma today. Already on every Mac, so nothing is downloaded.
    static func localVideos(_ maker: Maker) -> (aerials: [AppleAerial], names: Set<String>) {
        let root = desktopPictures.appendingPathComponent(".wallpapers", isDirectory: true)
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        var out: [AppleAerial] = []
        var names = Set<String>()
        for folder in folders {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            guard let light = files.first(where: { $0.hasSuffix("Light Landscape.mov") }),
                  let dark = files.first(where: { $0.hasSuffix("Dark Landscape.mov") })
            else { continue }
            names.insert(folder)
            let extensionStrings = localizedStrings(extensions
                .appendingPathComponent("Wallpaper\(folder)Extension.appex/Contents/Resources/Localizable.loctable"))
            let name = extensionStrings["\(folder.uppercased())_LABEL"] ?? folder
            let words = lightDarkWords(extensionStrings)
            for (index, (file, word)) in [(light, words.light), (dark, words.dark)].enumerated() {
                let path = directory.appendingPathComponent(file).path
                let variant = index == 0 ? "Light" : "Dark"
                out.append(maker.video(
                    slug: "\(slugged(folder))-\(variant.lowercased())",
                    name: "\(name) \(word)", order: Slot.sonoma + index,
                    thumbnail: existing(desktopPictures
                        .appendingPathComponent(".thumbnails/\(folder) \(variant).heic")),
                    videoURL: URL(fileURLWithPath: path), applePath: path
                ))
            }
        }
        return (out, names)
    }

    // MARK: - Drawn by macOS (Sequoia, Macintosh)

    /// One card each. macOS draws these with its own code and follows the
    /// Mac's light or dark mode; which part of the record forces one or the
    /// other is not known yet (tested 2026-09-30: the obvious keys are
    /// ignored), so a Light and a Dark card would both show the same thing.
    static func drawn(_ maker: Maker) -> [AppleAerial] {
        var out: [AppleAerial] = []
        let sequoia = extensions.appendingPathComponent("WallpaperSequoiaExtension.appex", isDirectory: true)
        if FileManager.default.fileExists(atPath: sequoia.path) {
            let resources = sequoia.appendingPathComponent("Contents/Resources", isDirectory: true)
            let strings = localizedStrings(resources.appendingPathComponent("Localizable.loctable"))
            out.append(maker.drawn(
                slug: "sequoia", name: strings["SEQUOIA_LABEL"] ?? "Sequoia", order: Slot.sequoia,
                thumbnail: existing(resources.appendingPathComponent("thumbnail.heic"))
                    ?? existing(resources.appendingPathComponent("thumbnail light.heic")),
                source: sequoia
            ))
        }
        let macintosh = extensions.appendingPathComponent("WallpaperMacintoshExtension.appex", isDirectory: true)
        if FileManager.default.fileExists(atPath: macintosh.path) {
            let resources = macintosh.appendingPathComponent("Contents/Resources", isDirectory: true)
            let strings = localizedStrings(resources.appendingPathComponent("Localizable.loctable"))
            out.append(maker.drawn(
                slug: "macintosh", name: strings["MACINTOSH_LABEL"] ?? "Macintosh", order: Slot.macintosh,
                thumbnail: existing(systemWallpapers.appendingPathComponent(".thumbnails/Macintosh.heic")),
                source: macintosh
            ))
        }
        return out
    }

    // MARK: - Still pictures

    /// Every dynamic picture in `Desktop Pictures`, in Apple's own order.
    ///
    /// A `.madesktop` file is macOS's note of a picture it can download: its
    /// name, its size and whether it changes with light and dark. A `.heic`
    /// is one already on the Mac; it counts as dynamic when macOS keeps a
    /// light and a dark thumbnail for it.
    static func pictures(_ maker: Maker, skipping videos: Set<String>) -> [AppleAerial] {
        let fileManager = FileManager.default
        let orderURL = desktopPictures.appendingPathComponent(".orderedPictures.plist")
        guard let data = try? Data(contentsOf: orderURL),
              let order = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
        else { return [] }
        let thumbnails = desktopPictures.appendingPathComponent(".thumbnails", isDirectory: true)
        let downloads = assetDownloads()

        struct Found { let base: String; let note: [String: Any] }
        var found: [Found] = []
        for file in order {
            let url = desktopPictures.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let base = (file as NSString).deletingPathExtension
            // Covered as a video already, like Sonoma.
            if videos.contains(base) { continue }
            var note: [String: Any] = [:]
            if file.hasSuffix(".madesktop") {
                guard let raw = try? Data(contentsOf: url),
                      let plist = (try? PropertyListSerialization.propertyList(from: raw, format: nil))
                        as? [String: Any],
                      plist["isDynamic"] as? Bool == true
                else { continue }
                note = plist
            } else {
                let light = thumbnails.appendingPathComponent("\(base) Light.heic")
                guard fileManager.fileExists(atPath: light.path) else { continue }
            }
            found.append(Found(base: base, note: note))
        }

        // System Settings calls "Ventura Graphic" just Ventura. Muro does the
        // same, unless that would give two pictures one name.
        let bases = Set(found.map(\.base))
        func displayName(_ base: String) -> String {
            guard base.hasSuffix(" Graphic") else { return base }
            let short = String(base.dropLast(" Graphic".count))
            return bases.contains(short) ? base : short
        }

        var out: [AppleAerial] = []
        for (index, picture) in found.enumerated() {
            let name = displayName(picture.base)
            let slot = Slot.firstPicture + index * 10
            let width = picture.note["width"] as? Int
            let height = picture.note["height"] as? Int
            let download = downloads[picture.base]
            let hasSides = picture.note["canSelectAppearance"] as? Bool != false
            if hasSides {
                for (side, variant) in ["Light", "Dark"].enumerated() {
                    out.append(maker.picture(
                        slug: "\(slugged(picture.base))-\(variant.lowercased())",
                        name: "\(name) \(variant)", order: slot + side,
                        thumbnail: existing(thumbnails.appendingPathComponent("\(picture.base) \(variant).heic"))
                            ?? existing(thumbnails.appendingPathComponent("\(picture.base).heic")),
                        source: download?.url ?? desktopPictures.appendingPathComponent(picture.base),
                        width: width, height: height, bytes: download?.bytes
                    ))
                }
            } else {
                out.append(maker.picture(
                    slug: slugged(picture.base), name: name, order: slot,
                    thumbnail: existing(thumbnails.appendingPathComponent("\(picture.base).heic")),
                    source: download?.url ?? desktopPictures.appendingPathComponent(picture.base),
                    width: width, height: height, bytes: download?.bytes
                ))
            }
        }
        return out
    }

    /// Where Apple's servers keep each picture, and how big it is, from the
    /// catalogue macOS itself downloads them with.
    static func assetDownloads() -> [String: (url: URL, bytes: Int64)] {
        guard let data = try? Data(contentsOf: assetCatalog),
              let top = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any],
              let assets = top["Assets"] as? [[String: Any]]
        else { return [:] }
        var out: [String: (url: URL, bytes: Int64)] = [:]
        for asset in assets {
            guard let id = asset["DesktopPictureID"] as? String,
                  let base = asset["__BaseURL"] as? String,
                  let path = asset["__RelativePath"] as? String,
                  let url = URL(string: base + path)
            else { continue }
            let bytes = (asset["_DownloadSize"] as? NSNumber)?.int64Value ?? 0
            out[id] = (url, bytes)
        }
        return out
    }

    // MARK: - Building them

    struct Maker {
        let category: String
        let categoryOrder: Int
        let cacheDir: URL

        func video(
            slug: String, name: String, order: Int, thumbnail: String?,
            videoURL: URL, applePath: String
        ) -> AppleAerial {
            let assetID = "dynamic-\(slug)"
            return AppleAerial(
                id: AppleAerials.muroID(assetID: assetID), assetID: assetID, name: name,
                category: category, categoryOrder: categoryOrder, order: order,
                thumbnailPath: thumbnail, previewImageURL: nil, videoURL: videoURL,
                applePath: applePath,
                cachePath: cacheDir.appendingPathComponent(
                    AppleAerials.downloadFileName(assetID: assetID)).path,
                stillMatchesVideo: false
            )
        }

        func drawn(slug: String, name: String, order: Int, thumbnail: String?, source: URL) -> AppleAerial {
            let assetID = "drawn-\(slug)"
            return AppleAerial(
                id: AppleAerials.muroID(assetID: assetID), assetID: assetID, name: name,
                category: category, categoryOrder: categoryOrder, order: order,
                thumbnailPath: thumbnail, previewImageURL: nil, videoURL: source,
                applePath: "", cachePath: "",
                stillMatchesVideo: false, kind: .drawn
            )
        }

        func picture(
            slug: String, name: String, order: Int, thumbnail: String?, source: URL,
            width: Int?, height: Int?, bytes: Int64?
        ) -> AppleAerial {
            let assetID = "picture-\(slug)"
            return AppleAerial(
                id: AppleAerials.muroID(assetID: assetID), assetID: assetID, name: name,
                category: category, categoryOrder: categoryOrder, order: order,
                thumbnailPath: thumbnail, previewImageURL: nil, videoURL: source,
                // Where its side of the picture goes once downloaded, so it
                // counts as downloaded the way an aerial does.
                applePath: "",
                cachePath: cacheDir.appendingPathComponent(
                    AppleAerials.pictureFileName(assetID: assetID)).path,
                stillMatchesVideo: false, kind: .picture,
                knownWidth: width, knownHeight: height, knownBytes: bytes
            )
        }
    }

    // MARK: - Small pieces

    static func appexes() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? [])
            .filter { $0.hasSuffix(".appex") }
            .sorted()
            .map { extensions.appendingPathComponent($0, isDirectory: true) }
    }

    /// Lower case, words joined by dashes: safe in an id, a file name and a
    /// path, which is all three of what an id becomes.
    static func slugged(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    static func existing(_ url: URL) -> String? {
        FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    /// A `.loctable`, in the user's language, falling back to English.
    static func localizedStrings(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let table = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any]
        else { return [:] }
        for code in AppleAerials.preferredLanguageCodes() {
            if let strings = table[code] as? [String: String] { return strings }
        }
        return [:]
    }

    /// The words Apple's own extension uses for its light and dark cuts.
    static func lightDarkWords(_ strings: [String: String]) -> (light: String, dark: String) {
        (strings["DYNAMIC_TYPE_LIGHT"] ?? strings["APPEARANCE_LIGHT"] ?? "Light",
         strings["DYNAMIC_TYPE_DARK"] ?? strings["APPEARANCE_DARK"] ?? "Dark")
    }
}

import AppKit

/// The screen savers on this Mac: Apple's own, and any `.saver` the person
/// installed, like XScreenSaver.
///
/// **Only macOS can run them here.** Apple's own (Flurry, Hello, Drift and
/// the rest) are programs sealed inside macOS, and an installed `.saver` is
/// someone else's code, so Muro never loads either. It hands the chosen one to
/// macOS through the wallpaper store, the same way System Settings does:
/// `com.apple.wallpaper.choice.screen-saver`, naming the module. macOS then
/// draws it live as the screen saver, or on the desktop and the lock screen
/// together, which was proven on the owner's Mac on 2026-09-28 (Flurry on both
/// screens, and a `.saver` from `~/Library/Screen Savers` through macOS's own
/// `legacyScreenSaver`).
///
/// Each one becomes an `AppleAerial` of kind `.screenSaver`, so the cards, the
/// detail view and the Set Wallpaper panel treat it like every other
/// wallpaper macOS shows.
public enum AppleScreenSavers {

    public static let idPrefix = AppleAerials.idPrefix + "saver-"
    public static let provider = "com.apple.wallpaper.choice.screen-saver"

    /// What System Settings writes for a screen saver: the module's own address.
    public static func choice(module: URL) -> [String: Any] {
        let configuration: [String: Any] = ["module": ["relative": module.absoluteString]]
        return [
            "Provider": provider,
            "Files": [],
            "Configuration": (try? PropertyListSerialization.data(
                fromPropertyList: configuration, format: .binary, options: 0)) ?? Data(),
        ]
    }

    /// Apple's screen savers the section offers, by module name: the eight
    /// recorded as 4K videos (owner, 2026-09-30). Album Artwork, Message and
    /// Photos show the person's own music, computer name and photos, so they
    /// were never recorded and are left out, as is any a later macOS adds.
    public static let recorded: Set<String> = [
        "Arabesque", "Drift", "Flurry", "Hello", "Monterey", "Shell", "Ventura", "Word of the Day",
    ]

    /// The two groups: Apple's, shown in the Apple section, and the person's
    /// own, shown in the Library.
    public static let appleGroup = "Apple"
    public static let installedGroup = "Yours"

    static let extensions = URL(
        fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)

    /// Where macOS looks for installed screen savers, the person's own first.
    public static var installedFolders: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Screen Savers", isDirectory: true),
            URL(fileURLWithPath: "/Library/Screen Savers", isDirectory: true),
        ]
    }

    /// Every screen saver on this Mac, Apple's first, each group by name.
    public static func found(thumbnails: URL = AppleAerialInfo.directory) -> [AppleAerial] {
        apple(thumbnails: thumbnails) + installed(thumbnails: thumbnails)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [AppleAerial]?

    /// `found()`, read once and kept until `refresh()`. Screen savers only
    /// change when someone installs or removes one.
    public static func cached() -> [AppleAerial] {
        cacheLock.lock()
        let kept = cache
        cacheLock.unlock()
        if let kept { return kept }
        let fresh = found()
        cacheLock.lock()
        cache = fresh
        cacheLock.unlock()
        return fresh
    }

    /// Looks again, for a screen saver installed while Muro was running.
    @discardableResult
    public static func refresh() -> [AppleAerial] {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
        return cached()
    }

    /// Apple's own, for the Apple section.
    public static func cachedApple() -> [AppleAerial] {
        cached().filter { $0.category == appleGroup }
    }

    /// The ones the person added, like XScreenSaver. They show in the Library
    /// with the rest of what they import, never in the Apple section (owner,
    /// 2026-09-30).
    public static func cachedInstalled() -> [AppleAerial] {
        cached().filter { $0.category == installedGroup }
    }

    // MARK: - Apple's

    static func apple(thumbnails: URL) -> [AppleAerial] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []
        var out: [AppleAerial] = []
        for name in names where name.hasSuffix(".appex") {
            let appex = extensions.appendingPathComponent(name, isDirectory: true)
            guard recorded.contains(appex.deletingPathExtension().lastPathComponent) else { continue }
            guard let bundle = Bundle(url: appex) else { continue }
            let described = bundle.infoDictionary?["NSExtension"] as? [String: Any]
            guard described?["NSExtensionPointIdentifier"] as? String == "com.apple.screensaver"
            else { continue }
            let title = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? appex.deletingPathExtension().lastPathComponent
            out.append(make(
                title: title, group: appleGroup, module: appex, bundle: bundle, thumbnails: thumbnails))
        }
        return sortedByName(out)
    }

    // MARK: - Installed

    static func installed(thumbnails: URL) -> [AppleAerial] {
        var out: [AppleAerial] = []
        var seen = Set<String>()
        for folder in installedFolders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".saver") {
                // The person's own copy wins over a second one for everybody.
                guard seen.insert(name).inserted else { continue }
                let module = folder.appendingPathComponent(name, isDirectory: true)
                let bundle = Bundle(url: module)
                let title = bundle?.infoDictionary?["CFBundleName"] as? String
                    ?? module.deletingPathExtension().lastPathComponent
                out.append(make(
                    title: title, group: installedGroup, module: module, bundle: bundle,
                    thumbnails: thumbnails))
            }
        }
        return sortedByName(out)
    }

    // MARK: - Pieces

    static func make(
        title: String, group: String, module: URL, bundle: Bundle?, thumbnails: URL
    ) -> AppleAerial {
        let slug = DynamicWallpapers.slugged(
            (group == appleGroup ? "" : "yours-") + module.deletingPathExtension().lastPathComponent)
        let assetID = "saver-\(slug)"
        let picture = thumbnails.appendingPathComponent("\(assetID).png")
        return AppleAerial(
            id: AppleAerials.muroID(assetID: assetID), assetID: assetID, name: title,
            category: group, categoryOrder: group == appleGroup ? 0 : 1, order: 0,
            thumbnailPath: thumbnail(for: bundle, title: title, at: picture),
            previewImageURL: nil, videoURL: module,
            applePath: "", cachePath: "",
            stillMatchesVideo: false, kind: .screenSaver
        )
    }

    static func sortedByName(_ list: [AppleAerial]) -> [AppleAerial] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The screen saver's own preview picture, saved once as a file so the
    /// cards can draw it like any other thumbnail. Apple keeps it inside each
    /// screen saver (214 by 130). The two that carry none, and any installed
    /// one without a `thumbnail` image, get a plain picture with their name.
    static func thumbnail(for bundle: Bundle?, title: String, at file: URL) -> String? {
        if FileManager.default.fileExists(atPath: file.path) { return file.path }
        let image = bundle?.image(forResource: "thumbnail") ?? placeholder(title: title)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? png.write(to: file, options: .atomic)) != nil else { return nil }
        return file.path
    }

    /// Midnight blue with a moon and the name, in the app's own colours.
    static func placeholder(title: String) -> NSImage {
        let size = NSSize(width: 428, height: 260)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(
            starting: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.24, alpha: 1),
            ending: NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.08, alpha: 1)
        )?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        if let moon = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 54, weight: .regular)) {
            let tinted = NSImage(size: moon.size, flipped: false) { rect in
                moon.draw(in: rect)
                NSColor(white: 1, alpha: 0.85).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(
                x: (size.width - moon.size.width) / 2, y: 118,
                width: moon.size.width, height: moon.size.height))
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (title as NSString).draw(
            in: NSRect(x: 0, y: 70, width: size.width, height: 32),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.9),
                .paragraphStyle: style,
            ])
        image.unlockFocus()
        return image
    }
}

import XCTest
@testable import MuroKit

/// Apple's aerial manifest, and the reading of it.
///
/// Built around a manifest written into a temporary directory rather than the
/// one on the machine running the tests, because that one is not there on
/// every Mac and its contents change with every macOS release. The shapes
/// below are copied from the real file on macOS 27, 2026-09-08.
final class AppleAerialsTests: XCTestCase {

    // MARK: - Building a store to read

    private func makeStore(
        assets: [[String: Any]],
        categories: [[String: Any]],
        thumbnailsFor: [String] = [],
        videosFor: [String] = []
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aerials-\(UUID().uuidString)", isDirectory: true)
        let manifest = root.appendingPathComponent("manifest", isDirectory: true)
        let thumbs = root.appendingPathComponent("thumbnails", isDirectory: true)
        let videos = root.appendingPathComponent("videos", isDirectory: true)
        for dir in [manifest, thumbs, videos] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let top: [String: Any] = [
            "assets": assets, "categories": categories, "version": 1
        ]
        try JSONSerialization.data(withJSONObject: top)
            .write(to: manifest.appendingPathComponent("entries.json"))
        for id in thumbnailsFor {
            try Data([0x89]).write(to: thumbs.appendingPathComponent("\(id).png"))
        }
        for id in videosFor {
            try Data([0x00]).write(to: videos.appendingPathComponent("\(id).mov"))
        }
        return root
    }

    private func asset(
        id: String, nameKey: String, category: String, order: Int = 0,
        orientation: String? = nil, url: String = "https://sylvan.apple.com/a.mov"
    ) -> [String: Any] {
        var a: [String: Any] = [
            "id": id,
            "localizedNameKey": nameKey,
            "accessibilityLabel": "fallback \(id)",
            "categories": [category],
            "preferredOrder": order,
            "previewImage": "https://sylvan.apple.com/\(id).png",
            "url-4K-SDR-240FPS": url
        ]
        if let orientation { a["variant"] = ["orientation": orientation] }
        return a
    }

    private let landscapes = [
        "id": "CAT-LAND", "localizedNameKey": "AerialCategoryLandscapes", "preferredOrder": 1
    ] as [String: Any]
    private let cities = [
        "id": "CAT-CITY", "localizedNameKey": "AerialCategoryCities", "preferredOrder": 2
    ] as [String: Any]

    // MARK: - Parsing

    func testReadsEveryAssetWithAVideo() throws {
        let root = try makeStore(
            assets: [
                asset(id: "A", nameKey: "K_A", category: "CAT-LAND"),
                asset(id: "B", nameKey: "K_B", category: "CAT-CITY")
            ],
            categories: [landscapes, cities]
        )
        let aerials = try XCTUnwrap(AppleAerials.load(root: root))
        XCTAssertEqual(aerials.count, 2)
        XCTAssertEqual(aerials.map(\.assetID), ["A", "B"])
    }

    /// A row with no video is not a wallpaper. Apple has shipped those ahead of
    /// a release, and they must not reach the grid as a card that cannot play.
    func testSkipsAssetsWithNoVideo() throws {
        var broken = asset(id: "B", nameKey: "K_B", category: "CAT-LAND")
        broken.removeValue(forKey: "url-4K-SDR-240FPS")
        let root = try makeStore(
            assets: [asset(id: "A", nameKey: "K_A", category: "CAT-LAND"), broken],
            categories: [landscapes]
        )
        let aerials = try XCTUnwrap(AppleAerials.load(root: root))
        XCTAssertEqual(aerials.map(\.assetID), ["A"])
    }

    /// Missing entirely and empty are different answers. A Mac that has never
    /// opened the wallpaper pane has no store, and the interface has to be able
    /// to say so rather than show an empty gallery.
    func testNoManifestReadsAsNilNotEmpty() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertNil(AppleAerials.load(root: nowhere))
    }

    func testAppleOrderIsKept() throws {
        let root = try makeStore(
            assets: [
                asset(id: "C", nameKey: "K", category: "CAT-CITY", order: 0),
                asset(id: "L2", nameKey: "K", category: "CAT-LAND", order: 7),
                asset(id: "L1", nameKey: "K", category: "CAT-LAND", order: 2)
            ],
            categories: [landscapes, cities]
        )
        let aerials = try XCTUnwrap(AppleAerials.load(root: root))
        // Landscapes (preferredOrder 1) before Cities (2), and inside
        // Landscapes, Apple's own order.
        XCTAssertEqual(aerials.map(\.assetID), ["L1", "L2", "C"])
    }

    /// Apple ships its dynamic wallpapers in a tall cut for iPad. On a Mac
    /// desktop that is a portrait video in a landscape window.
    func testPortraitVariantsAreRecognised() throws {
        let root = try makeStore(
            assets: [
                asset(id: "W", nameKey: "K", category: "CAT-LAND", orientation: "landscape"),
                asset(id: "T", nameKey: "K", category: "CAT-LAND", orientation: "portrait")
            ],
            categories: [landscapes]
        )
        let aerials = try XCTUnwrap(AppleAerials.load(root: root))
        XCTAssertEqual(aerials.first { $0.assetID == "T" }?.isPortrait, true)
        XCTAssertEqual(aerials.first { $0.assetID == "W" }?.isPortrait, false)
    }

    // MARK: - Files

    func testThumbnailIsFoundOnlyWhenItIsThere() throws {
        let root = try makeStore(
            assets: [
                asset(id: "HAS", nameKey: "K", category: "CAT-LAND"),
                asset(id: "NONE", nameKey: "K", category: "CAT-LAND")
            ],
            categories: [landscapes],
            thumbnailsFor: ["HAS"]
        )
        let aerials = try XCTUnwrap(AppleAerials.load(root: root))
        XCTAssertNotNil(aerials.first { $0.assetID == "HAS" }?.thumbnailPath)
        XCTAssertNil(aerials.first { $0.assetID == "NONE" }?.thumbnailPath)
    }

    func testDownloadedIsReadFromDiskEveryTime() throws {
        let root = try makeStore(
            assets: [asset(id: "V", nameKey: "K", category: "CAT-LAND")],
            categories: [landscapes],
            videosFor: ["V"]
        )
        let aerial = try XCTUnwrap(AppleAerials.load(root: root)?.first)
        XCTAssertTrue(aerial.isDownloaded)
        // macOS deletes these on its own when space runs short. Nothing may
        // hold on to an answer from before that happened.
        try FileManager.default.removeItem(atPath: try XCTUnwrap(aerial.playablePath))
        XCTAssertFalse(aerial.isDownloaded)
    }

    // MARK: - Ids

    func testAppleIdsAreRecognisableAndReversible() {
        let id = AppleAerials.muroID(assetID: "C6AECFD2-A365-4504-9E2C-F86343F9421F")
        XCTAssertEqual(id, "apple-C6AECFD2-A365-4504-9E2C-F86343F9421F")
        XCTAssertTrue(AppleAerials.isAppleID(id))
        XCTAssertEqual(AppleAerials.assetID(fromMuroID: id), "C6AECFD2-A365-4504-9E2C-F86343F9421F")
    }

    /// A Muro wallpaper id is a bare UUID and must never be taken for Apple's.
    /// This is what the whole feature's removal leans on.
    func testMuroIdsAreNeverMistakenForApples() {
        let muro = "c0b0484f-80b9-40f3-bf02-03cd0886ba82"
        XCTAssertFalse(AppleAerials.isAppleID(muro))
        XCTAssertNil(AppleAerials.assetID(fromMuroID: muro))
    }

    /// The id has to survive being used as a directory name, which
    /// `LockScreenService` does. A colon would not.
    func testAppleIdIsSafeInAPath() {
        let id = AppleAerials.muroID(assetID: "C6AECFD2-A365-4504-9E2C-F86343F9421F")
        XCTAssertFalse(id.contains(":"))
        XCTAssertFalse(id.contains("/"))
    }

    // MARK: - Becoming an ordinary wallpaper

    func testEntryPointsAtApplesOwnFilesNotMuros() throws {
        let root = try makeStore(
            assets: [asset(id: "A", nameKey: "K", category: "CAT-LAND")],
            categories: [landscapes],
            thumbnailsFor: ["A"], videosFor: ["A"]
        )
        let aerial = try XCTUnwrap(AppleAerials.load(root: root)?.first)
        let entry = AppleAerials.entry(for: aerial)

        XCTAssertTrue(entry.file.hasPrefix("/"), "must be absolute, nothing is copied")
        XCTAssertTrue(entry.thumbnail.hasPrefix("/"))
        XCTAssertTrue(entry.file.contains("/videos/"), "Apple's own copy is preferred")
        // Never new, never floated to the top of anything sorted by arrival.
        XCTAssertEqual(entry.dateAdded, .distantPast)
    }

    /// The single line of existing Muro this feature needed. A relative path
    /// still resolves inside the library; an absolute one is left alone.
    func testAbsolutePathsResolveOutsideTheLibrary() {
        let root = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Muro")
        XCTAssertEqual(
            resolveLibraryFile("Masters/x.mov", root: root).path,
            "/Users/someone/Library/Application Support/Muro/Masters/x.mov"
        )
        XCTAssertEqual(
            resolveLibraryFile("/Users/someone/Library/Application Support/"
                + "com.apple.wallpaper/aerials/videos/A.mov", root: root).path,
            "/Users/someone/Library/Application Support/com.apple.wallpaper/aerials/videos/A.mov"
        )
    }

    func testOnlyDownloadedAerialsBecomeLibraryEntries() throws {
        let root = try makeStore(
            assets: [
                asset(id: "HAVE", nameKey: "K", category: "CAT-LAND"),
                asset(id: "NOT", nameKey: "K", category: "CAT-LAND")
            ],
            categories: [landscapes],
            videosFor: ["HAVE"]
        )
        let aerials = try XCTUnwrap(AppleAerials.load(root: root))
        let entries = aerials.filter(\.isDownloaded).map(AppleAerials.entry(for:))
        XCTAssertEqual(entries.map(\.id), ["apple-HAVE"])
    }

    // MARK: - Names

    func testFallsBackThroughAccessibilityLabelToTheKey() throws {
        // No strings table is written, so nothing resolves and the fallback
        // chain is what produces the name.
        let root = try makeStore(
            assets: [asset(id: "A", nameKey: "GG_A_SUNSET_NAME", category: "CAT-LAND")],
            categories: [landscapes]
        )
        let aerial = try XCTUnwrap(AppleAerials.load(root: root)?.first)
        XCTAssertEqual(aerial.name, "fallback A")
    }

    func testCategoryFallsBackToItsKeyWhenNotLocalised() throws {
        let root = try makeStore(
            assets: [asset(id: "A", nameKey: "K", category: "CAT-LAND")],
            categories: [landscapes]
        )
        let aerial = try XCTUnwrap(AppleAerials.load(root: root)?.first)
        XCTAssertEqual(aerial.category, "AerialCategoryLandscapes")
    }

    func testLocalisedNamesWin() throws {
        let root = try makeStore(
            assets: [asset(id: "A", nameKey: "GG_A_SUNSET_NAME", category: "CAT-LAND")],
            categories: [landscapes]
        )
        let data = try XCTUnwrap(
            FileManager.default.contents(
                atPath: root.appendingPathComponent("manifest/entries.json").path))
        let aerials = try XCTUnwrap(AppleAerials.parse(
            manifest: data, root: root,
            strings: ["GG_A_SUNSET_NAME": "Golden Gate Sunset",
                      "AerialCategoryLandscapes": "Landscape"],
            cacheDir: root.appendingPathComponent("cache")
        ))
        XCTAssertEqual(aerials.first?.name, "Golden Gate Sunset")
        XCTAssertEqual(aerials.first?.category, "Landscape")
    }

    func testPreferredLanguagesTryRegionThenBase() {
        XCTAssertEqual(
            AppleAerials.preferredLanguageCodes(preferred: ["en-GB", "fr-FR"]),
            ["en_GB", "en", "fr_FR", "fr"]
        )
        // English is always worth one last try: Apple's table always has it.
        XCTAssertEqual(AppleAerials.preferredLanguageCodes(preferred: ["si"]).last, "en")
    }

    // MARK: - Apple's copy versus Muro's

    /// Two places a video can be, and which one wins matters twice: it decides
    /// whether 170 MB is downloaded at all, and whether Muro is allowed to
    /// delete what it finds.
    private func makeAerial(
        appleCopy: Bool, muroCopy: Bool
    ) throws -> AppleAerial {
        let cache = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muro-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let root = try makeStore(
            assets: [asset(id: "A", nameKey: "K", category: "CAT-LAND")],
            categories: [landscapes],
            videosFor: appleCopy ? ["A"] : []
        )
        if muroCopy {
            try Data([0x01]).write(
                to: cache.appendingPathComponent(AppleAerials.downloadFileName(assetID: "A")))
        }
        return try XCTUnwrap(AppleAerials.load(root: root, cacheDir: cache)?.first)
    }

    func testApplesOwnCopyIsPreferredSoNothingIsDownloadedTwice() throws {
        let aerial = try makeAerial(appleCopy: true, muroCopy: true)
        XCTAssertEqual(aerial.playablePath, aerial.applePath)
        XCTAssertTrue(aerial.isDownloaded)
    }

    func testMurosCopyIsUsedWhenApplesIsNotThere() throws {
        let aerial = try makeAerial(appleCopy: false, muroCopy: true)
        XCTAssertEqual(aerial.playablePath, aerial.cachePath)
        XCTAssertTrue(aerial.isDownloaded)
    }

    func testNeitherCopyMeansNotDownloaded() throws {
        let aerial = try makeAerial(appleCopy: false, muroCopy: false)
        XCTAssertNil(aerial.playablePath)
        XCTAssertFalse(aerial.isDownloaded)
    }

    /// The guard that keeps Muro out of macOS's files. An aerial macOS
    /// downloaded for itself is playable and is **not** Muro's to remove.
    func testApplesOwnCopyIsNotMurosToRemove() throws {
        let aerial = try makeAerial(appleCopy: true, muroCopy: false)
        XCTAssertTrue(aerial.isDownloaded)
        XCTAssertFalse(aerial.hasMuroCopy, "macOS owns that file, Muro must not offer to delete it")
    }

    func testOnlyMurosOwnCopyIsRemovable() throws {
        let aerial = try makeAerial(appleCopy: false, muroCopy: true)
        XCTAssertTrue(aerial.hasMuroCopy)
    }

    /// Muro's cache path must never point inside Apple's store, or a remove
    /// would delete somebody else's file.
    func testMuroCacheNeverPointsIntoApplesStore() throws {
        let aerial = try makeAerial(appleCopy: true, muroCopy: true)
        XCTAssertFalse(aerial.cachePath.contains("com.apple.wallpaper"))
        XCTAssertNotEqual(aerial.cachePath, aerial.applePath)
    }

    // MARK: - Muro's downloads live with the other wallpapers

    /// Beside the other videos, so a Download Folder on another drive holds
    /// them too, under a name that says whose they are.
    func testDownloadsGoBesideTheOtherWallpapers() {
        let library = URL(fileURLWithPath: "/tmp/lib")
        XCTAssertEqual(AppleAerials.cacheDir(libraryRoot: library).lastPathComponent, "Masters")
        XCTAssertEqual(AppleAerials.downloadFileName(assetID: "A"), "apple-A.mov")
    }

    func testPurgeTakesTheWholeFootprintAndNothingElse() throws {
        let library = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muro-lib-\(UUID().uuidString)", isDirectory: true)
        let masters = AppleAerials.cacheDir(libraryRoot: library)
        try FileManager.default.createDirectory(at: masters, withIntermediateDirectories: true)
        let aerial = masters.appendingPathComponent(AppleAerials.downloadFileName(assetID: "A"))
        try Data(repeating: 0, count: 2048).write(to: aerial)
        // The user's own wallpapers share the folder and must survive it.
        let own = masters.appendingPathComponent("\(UUID().uuidString).mov")
        try Data(repeating: 1, count: 512).write(to: own)
        try Data([0x02]).write(to: library.appendingPathComponent("library.json"))

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerial-info-\(UUID().uuidString)", isDirectory: true)
        AppleAerialInfo.directoryOverride = cacheDirectory
        defer { AppleAerialInfo.directoryOverride = nil }

        XCTAssertEqual(AppleAerials.cacheSize(libraryRoot: library), 2048)
        XCTAssertEqual(AppleAerials.purgeCache(libraryRoot: library), 2048)

        XCTAssertFalse(FileManager.default.fileExists(atPath: aerial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path),
                      "removing the feature must not touch the user's own wallpapers")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: library.appendingPathComponent("library.json").path),
            "removing the feature must not touch the user's own library"
        )
        XCTAssertEqual(AppleAerials.cacheSize(libraryRoot: library), 0)
    }

    /// library.json never lists them, so without the guard every Clear would
    /// delete the aerials Muro downloaded along with the real leftovers.
    func testOrphanSweepLeavesAerialsAlone() throws {
        let library = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muro-lib-\(UUID().uuidString)", isDirectory: true)
        let masters = library.appendingPathComponent("Masters", isDirectory: true)
        try FileManager.default.createDirectory(at: masters, withIntermediateDirectories: true)
        try LibraryManifest().save(root: library)
        let aerial = masters.appendingPathComponent(AppleAerials.downloadFileName(assetID: "A"))
        let leftover = masters.appendingPathComponent("\(UUID().uuidString).mov")
        for file in [aerial, leftover] {
            try Data(repeating: 0, count: 64).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: file.path)
        }

        _ = try LibraryWriter.sweepOrphans(root: library)

        XCTAssertTrue(FileManager.default.fileExists(atPath: aerial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "a real leftover is still swept")
    }

    // MARK: - What Apple's servers say

    private func withFacts(_ body: () throws -> Void) rethrows {
        AppleAerialInfo.directoryOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerial-info-\(UUID().uuidString)", isDirectory: true)
        AppleAerialInfo.clear()
        defer {
            AppleAerialInfo.clear()
            AppleAerialInfo.directoryOverride = nil
        }
        try body()
    }

    /// The size and the rest arrive from two reads. Neither may wipe out the
    /// other.
    func testFactsFromTwoReadsAreMerged() {
        withFacts {
            let video = URL(string: "https://sylvan.apple.com/a.mov")!
            AppleAerialInfo.record(.init(video: video.absoluteString, bytes: 441_000_000), assetID: "A")
            AppleAerialInfo.record(
                .init(video: video.absoluteString, duration: 300, width: 3840, height: 2160, fps: 240),
                assetID: "A"
            )
            let facts = AppleAerialInfo.facts(assetID: "A", video: video)
            XCTAssertEqual(facts?.bytes, 441_000_000)
            XCTAssertEqual(facts?.duration, 300)
            XCTAssertEqual(facts?.width, 3840)
        }
    }

    /// A new address from Apple is a new video, so what was known about the
    /// old one must not be shown for it.
    func testFactsForAnOlderVideoAreNotUsed() {
        withFacts {
            AppleAerialInfo.record(.init(video: "https://sylvan.apple.com/old.mov", bytes: 1), assetID: "A")
            XCTAssertNil(AppleAerialInfo.facts(
                assetID: "A", video: URL(string: "https://sylvan.apple.com/new.mov")!))
        }
    }

    /// The real numbers, once known, replace the stand-ins everywhere an
    /// aerial is shown as a wallpaper.
    func testEntryUsesTheRealFacts() throws {
        try withFacts {
            let root = try makeStore(
                assets: [asset(id: "A", nameKey: "K", category: "CAT-LAND")],
                categories: [landscapes],
                thumbnailsFor: ["A"], videosFor: ["A"]
            )
            let aerial = try XCTUnwrap(AppleAerials.load(root: root)?.first)
            AppleAerialInfo.record(
                .init(video: aerial.videoURL.absoluteString, duration: 428.7,
                      width: 3840, height: 2160, fps: 240),
                assetID: "A"
            )
            let entry = AppleAerials.entry(for: aerial)
            XCTAssertEqual(entry.duration, 428.7)
            XCTAssertEqual(entry.width, 3840)
            // No sharp picture yet: Apple's own still.
            XCTAssertEqual(entry.thumbnail, aerial.thumbnailPath)

            let frame = AppleAerialInfo.framePath(assetID: "A")
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: frame).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data([0xFF]).write(to: URL(fileURLWithPath: frame))
            XCTAssertEqual(AppleAerials.entry(for: aerial).thumbnail, frame,
                           "the sharp picture wins once it is there")
        }
    }

    // MARK: - Dynamic Wallpapers

    /// Apple names the two cuts of a dynamic wallpaper only "Light" and
    /// "Dark"; System Settings shows them under their group. Muro shows both
    /// cuts, so each card carries the group's name too.
    func testLightAndDarkCutsCarryTheirGroupsName() throws {
        var light = asset(id: "L", nameKey: "DYN_LIGHT", category: "dynamic-aerials", order: 0)
        light["variant"] = ["appearance": "light", "orientation": "landscape"]
        light["subcategories"] = ["SUB-GG"]
        var dark = asset(id: "D", nameKey: "DYN_DARK", category: "dynamic-aerials", order: 0)
        dark["variant"] = ["appearance": "dark", "orientation": "landscape"]
        dark["subcategories"] = ["SUB-GG"]
        let dynamic: [String: Any] = [
            "id": "dynamic-aerials", "localizedNameKey": "DYN_CAT", "preferredOrder": 0,
            "subcategories": [["id": "SUB-GG", "localizedNameKey": "GG_NAME"]]
        ]
        let root = try makeStore(assets: [dark, light], categories: [dynamic])
        let data = try XCTUnwrap(FileManager.default.contents(
            atPath: root.appendingPathComponent("manifest/entries.json").path))
        let aerials = try XCTUnwrap(AppleAerials.parse(
            manifest: data, root: root,
            strings: ["DYN_LIGHT": "Light", "DYN_DARK": "Dark", "DYN_CAT": "Dynamic Wallpapers",
                      "GG_NAME": "Golden Gate"],
            cacheDir: root.appendingPathComponent("cache")
        ))
        XCTAssertEqual(aerials.map(\.name), ["Golden Gate Light", "Golden Gate Dark"],
                       "named after the group, light first")
    }

    /// Only a video is ever played by Muro. A picture or one macOS draws must
    /// never read as downloaded, even if a file sits where a video would.
    func testOnlyVideosArePlayable() {
        let maker = DynamicWallpapers.Maker(
            category: "Dynamic Wallpapers", categoryOrder: 0,
            cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        let picture = maker.picture(
            slug: "the-beach-light", name: "The Beach Light", order: 0, thumbnail: nil,
            source: URL(fileURLWithPath: NSTemporaryDirectory()), width: 6016, height: 6016,
            bytes: 65_395_097)
        let drawn = maker.drawn(
            slug: "sequoia", name: "Sequoia", order: 0, thumbnail: nil,
            source: URL(fileURLWithPath: NSTemporaryDirectory()))
        XCTAssertNil(picture.playablePath)
        XCTAssertNil(drawn.playablePath)
        XCTAssertTrue(AppleAerials.isMacOSOnly(picture.id))
        XCTAssertTrue(AppleAerials.isMacOSOnly(drawn.id))
        XCTAssertFalse(AppleAerials.isMacOSOnly(AppleAerials.muroID(assetID: "dynamic-tahoe-light")))
    }

    func testSlugsAreSafeInAPath() {
        XCTAssertEqual(DynamicWallpapers.slugged("Big Sur Graphic"), "big-sur-graphic")
        XCTAssertEqual(DynamicWallpapers.slugged("hello Orange"), "hello-orange")
        XCTAssertFalse(DynamicWallpapers.slugged("Utah’s Monument / Valley").contains("/"))
    }

    // MARK: - Shown by macOS

    /// A picture's record names its file twice, in the configuration and in
    /// Files, because macOS refuses the screen saver role without the second.
    func testPictureChoiceNamesItsFile() throws {
        let file = URL(fileURLWithPath: "/tmp/Muro Wallpapers/apple-picture-the-beach-light.heic")
        let choice = MacOSWallpaperChoice.picture(file: file)
        XCTAssertEqual(choice["Provider"] as? String, "com.apple.wallpaper.choice.image")
        let files = try XCTUnwrap(choice["Files"] as? [[String: String]])
        XCTAssertEqual(files.first?["relative"], file.absoluteString)
        let data = try XCTUnwrap(choice["Configuration"] as? Data)
        let configuration = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(configuration["type"] as? String, "imageFile")
        XCTAssertEqual((configuration["url"] as? [String: String])?["relative"], file.absoluteString)
    }

    func testDrawnProviderComesFromTheCardsID() {
        XCTAssertEqual(MacOSWallpaperChoice.drawnProvider(forAssetID: "drawn-sequoia"),
                       "com.apple.wallpaper.choice.sequoia")
        XCTAssertNil(MacOSWallpaperChoice.drawnProvider(forAssetID: "picture-the-beach-light"))
    }

    /// Muro's own desktop still goes through the same image provider, so only
    /// the same file counts as showing the same picture.
    func testOnlyTheSameFileCountsAsShowingIt() {
        let beach = MacOSWallpaperChoice.picture(file: URL(fileURLWithPath: "/tmp/a.heic"))
        let still = MacOSWallpaperChoice.picture(file: URL(fileURLWithPath: "/tmp/still.jpg"))
        let surface: [String: Any] = ["Content": ["Choices": [still]]]
        XCTAssertFalse(MacOSWallpaperChoice.surface(surface, shows: beach))
        XCTAssertTrue(MacOSWallpaperChoice.surface(["Content": ["Choices": [beach]]], shows: beach))
    }

    /// Both cards of a picture share one download, so either names both.
    func testLightAndDarkCardsShareADownload() {
        let maker = DynamicWallpapers.Maker(
            category: "D", categoryOrder: 0, cacheDir: URL(fileURLWithPath: NSTemporaryDirectory()))
        let dark = maker.picture(
            slug: "the-beach-dark", name: "The Beach Dark", order: 0, thumbnail: nil,
            source: URL(fileURLWithPath: "/tmp/x.zip"), width: nil, height: nil, bytes: nil)
        let sides = ApplePictures.sides(of: dark)
        XCTAssertEqual(sides?.light, "picture-the-beach-light")
        XCTAssertEqual(sides?.dark, "picture-the-beach-dark")
        let solar = maker.picture(
            slug: "solar-gradients", name: "Solar Gradients", order: 0, thumbnail: nil,
            source: URL(fileURLWithPath: "/tmp/x.zip"), width: nil, height: nil, bytes: nil)
        XCTAssertNil(ApplePictures.sides(of: solar), "kept whole, macOS changes it with the time of day")
    }

    // MARK: - Screen savers

    /// The record System Settings writes for a screen saver: the module's own
    /// address inside `module`, as a binary property list.
    func testScreenSaverChoiceNamesItsModule() throws {
        let module = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/Flurry.appex")
        let choice = AppleScreenSavers.choice(module: module)
        XCTAssertEqual(choice["Provider"] as? String, "com.apple.wallpaper.choice.screen-saver")
        let data = try XCTUnwrap(choice["Configuration"] as? Data)
        let configuration = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual((configuration["module"] as? [String: String])?["relative"], module.absoluteString)
    }

    /// Only macOS runs a screen saver, so a card for one is never downloaded
    /// or played by Muro.
    func testScreenSaversAreShownByMacOSOnly() {
        let saver = AppleScreenSavers.make(
            title: "Flurry", group: AppleScreenSavers.appleGroup,
            module: URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/Flurry.appex"),
            bundle: nil,
            thumbnails: FileManager.default.temporaryDirectory
                .appendingPathComponent("saver-thumbs-\(UUID().uuidString)"))
        XCTAssertEqual(saver.id, "apple-saver-flurry")
        XCTAssertTrue(AppleAerials.isMacOSOnly(saver.id))
        XCTAssertNil(saver.playablePath)
        XCTAssertNotNil(saver.thumbnailPath, "one without a picture of its own gets a drawn one")
    }
}

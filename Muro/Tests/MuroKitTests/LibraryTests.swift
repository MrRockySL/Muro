import XCTest
@testable import MuroKit

final class LibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(id: String = UUID().uuidString, title: String = "Test") -> WallpaperEntry {
        WallpaperEntry(
            id: id, title: title, category: "Nature",
            file: "Masters/\(id).mov", thumbnail: "Thumbnails/\(id).jpg",
            width: 3840, height: 2160, fps: 30, duration: 30, sizeBytes: 1234
        )
    }

    // MARK: - Manifest

    func testManifestRoundTrip() throws {
        var manifest = LibraryManifest()
        var one = entry(title: "One")
        one.efficientFile = "Masters/one-eff.mov"
        one.previewFile = "Previews/one-p720.mov"
        one.liked = true
        manifest.wallpapers = [one, entry(title: "Two")]
        try manifest.save(root: root)

        let loaded = LibraryManifest.load(root: root)
        XCTAssertEqual(loaded.wallpapers.count, 2)
        XCTAssertEqual(loaded.wallpapers[0].title, "One")
        XCTAssertEqual(loaded.wallpapers[0].efficientFile, "Masters/one-eff.mov")
        XCTAssertEqual(loaded.wallpapers[0].previewFile, "Previews/one-p720.mov")
        XCTAssertTrue(loaded.wallpapers[0].liked)
    }

    /// A library that has never been written, or one that got corrupted, must
    /// come back empty rather than throwing on the launch path.
    func testMissingAndCorruptManifestsLoadAsEmpty() throws {
        XCTAssertTrue(LibraryManifest.load(root: root).wallpapers.isEmpty)
        try Data("not json".utf8).write(to: LibraryManifest.manifestURL(root: root))
        XCTAssertTrue(LibraryManifest.load(root: root).wallpapers.isEmpty)
    }

    // MARK: - LibraryWriter

    /// The A6 bug: every writer used to load, change and save on its own, so
    /// two finishing together meant the later save dropped the other's entry.
    func testConcurrentWritesAllSurvive() throws {
        let count = 50
        DispatchQueue.concurrentPerform(iterations: count) { index in
            try? LibraryWriter.update(root: root) { manifest in
                manifest.wallpapers.append(self.entry(title: "Entry \(index)"))
            }
        }
        let loaded = LibraryManifest.load(root: root)
        XCTAssertEqual(loaded.wallpapers.count, count, "a concurrent write was lost")
        XCTAssertEqual(Set(loaded.wallpapers.map(\.title)).count, count)
    }

    func testUpdateReturnsWhatWasSaved() throws {
        let saved = try LibraryWriter.update(root: root) { manifest in
            manifest.wallpapers.append(self.entry(title: "Only"))
        }
        XCTAssertEqual(saved.wallpapers.map(\.title), ["Only"])
        XCTAssertEqual(LibraryManifest.load(root: root).wallpapers.map(\.title), ["Only"])
    }

    /// A throwing change must leave the file exactly as it was.
    func testAFailedChangeDoesNotWriteAPartialLibrary() throws {
        struct Boom: Error {}
        _ = try LibraryWriter.update(root: root) { $0.wallpapers = [self.entry(title: "Kept")] }
        XCTAssertThrowsError(
            try LibraryWriter.update(root: root) { manifest in
                manifest.wallpapers.removeAll()
                throw Boom()
            }
        )
        XCTAssertEqual(LibraryManifest.load(root: root).wallpapers.map(\.title), ["Kept"])
    }

    // MARK: - EngineConfig

    func testConfigRoundTripIncludingThePauseSettings() throws {
        var config = EngineConfig(allDisplays: .init(wallpaperID: "abc", mode: "efficient"))
        config.perDisplay["uuid-1"] = .init(wallpaperID: "def", mode: "smooth")
        config.paused = true
        config.playbackSpeed = 1.25
        config.autoPauseLowPower = true
        config.autoPauseBattery = false
        config.autoPauseFullScreen = false
        try config.save(root: root)

        let loaded = EngineConfig.load(root: root)
        XCTAssertEqual(loaded.allDisplays?.wallpaperID, "abc")
        XCTAssertEqual(loaded.allDisplays?.mode, "efficient")
        XCTAssertEqual(loaded.perDisplay["uuid-1"]?.wallpaperID, "def")
        XCTAssertEqual(loaded.paused, true)
        XCTAssertEqual(loaded.playbackSpeed, 1.25)
        XCTAssertEqual(loaded.autoPauseLowPower, true)
        XCTAssertEqual(loaded.autoPauseBattery, false)
        XCTAssertEqual(loaded.autoPauseFullScreen, false)
    }

    /// Someone updating from 2.0 has a config with none of the newer keys.
    /// It must still load, and the absent settings must mean their defaults.
    func testAnOldConfigStillLoads() throws {
        let old = """
        {"allDisplays": {"wallpaperID": "abc", "mode": "smooth"}, "perDisplay": {}}
        """
        try Data(old.utf8).write(to: EngineConfig.configURL(root: root))
        let loaded = EngineConfig.load(root: root)
        XCTAssertEqual(loaded.allDisplays?.wallpaperID, "abc")
        XCTAssertNil(loaded.autoPauseFullScreen)
        XCTAssertNil(loaded.paused)
        // How the engine reads a missing value: covered wallpapers pause.
        XCTAssertTrue(loaded.autoPauseFullScreen ?? true)
    }

    func testPerDisplayAssignmentBeatsTheAllDisplaysFallback() {
        var config = EngineConfig(allDisplays: .init(wallpaperID: "fallback"))
        config.perDisplay["uuid-1"] = .init(wallpaperID: "specific")
        XCTAssertEqual(config.assignment(forDisplayUUID: "uuid-1")?.wallpaperID, "specific")
        XCTAssertEqual(config.assignment(forDisplayUUID: "uuid-2")?.wallpaperID, "fallback")
        XCTAssertEqual(config.assignment(forDisplayUUID: nil)?.wallpaperID, "fallback")
    }

    // MARK: - File resolution

    func testEfficientModeUsesTheVariantOnlyWhenItExists() {
        var withVariant = entry(id: "abc")
        withVariant.efficientFile = "Masters/abc-eff.mov"
        XCTAssertEqual(
            resolveVideoURL(entry: withVariant, mode: "efficient", root: root).lastPathComponent,
            "abc-eff.mov"
        )
        XCTAssertEqual(
            resolveVideoURL(entry: withVariant, mode: "smooth", root: root).lastPathComponent,
            "abc.mov"
        )
        // No variant generated yet: fall back to the master rather than
        // pointing the engine at a file that is not there.
        let plain = entry(id: "abc")
        XCTAssertEqual(
            resolveVideoURL(entry: plain, mode: "efficient", root: root).lastPathComponent,
            "abc.mov"
        )
    }

    // MARK: - Playlists

    func testPlaylistRoundTrip() throws {
        let playlists = [
            Playlist(name: "Evening", wallpaperIDs: ["a", "b"], intervalMinutes: 15, shuffle: true),
            Playlist(name: "Work", wallpaperIDs: ["c"]),
        ]
        try PlaylistStore.save(playlists, root: root)
        let loaded = PlaylistStore.load(root: root)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Evening")
        XCTAssertEqual(loaded[0].wallpaperIDs, ["a", "b"])
        XCTAssertEqual(loaded[0].intervalMinutes, 15)
        XCTAssertTrue(loaded[0].shuffle)
        XCTAssertEqual(loaded[1].intervalMinutes, 30, "the default interval")
    }

    func testMissingPlaylistsFileLoadsAsEmpty() {
        XCTAssertTrue(PlaylistStore.load(root: root).isEmpty)
    }
}

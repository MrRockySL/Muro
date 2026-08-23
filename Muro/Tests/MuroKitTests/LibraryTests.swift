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

    // MARK: - Deleting a wallpaper

    /// The delete path removes exactly this list. A wallpaper with a lazily
    /// generated efficient variant and a preview owns four files, not two.
    func testAWallpaperKnowsEveryFileItOwns() {
        var full = entry(id: "abc")
        full.efficientFile = "Masters/abc-eff.mov"
        full.previewFile = "Previews/abc-p720.mov"
        XCTAssertEqual(full.relativeFiles, [
            "Masters/abc.mov", "Masters/abc-eff.mov",
            "Previews/abc-p720.mov", "Thumbnails/abc.jpg",
        ])
        // Nothing generated yet: two files, and no nil in the list.
        XCTAssertEqual(entry(id: "abc").relativeFiles, ["Masters/abc.mov", "Thumbnails/abc.jpg"])
    }

    /// The whole destructive half, against real files: the entries go, their
    /// files go, and nothing that was not asked for is touched.
    func testDeletingWallpapersRemovesTheirEntriesAndTheirFiles() throws {
        var doomed = entry(id: "doomed")
        doomed.efficientFile = "Masters/doomed-eff.mov"
        doomed.previewFile = "Previews/doomed-p720.mov"
        let kept = entry(id: "kept")
        _ = try LibraryWriter.update(root: root) { $0.wallpapers = [doomed, kept] }
        for relative in doomed.relativeFiles + kept.relativeFiles {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("video".utf8).write(to: url)
        }

        let after = try LibraryWriter.delete(ids: ["doomed"], root: root)

        XCTAssertEqual(after.wallpapers.map(\.id), ["kept"])
        XCTAssertEqual(LibraryManifest.load(root: root).wallpapers.map(\.id), ["kept"])
        for relative in doomed.relativeFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path),
                "\(relative) was left on disk"
            )
        }
        for relative in kept.relativeFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path),
                "\(relative) belonged to another wallpaper"
            )
        }
    }

    /// Deleting a wallpaper whose files are already missing is not an error:
    /// a half-finished download or a hand-cleaned folder must still be
    /// removable from the Library rather than becoming a card that cannot go.
    func testDeletingAWallpaperWithNoFilesLeftStillRemovesTheEntry() throws {
        _ = try LibraryWriter.update(root: root) { $0.wallpapers = [self.entry(id: "ghost")] }
        let after = try LibraryWriter.delete(ids: ["ghost"], root: root)
        XCTAssertTrue(after.wallpapers.isEmpty)
    }

    /// B6: deleting a wallpaper used to leave its id behind in every playlist
    /// that referenced it, so the rotation kept trying to apply a file that
    /// was no longer on disk.
    func testDeletedWallpapersLeaveNoIdsBehindInPlaylists() {
        let playlists = [
            Playlist(id: "p1", name: "Mixed", wallpaperIDs: ["a", "b", "c"]),
            Playlist(id: "p2", name: "Untouched", wallpaperIDs: ["d"]),
        ]
        let result = PlaylistStore.pruned(playlists, removing: ["a", "c"])
        XCTAssertEqual(result.playlists[0].wallpaperIDs, ["b"])
        XCTAssertEqual(result.playlists[1].wallpaperIDs, ["d"])
        XCTAssertTrue(result.emptied.isEmpty)
    }

    /// A playlist that loses its last wallpaper has to be reported, because a
    /// running one must stop rather than tick over an empty list forever.
    func testAPlaylistThatLosesItsLastWallpaperIsReported() {
        let playlists = [
            Playlist(id: "p1", name: "Gone", wallpaperIDs: ["a", "b"]),
            Playlist(id: "p2", name: "Kept", wallpaperIDs: ["b", "c"]),
        ]
        let result = PlaylistStore.pruned(playlists, removing: ["a", "b"])
        XCTAssertEqual(result.emptied, ["p1"])
        XCTAssertEqual(result.playlists[1].wallpaperIDs, ["c"])
    }

    /// A playlist the user deliberately left empty is not something a delete
    /// just emptied, so it must not stop anything or raise a notice.
    func testAnAlreadyEmptyPlaylistIsNotReportedAsEmptied() {
        let playlists = [Playlist(id: "p1", name: "Empty", wallpaperIDs: [])]
        XCTAssertTrue(PlaylistStore.pruned(playlists, removing: ["a"]).emptied.isEmpty)
    }
}

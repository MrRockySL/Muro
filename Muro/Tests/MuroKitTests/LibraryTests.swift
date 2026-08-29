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

    // MARK: - A damaged manifest

    /// Missing and damaged are not the same thing, and every writer decision
    /// below depends on telling them apart.
    func testManifestStateTellsMissingFromDamagedFromReadable() throws {
        guard case .missing = LibraryManifest.state(root: root) else {
            return XCTFail("a library with no manifest should read as missing")
        }

        try Data("{ not json".utf8).write(to: LibraryManifest.manifestURL(root: root))
        guard case .damaged = LibraryManifest.state(root: root) else {
            return XCTFail("an undecodable manifest should read as damaged")
        }

        var manifest = LibraryManifest()
        manifest.wallpapers = [entry(title: "Real")]
        try manifest.save(root: root)
        guard case .loaded(let loaded) = LibraryManifest.state(root: root) else {
            return XCTFail("a good manifest should read as loaded")
        }
        XCTAssertEqual(loaded.wallpapers.map(\.title), ["Real"])
    }

    /// **The bug.** `update` loaded, applied and saved, and `load` answers an
    /// undecodable file with an empty manifest, so the next ordinary edit
    /// wrote that emptiness over the only record of what the library held.
    /// One corrupt byte plus one heart tap used to erase every entry.
    func testALikeDoesNotEraseALibraryItCouldNotRead() throws {
        var manifest = LibraryManifest()
        manifest.wallpapers = [entry(title: "One"), entry(title: "Two")]
        try manifest.save(root: root)

        // Damage it the way a truncated write would.
        let url = LibraryManifest.manifestURL(root: root)
        let good = try Data(contentsOf: url)
        try good.prefix(good.count / 2).write(to: url)
        let damaged = try Data(contentsOf: url)

        // A like is the smallest possible edit, and it was enough.
        XCTAssertThrowsError(
            try LibraryWriter.update(root: root) { manifest in
                guard !manifest.wallpapers.isEmpty else { return }
                manifest.wallpapers[0].liked = true
            }
        ) { error in
            XCTAssertEqual(error as? LibraryWriter.WriteError, .manifestUnreadable)
        }

        XCTAssertEqual(
            try Data(contentsOf: url), damaged,
            "the damaged manifest is the only record left of what was in the library"
        )
    }

    /// Nothing is deleted on the way to refusing, so a repaired file brings
    /// the whole library straight back.
    func testARepairedManifestWorksAgain() throws {
        var manifest = LibraryManifest()
        manifest.wallpapers = [entry(title: "One")]
        try manifest.save(root: root)
        let good = try Data(contentsOf: LibraryManifest.manifestURL(root: root))

        try Data("broken".utf8).write(to: LibraryManifest.manifestURL(root: root))
        XCTAssertThrowsError(
            try LibraryWriter.update(root: root) { $0.wallpapers.append(self.entry(title: "Two")) }
        )

        try good.write(to: LibraryManifest.manifestURL(root: root))
        let saved = try LibraryWriter.update(root: root) {
            $0.wallpapers.append(self.entry(title: "Two"))
        }
        XCTAssertEqual(saved.wallpapers.map(\.title), ["One", "Two"])
    }

    /// A library that has never been written is not damaged, and refusing
    /// there would mean the first import could never happen.
    func testANewLibraryWithNoManifestStillWrites() throws {
        let saved = try LibraryWriter.update(root: root) {
            $0.wallpapers.append(self.entry(title: "First"))
        }
        XCTAssertEqual(saved.wallpapers.map(\.title), ["First"])
        XCTAssertEqual(LibraryManifest.load(root: root).wallpapers.map(\.title), ["First"])
    }

    /// Delete goes through `update`, so it inherits the refusal. It must not
    /// remove any files either: it works out what to delete from the manifest
    /// it cannot read.
    func testDeleteDoesNotTouchFilesWhenTheManifestIsUnreadable() throws {
        let masters = root.appendingPathComponent("Masters", isDirectory: true)
        try FileManager.default.createDirectory(at: masters, withIntermediateDirectories: true)
        let video = masters.appendingPathComponent("keep.mov")
        try Data("video".utf8).write(to: video)

        try Data("not json".utf8).write(to: LibraryManifest.manifestURL(root: root))
        XCTAssertThrowsError(try LibraryWriter.delete(ids: ["anything"], root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
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

    // MARK: - Orphan sweep

    private func write(_ relative: String, bytes: Int, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path
            )
        }
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    /// The leak this exists to plug: importing writes the video before it
    /// appends the manifest row, so a crash in between leaves files that no id
    /// names and therefore nothing can ever reach again.
    func testSweepRemovesUnreferencedFiles() throws {
        try LibraryManifest().save(root: root)
        let old = Date().addingTimeInterval(-3600)
        try write("Masters/stranded.mov", bytes: 2048, modified: old)
        try write("Thumbnails/stranded.jpg", bytes: 512, modified: old)

        let freed = try LibraryWriter.sweepOrphans(root: root)

        XCTAssertEqual(freed, 2560)
        XCTAssertFalse(exists("Masters/stranded.mov"))
        XCTAssertFalse(exists("Thumbnails/stranded.jpg"))
    }

    /// The sweep must never touch a wallpaper that is actually in the library,
    /// including its optional efficient and preview files.
    func testSweepKeepsReferencedFiles() throws {
        var kept = entry(id: "keep")
        kept.efficientFile = "Masters/keep-eff.mov"
        kept.previewFile = "Previews/keep-p720.mov"
        var manifest = LibraryManifest()
        manifest.wallpapers = [kept]
        try manifest.save(root: root)

        let old = Date().addingTimeInterval(-3600)
        for relative in kept.relativeFiles { try write(relative, bytes: 128, modified: old) }

        let freed = try LibraryWriter.sweepOrphans(root: root)

        XCTAssertEqual(freed, 0)
        for relative in kept.relativeFiles { XCTAssertTrue(exists(relative), relative) }
    }

    /// The dangerous case. A file with no manifest row yet is indistinguishable
    /// from an import still writing it — and that import can be `muro-import`
    /// in another process, which this one cannot see. Recent files are spared
    /// so the sweep cannot delete the very file it is meant to stop leaking.
    func testSweepSparesFilesStillBeingWritten() throws {
        try LibraryManifest().save(root: root)
        try write("Masters/in-progress.mov", bytes: 4096)

        let freed = try LibraryWriter.sweepOrphans(root: root)

        XCTAssertEqual(freed, 0)
        XCTAssertTrue(exists("Masters/in-progress.mov"))
    }

    /// A shorter grace must still hold the line: the file ages past the cutoff
    /// and only then becomes sweepable.
    func testSweepGraceIsRespected() throws {
        try LibraryManifest().save(root: root)
        try write("Masters/aging.mov", bytes: 1024, modified: Date().addingTimeInterval(-30))

        XCTAssertEqual(try LibraryWriter.sweepOrphans(root: root, grace: 60), 0)
        XCTAssertTrue(exists("Masters/aging.mov"))

        XCTAssertEqual(try LibraryWriter.sweepOrphans(root: root, grace: 10), 1024)
        XCTAssertFalse(exists("Masters/aging.mov"))
    }

    /// The whole library, one button press, from one unreadable file. Nothing
    /// references anything when the manifest does not decode, so every file
    /// looks stranded. Reading the library has to succeed before deleting
    /// from it is allowed.
    func testSweepRefusesToRunOnAManifestThatDidNotLoad() throws {
        try write("Masters/real.mov", bytes: 4096, modified: Date().addingTimeInterval(-3600))
        try Data("{ not json".utf8)
            .write(to: LibraryManifest.manifestURL(root: root))

        XCTAssertEqual(try LibraryWriter.sweepOrphans(root: root), 0)
        XCTAssertTrue(exists("Masters/real.mov"))
        // And the unreadable manifest is still there to be repaired by hand,
        // rather than overwritten with an empty one on the way past.
        XCTAssertEqual(
            try Data(contentsOf: LibraryManifest.manifestURL(root: root)).count, 10
        )
    }

    /// Same reasoning for a manifest that is missing rather than broken. It
    /// costs almost nothing: the first import that finishes writes one, and
    /// the next sweep picks up anything an earlier crash left behind.
    func testSweepRefusesToRunWithNoManifestAtAll() throws {
        try write("Masters/real.mov", bytes: 4096, modified: Date().addingTimeInterval(-3600))

        XCTAssertEqual(try LibraryWriter.sweepOrphans(root: root), 0)
        XCTAssertTrue(exists("Masters/real.mov"))
    }
}

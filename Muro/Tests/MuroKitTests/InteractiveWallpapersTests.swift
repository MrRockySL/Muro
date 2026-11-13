import XCTest
@testable import MuroKit

/// Issue #59, interactive wallpapers: what counts as one, what deleting one
/// may take with it, how Muro's own are read, and how a person's own come in.
final class InteractiveWallpapersTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-interactive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func entry(file: String, thumbnail: String = "Thumbnails/a.jpg") -> WallpaperEntry {
        WallpaperEntry(
            id: "a", title: "A", category: importedVideoCategory, file: file,
            thumbnail: thumbnail, width: 0, height: 0, fps: 0, duration: 0, sizeBytes: 0
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Telling the two kinds apart

    func testAPageIsAnInteractiveWallpaperAndAVideoIsNot() {
        XCTAssertTrue(entry(file: "Interactive/a/index.html").isInteractive)
        XCTAssertTrue(entry(file: "Interactive/a/Page.HTM").isInteractive)
        XCTAssertTrue(entry(file: "/Applications/Muro.app/Contents/Resources/Interactive/eclipse/index.html").isInteractive)
        XCTAssertFalse(entry(file: "Masters/a.mov").isInteractive)
        XCTAssertFalse(entry(file: "Masters/html.mov").isInteractive)
    }

    func testAnOlderLibraryStillReadsOne() throws {
        // Nothing was added to library.json for these, so the entry is the
        // same shape as a video's and decodes like one.
        let manifest = LibraryManifest(wallpapers: [entry(file: "Interactive/a/index.html")])
        try manifest.save(root: scratch)
        let back = LibraryManifest.load(root: scratch)
        XCTAssertEqual(back.wallpapers.first?.isInteractive, true)
    }

    // MARK: - Deleting

    func testDeletingOneTakesItsOwnFolder() {
        XCTAssertEqual(
            entry(file: "Interactive/abc/index.html").relativeFiles,
            ["Interactive/abc", "Thumbnails/a.jpg"]
        )
    }

    func testDeletingNeverTakesAFolderThatIsNotItsOwn() {
        // A path of any other shape names the page alone. The folder above a
        // page is never deleted unless it is one inside `Interactive`.
        for file in ["index.html", "Interactive/index.html", "Interactive//index.html",
                     "Interactive/../index.html", "Interactive/./index.html",
                     "Masters/abc/index.html", "Interactive/abc/deep/index.html"] {
            let files = entry(file: file).relativeFiles
            XCTAssertEqual(files, [file, "Thumbnails/a.jpg"], file)
        }
        // One of Muro's own, inside the app, owns nothing in the library.
        XCTAssertEqual(entry(file: "/Applications/Muro.app/x/index.html").relativeFiles, [])
        // And a video is as it always was.
        XCTAssertEqual(entry(file: "Masters/a.mov").relativeFiles, ["Masters/a.mov", "Thumbnails/a.jpg"])
    }

    func testDeletingFromTheLibraryRemovesTheWholeFolder() throws {
        let source = scratch.appendingPathComponent("My Wallpaper", isDirectory: true)
        try write("<html><title>Mine</title></html>", to: source.appendingPathComponent("index.html"))
        try write("let a = 1", to: source.appendingPathComponent("js/app.js"))
        let root = scratch.appendingPathComponent("Library", isDirectory: true)
        let added = try InteractiveWallpapers.importPage(source: source, root: root)
        let home = root.appendingPathComponent("Interactive/\(added.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("js/app.js").path))

        try LibraryWriter.delete(ids: [added.id], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Interactive").path))
        XCTAssertTrue(LibraryManifest.load(root: root).wallpapers.isEmpty)
    }

    // MARK: - Muro's own

    func testMurosOwnAreReadFromTheirFoldersInOrder() throws {
        let folder = scratch.appendingPathComponent("Interactive", isDirectory: true)
        for (name, id, order) in [("b", "interactive-muro-b", 2), ("a", "interactive-muro-a", 1)] {
            try write("<html></html>", to: folder.appendingPathComponent("\(name)/index.html"))
            try write(
                #"{"id":"\#(id)","title":"\#(name.uppercased())","added":"2026-11-13","order":\#(order)}"#,
                to: folder.appendingPathComponent("\(name)/wallpaper.json")
            )
        }
        // No name: not a wallpaper. Not one of Muro's ids: not taken either.
        try write("<html></html>", to: folder.appendingPathComponent("c/index.html"))
        try write("<html></html>", to: folder.appendingPathComponent("d/index.html"))
        try write(#"{"id":"someone-else","title":"D","added":"2026-11-13"}"#,
                  to: folder.appendingPathComponent("d/wallpaper.json"))

        let entries = InteractiveWallpapers.entries(in: folder)
        XCTAssertEqual(entries.map(\.id), ["interactive-muro-a", "interactive-muro-b"])
        XCTAssertEqual(entries.map(\.title), ["A", "B"])
        XCTAssertTrue(entries.allSatisfy(\.isInteractive))
        XCTAssertTrue(entries.allSatisfy { $0.category == InteractiveWallpapers.category })
        XCTAssertTrue(entries.allSatisfy { InteractiveWallpapers.isBuiltIn($0.id) })
        XCTAssertTrue(entries[0].file.hasPrefix("/"), "played where it lies, never copied")
        XCTAssertEqual(entries[0].relativeFiles, [])
        let day = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: entries[0].dateAdded
        )
        XCTAssertEqual([day.year, day.month, day.day], [2026, 11, 13])
    }

    func testTheWallpapersInTheProjectAreComplete() throws {
        // The three that ship: each has its page, its name and both pictures,
        // and a page that asks Muro for the pointer and the sound.
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Interactive", isDirectory: true)
        let entries = InteractiveWallpapers.entries(in: folder)
        XCTAssertEqual(entries.map(\.title), ["Eclipse", "White Sand", "Grey Silk"])
        for entry in entries {
            let home = URL(fileURLWithPath: entry.file).deletingLastPathComponent()
            for name in ["thumb.jpg", InteractiveWallpapers.stillName] {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: home.appendingPathComponent(name).path),
                    "\(entry.title) \(name)"
                )
            }
            let page = try String(contentsOfFile: entry.file, encoding: .utf8)
            for word in ["muro:mouse", "muro:audio", "muro:click"] {
                XCTAssertTrue(page.contains(word), "\(entry.title) \(word)")
            }
            // Shut in: a wallpaper of Muro's own asks the internet for nothing.
            XCTAssertFalse(page.contains("http://") || page.contains("https://"), entry.title)
        }
    }

    // MARK: - A person's own

    func testAFolderComesInWholeUnderItsOwnName() throws {
        let source = scratch.appendingPathComponent("Rain", isDirectory: true)
        try write("<html><head><title> Rain on Glass </title></head></html>",
                  to: source.appendingPathComponent("index.html"))
        try write("body{}", to: source.appendingPathComponent("style.css"))
        let root = scratch.appendingPathComponent("Library", isDirectory: true)

        XCTAssertTrue(InteractiveWallpapers.canImport(source))
        let entry = try InteractiveWallpapers.importPage(source: source, root: root)
        XCTAssertEqual(entry.title, "Rain on Glass")
        XCTAssertEqual(entry.category, importedVideoCategory, "a person's own stay in the Library")
        XCTAssertEqual(entry.file, "Interactive/\(entry.id)/index.html")
        XCTAssertTrue(entry.isInteractive)
        XCTAssertFalse(InteractiveWallpapers.isBuiltIn(entry.id))
        XCTAssertGreaterThan(entry.sizeBytes, 0)
        let home = root.appendingPathComponent("Interactive/\(entry.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("style.css").path))
        XCTAssertEqual(LibraryManifest.load(root: root).wallpapers.map(\.id), [entry.id])
        // The same page again is the same fingerprint, so it can be turned away.
        XCTAssertNotNil(entry.sourceFingerprint)
        XCTAssertEqual(entry.sourceFingerprint, InteractiveWallpapers.fingerprint(of: source))
    }

    func testALoosePageComesInAloneAndAFrontPageBringsItsFolder() throws {
        let folder = scratch.appendingPathComponent("Stuff", isDirectory: true)
        try write("<html></html>", to: folder.appendingPathComponent("clock.html"))
        try write("secret", to: folder.appendingPathComponent("notes.txt"))
        let loose = InteractiveWallpapers.source(for: folder.appendingPathComponent("clock.html"))
        XCTAssertNil(loose?.folder, "a page that is not a front page never takes the folder")

        let wallpaper = scratch.appendingPathComponent("Waves", isDirectory: true)
        try write("<html></html>", to: wallpaper.appendingPathComponent("index.html"))
        try write("x", to: wallpaper.appendingPathComponent("waves.js"))
        let front = InteractiveWallpapers.source(for: wallpaper.appendingPathComponent("index.html"))
        XCTAssertEqual(front?.folder?.lastPathComponent, "Waves")

        // A Lively or Wallpaper Engine folder says what it is, whatever the
        // page is called, and gives its own name.
        let lively = scratch.appendingPathComponent("lively", isDirectory: true)
        try write("<html></html>", to: lively.appendingPathComponent("main.html"))
        try write(#"{"Title":"Fluid"}"#, to: lively.appendingPathComponent("LivelyInfo.json"))
        let described = InteractiveWallpapers.source(for: lively.appendingPathComponent("main.html"))
        XCTAssertEqual(described?.folder?.lastPathComponent, "lively")
        XCTAssertEqual(InteractiveWallpapers.title(folder: lively, page: lively.appendingPathComponent("main.html")), "Fluid")

        let root = scratch.appendingPathComponent("Library", isDirectory: true)
        let alone = try InteractiveWallpapers.importPage(source: folder.appendingPathComponent("clock.html"), root: root)
        XCTAssertEqual(alone.title, "clock")
        let home = root.appendingPathComponent("Interactive/\(alone.id)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["index.html"])
    }

    func testAFolderWithNoPageIsTurnedAway() throws {
        let empty = scratch.appendingPathComponent("Empty", isDirectory: true)
        try write("hello", to: empty.appendingPathComponent("readme.txt"))
        XCTAssertFalse(InteractiveWallpapers.canImport(empty))
        XCTAssertThrowsError(try InteractiveWallpapers.importPage(source: empty, root: scratch)) {
            XCTAssertEqual($0 as? InteractiveWallpapers.ImportError, .noPage)
        }
        // Two pages and no front page: Muro does not guess.
        try write("<html></html>", to: empty.appendingPathComponent("a.html"))
        try write("<html></html>", to: empty.appendingPathComponent("b.html"))
        XCTAssertNil(InteractiveWallpapers.page(inFolder: empty))
    }

    // MARK: - The picture left on the desktop

    func testTheStillIsTheFoldersOwnOrElseTheThumbnail() throws {
        let home = scratch.appendingPathComponent("Interactive/abc", isDirectory: true)
        try write("<html></html>", to: home.appendingPathComponent("index.html"))
        let entry = entry(file: "Interactive/abc/index.html")
        XCTAssertNil(InteractiveWallpapers.stillPicture(for: entry, root: scratch))
        try write("jpeg", to: scratch.appendingPathComponent("Thumbnails/a.jpg"))
        XCTAssertEqual(
            InteractiveWallpapers.stillPicture(for: entry, root: scratch)?.lastPathComponent, "a.jpg"
        )
        try write("jpeg", to: home.appendingPathComponent(InteractiveWallpapers.stillName))
        XCTAssertEqual(
            InteractiveWallpapers.stillPicture(for: entry, root: scratch)?.lastPathComponent, "still.jpg"
        )
    }

    // MARK: - Sound

    func testALowNoteLandsInTheLowBandsAndSilenceIsSilence() {
        let rate: Float = 48_000
        let count = InteractiveBridge.bandCount
        let spectrum = SoundSpectrum()
        let silence = spectrum.bands(
            [Float](repeating: 0, count: SoundSpectrum.size), sampleRate: rate, count: count
        )
        XCTAssertEqual(silence.max(), 0)

        func tone(_ hertz: Float) -> [Float] {
            (0..<SoundSpectrum.size).map { 0.5 * sin(2 * .pi * hertz * Float($0) / rate) }
        }
        let low = spectrum.bands(tone(80), sampleRate: rate, count: count)
        let high = spectrum.bands(tone(6_000), sampleRate: rate, count: count)
        let lowPeak = low.firstIndex(of: low.max()!)!
        let highPeak = high.firstIndex(of: high.max()!)!
        XCTAssertLessThan(lowPeak, 10, "80 Hz is a bass note")
        XCTAssertGreaterThan(highPeak, 38, "6 kHz is treble")
        XCTAssertGreaterThan(low[lowPeak], 0.6)
        XCTAssertTrue(low.allSatisfy { (0...1).contains($0) })
    }

    // MARK: - The page's side

    func testTheBridgeOffersWhatAPageIsPromised() {
        let script = InteractiveBridge.script
        for word in ["muro:", "__mouse", "__click", "__audio", "__pause",
                     "wallpaperRegisterAudioListener", "livelyAudioListener",
                     "requestAnimationFrame", "mousemove"] {
            XCTAssertTrue(script.contains(word), word)
        }
        XCTAssertTrue(script.contains("var N = \(InteractiveBridge.bandCount);"))
    }
}

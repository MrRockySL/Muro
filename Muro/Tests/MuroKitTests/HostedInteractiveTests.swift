import XCTest
@testable import MuroKit

/// Interactive wallpapers hosted beside the live wallpapers. The "server" in
/// these tests is a folder read through file:// addresses, laid out exactly
/// like the real one.
final class HostedInteractiveTests: XCTestCase {
    private var server: URL!
    private var root: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-hosted-\(UUID().uuidString)", isDirectory: true)
        server = base.appendingPathComponent("server", isDirectory: true)
        root = base.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: server.deletingLastPathComponent())
    }

    /// Puts a wallpaper on the test server and returns its list entry.
    private func publish(
        id: String = "interactive-muro-test", title: String = "Test", author: String? = "MrRockySL",
        files: [String: String] = ["index.html": "<html>hello</html>", "thumb.jpg": "thumb", "still.jpg": "still"]
    ) throws -> HostedInteractive.Entry {
        let list = files.map { path, text in
            HostedInteractive.File(path: path, size: Int64(text.utf8.count), sha256: HostedInteractive.sha256(Data(text.utf8)))
        }.sorted { $0.path < $1.path }
        let entry = HostedInteractive.Entry(
            id: id, title: title, author: author, added: "2026-11-19", order: 1,
            version: HostedInteractive.version(of: list), files: list
        )
        for (path, text) in files {
            let url = HostedInteractive.fileURL(base: server, entry: entry, path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return entry
    }

    /// A sync where the person has every listed one unless `wanted` says
    /// otherwise.
    private func sync(_ entries: [HostedInteractive.Entry], wanted: Set<String>? = nil) async -> HostedInteractive.SyncResult {
        await HostedInteractive.sync(
            list: .init(wallpapers: entries), base: server, root: root,
            wanted: wanted ?? Set(entries.map(\.id))
        )
    }

    private var copies: URL { HostedInteractive.folder(root: root) }

    // MARK: - The list

    func testTheListSitsBesideTheCatalog() {
        XCTAssertEqual(
            HostedInteractive.listURL(catalogURL: URL(string: "https://cdn.murowallpaper.com/catalog.json")!).absoluteString,
            "https://cdn.murowallpaper.com/interactive.json"
        )
    }

    func testAFileLivesUnderItsWallpaperAndVersion() throws {
        let entry = try publish()
        XCTAssertEqual(
            HostedInteractive.fileURL(base: URL(string: "https://cdn.murowallpaper.com/")!, entry: entry, path: "assets/a.png").absoluteString,
            "https://cdn.murowallpaper.com/interactive/interactive-muro-test/\(entry.version)/assets/a.png"
        )
    }

    /// A later Muro may write entries an older one cannot read; those are left
    /// out, never the whole list.
    func testAnEntryThatCannotBeReadIsLeftOutNotTheList() throws {
        let json = """
        {"wallpapers": [
          {"id": "interactive-muro-a", "title": "A", "added": "2026-11-19", "version": "abcdef12", "files": []},
          {"id": "interactive-muro-b", "something": "new"}
        ]}
        """
        let list = try JSONDecoder().decode(HostedInteractive.List.self, from: Data(json.utf8))
        XCTAssertEqual(list.wallpapers.map(\.id), ["interactive-muro-a"])
    }

    func testOnlyPlainFileNamesInsideTheFolderAreAllowed() {
        for good in ["index.html", "thumb.jpg", "assets/rain.png", "a_b-c.9.js"] {
            XCTAssertTrue(HostedInteractive.isSafePath(good), good)
        }
        for bad in ["", "../x.html", "a/../../x", "/etc/passwd", "a//b", ".hidden", "a/.git/x", "Index.html",
                    "a b.png", "a\\b", "x?.js", "~/x"] {
            XCTAssertFalse(HostedInteractive.isSafePath(bad), bad)
        }
    }

    func testAnyChangedFileGivesANewVersion() {
        let a = [HostedInteractive.File(path: "index.html", size: 5, sha256: String(repeating: "a", count: 64))]
        let b = [HostedInteractive.File(path: "index.html", size: 5, sha256: String(repeating: "b", count: 64))]
        XCTAssertEqual(HostedInteractive.version(of: a), HostedInteractive.version(of: a))
        XCTAssertNotEqual(HostedInteractive.version(of: a), HostedInteractive.version(of: b))
        XCTAssertTrue(HostedInteractive.isSafeVersion(HostedInteractive.version(of: a)))
    }

    func testAWallpaperNeedsItsPageThumbnailAndStill() throws {
        XCTAssertTrue(HostedInteractive.isUsable(try publish()))
        XCTAssertFalse(HostedInteractive.isUsable(try publish(files: ["index.html": "x", "thumb.jpg": "t"])))
        XCTAssertFalse(HostedInteractive.isUsable(try publish(id: "my-own-thing")))
        var entry = try publish()
        entry.files.append(.init(path: "wallpaper.json", size: 2, sha256: HostedInteractive.sha256(Data("{}".utf8))))
        XCTAssertFalse(HostedInteractive.isUsable(entry), "wallpaper.json is written here, never downloaded")
    }

    // MARK: - Keeping the copies

    func testANewWallpaperIsDownloadedCheckedAndNamed() async throws {
        let entry = try publish(author: "bugbenderx")
        let result = await sync([entry])
        XCTAssertEqual(result.added, ["interactive-muro-test"])
        XCTAssertTrue(result.changed)
        let home = copies.appendingPathComponent("interactive-muro-test")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("index.html")), "<html>hello</html>")
        let read = InteractiveWallpapers.entriesAndAuthors(in: copies)
        XCTAssertEqual(read.entries.map(\.id), ["interactive-muro-test"])
        XCTAssertEqual(read.entries.first?.title, "Test")
        XCTAssertEqual(read.authors["interactive-muro-test"], "bugbenderx")
        XCTAssertTrue(read.entries.first?.isInteractive ?? false)
    }

    func testAnUpToDateCopyIsLeftAlone() async throws {
        let entry = try publish()
        _ = await sync([entry])
        let again = await sync([entry])
        XCTAssertFalse(again.changed)
        XCTAssertTrue(again.failed.isEmpty)
    }

    func testAChangedWallpaperReplacesTheOldCopy() async throws {
        _ = await sync([try publish()])
        let changed = try publish(files: ["index.html": "<html>new</html>", "thumb.jpg": "thumb", "still.jpg": "still"])
        let result = await sync([changed])
        XCTAssertEqual(result.updated, ["interactive-muro-test"])
        let page = copies.appendingPathComponent("interactive-muro-test/index.html")
        XCTAssertEqual(try String(contentsOf: page), "<html>new</html>")
    }

    /// A file swapped on the server never runs here, and the copy that was
    /// already working stays.
    func testAFileThatDoesNotMatchItsChecksumIsRefusedAndTheOldCopyStays() async throws {
        _ = await sync([try publish()])
        let changed = try publish(files: ["index.html": "<html>new</html>", "thumb.jpg": "thumb", "still.jpg": "still"])
        // The same size, other bytes: only the checksum can tell.
        try Data("<html>BAD</html>".utf8).write(to: HostedInteractive.fileURL(base: server, entry: changed, path: "index.html"))
        let result = await sync([changed])
        XCTAssertEqual(result.failed, ["interactive-muro-test"])
        XCTAssertFalse(result.changed)
        let page = copies.appendingPathComponent("interactive-muro-test/index.html")
        XCTAssertEqual(try String(contentsOf: page), "<html>hello</html>")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: copies.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testAnEntryAskingForAFileOutsideItsFolderIsNeverDownloaded() async throws {
        var entry = try publish()
        entry.files.append(.init(path: "../../evil.html", size: 1, sha256: String(repeating: "0", count: 64)))
        let result = await sync([entry])
        XCTAssertEqual(result.failed, ["interactive-muro-test"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies.appendingPathComponent("interactive-muro-test").path))
    }

    func testAWallpaperTheListDropsIsRemovedUnlessItIsInUse() async throws {
        let a = try publish(id: "interactive-muro-a")
        let b = try publish(id: "interactive-muro-b")
        _ = await sync([a, b])
        let result = await sync([], wanted: ["interactive-muro-b"])
        XCTAssertEqual(result.removed, ["interactive-muro-a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent("interactive-muro-b").path))
    }

    // MARK: - Downloaded only when asked (owner, 2026-11-19)

    /// Listed is not downloaded: like a live wallpaper, one waits in Explore
    /// until the person asks for it.
    func testNothingIsDownloadedThatThePersonDoesNotHave() async throws {
        let entry = try publish()
        let result = await sync([entry], wanted: [])
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies.appendingPathComponent(entry.id).path))
    }

    /// After an update from 6.1.1 the ones the person had are downloaded by
    /// themselves, and only those.
    func testOnlyTheOnesThePersonHasAreDownloaded() async throws {
        let a = try publish(id: "interactive-muro-a")
        let b = try publish(id: "interactive-muro-b")
        let result = await sync([a, b], wanted: ["interactive-muro-b"])
        XCTAssertEqual(result.added, ["interactive-muro-b"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies.appendingPathComponent("interactive-muro-a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent("interactive-muro-b/index.html").path))
    }

    /// Out of the Library and off every screen and list: its copy goes, even
    /// while the server still lists it.
    func testACopyNobodyHasAnyMoreIsRemoved() async throws {
        let entry = try publish()
        _ = await sync([entry])
        let result = await sync([entry], wanted: [])
        XCTAssertEqual(result.removed, [entry.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies.appendingPathComponent(entry.id).path))
    }

    func testADownloadIsCheckedAndTellsHowFarItIs() async throws {
        let entry = try publish(files: [
            "index.html": String(repeating: "p", count: 600),
            "thumb.jpg": String(repeating: "t", count: 300),
            "still.jpg": String(repeating: "s", count: 100),
        ])
        let seen = Reported()
        try await HostedInteractive.download(entry, base: server, root: root) { seen.add($0) }
        XCTAssertEqual(seen.values.count, 3)
        XCTAssertEqual(seen.values, seen.values.sorted())
        XCTAssertEqual(seen.values.last ?? 0, 1, accuracy: 0.0001)
        let read = InteractiveWallpapers.entriesAndAuthors(in: copies)
        XCTAssertEqual(read.entries.map(\.id), [entry.id])
        // Already here at this version: nothing is fetched again.
        let again = Reported()
        try await HostedInteractive.download(entry, base: server, root: root) { again.add($0) }
        XCTAssertEqual(again.values, [1])
    }

    func testADownloadThatDoesNotMatchItsChecksumLeavesNothing() async throws {
        let entry = try publish()
        try Data("<html>BAD!!</html>".utf8).write(to: HostedInteractive.fileURL(base: server, entry: entry, path: "index.html"))
        await XCTAssertThrowsErrorAsync(try await HostedInteractive.download(entry, base: server, root: root))
        let left = (try? FileManager.default.contentsOfDirectory(atPath: copies.path)) ?? []
        XCTAssertEqual(left, [])
    }

    /// Explore shows one that is not downloaded like a live wallpaper that is
    /// not: its thumbnail from the server, its whole size and its day.
    func testOneNotDownloadedLooksLikeACatalogEntry() throws {
        let entry = try publish(author: "bugbenderx")
        let base = URL(string: "https://cdn.murowallpaper.com/")!
        let shown = HostedInteractive.catalogEntry(for: entry, base: base)
        XCTAssertEqual(shown.id, entry.id)
        XCTAssertEqual(shown.category, InteractiveWallpapers.category)
        XCTAssertEqual(shown.sizeBytes, entry.totalSize)
        XCTAssertEqual(
            shown.thumbnail.absoluteString,
            "https://cdn.murowallpaper.com/interactive/interactive-muro-test/\(entry.version)/thumb.jpg"
        )
        XCTAssertNil(shown.preview720)
        let days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]
        XCTAssertEqual(shown.publishedAt, days.date(from: "2026-11-19"))
    }

    func testTheListIsKeptForWhenMuroIsOffline() throws {
        let list = HostedInteractive.List(wallpapers: [try publish()])
        XCTAssertNil(HostedInteractive.loadLocalList(root: root))
        try HostedInteractive.saveLocalList(list, root: root)
        XCTAssertEqual(HostedInteractive.loadLocalList(root: root), list)
    }

    func testAnEmptyServerListIsNotAnError() async throws {
        let missing = server.appendingPathComponent("nothing-here.json")
        await XCTAssertThrowsErrorAsync(try await HostedInteractive.fetchList(from: missing))
        let list = server.appendingPathComponent("interactive.json")
        try Data(#"{"wallpapers": []}"#.utf8).write(to: list)
        let read = try await HostedInteractive.fetchList(from: list)
        XCTAssertEqual(read.wallpapers.count, 0)
    }

    // MARK: - Checking a page before it is published

    func testReachingOutsideTheFolderIsFound() {
        let page = """
        <script src="https://cdn.example.com/x.js"></script>
        <script>fetch('/api'); new WebSocket('wss://a.b'); navigator.sendBeacon('/x');</script>
        <link href="//fonts.example.com/f.css">
        """
        let found = HostedInteractive.outsideReferences(in: page)
        XCTAssertTrue(found.contains { $0.hasPrefix("https://cdn.example.com") })
        XCTAssertTrue(found.contains { $0.hasPrefix("fetch") })
        XCTAssertTrue(found.contains("WebSocket"))
        XCTAssertTrue(found.contains("sendBeacon"))
        XCTAssertTrue(found.contains { $0.contains("//fonts.example.com") })
    }

    func testMarkupNamesAndBuiltInPicturesAreNotOutsideReferences() {
        let page = """
        <svg xmlns="http://www.w3.org/2000/svg"></svg>
        <img src="data:image/png;base64,iVBORw0KGgofetch(WebSocketAAAA=">
        <script>const a = 1; requestAnimationFrame(() => {});</script>
        """
        XCTAssertEqual(HostedInteractive.outsideReferences(in: page), [])
    }
}

/// What a download reported, collected from wherever it reported it.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        collected.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}

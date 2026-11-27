import XCTest
@testable import MuroKit

/// Static wallpapers: still pictures hosted beside the live wallpapers in a
/// list of their own.
final class HostedStaticsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-statics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ path: String, _ text: String) -> HostedInteractive.File {
        HostedInteractive.File(path: path, size: Int64(text.utf8.count), sha256: HostedInteractive.sha256(Data(text.utf8)))
    }

    private func entry(
        id: String = "static-test", title: String = "Test", added: String = "2026-11-27",
        order: Int? = nil, picture: String = "picture.png", pictureText: String = "picture",
        thumbnail: String = "thumb.jpg", thumbnailText: String = "thumb"
    ) -> HostedStatics.Entry {
        let p = file(picture, pictureText)
        let t = file(thumbnail, thumbnailText)
        return HostedStatics.Entry(
            id: id, title: title, author: nil, added: added, order: order,
            width: 3840, height: 2160, version: HostedStatics.version(picture: p, thumbnail: t),
            picture: p, thumbnail: t
        )
    }

    func testUsableEntry() {
        XCTAssertTrue(HostedStatics.isUsable(entry()))
        XCTAssertTrue(HostedStatics.isStatic("static-abc"))
        XCTAssertFalse(HostedStatics.isStatic("interactive-muro-eclipse"))
    }

    func testUnusableEntries() {
        XCTAssertFalse(HostedStatics.isUsable(entry(id: "abc")), "the id must start with static-")
        XCTAssertFalse(HostedStatics.isUsable(entry(id: "static-")), "an id needs more than the prefix")
        XCTAssertFalse(HostedStatics.isUsable(entry(id: "static-a/b")), "no folders in an id")
        XCTAssertFalse(HostedStatics.isUsable(entry(title: "  ")), "a title is needed")
        XCTAssertFalse(HostedStatics.isUsable(entry(picture: "picture.gif")), "only pictures macOS shows")
        XCTAssertFalse(HostedStatics.isUsable(entry(picture: "a/picture.png")), "no folders in a file name")
        XCTAssertFalse(HostedStatics.isUsable(entry(picture: "Picture.png")), "lower case file names only")
        XCTAssertFalse(HostedStatics.isUsable(entry(thumbnail: "card.jpg")), "the card picture is thumb.jpg")
        XCTAssertFalse(HostedStatics.isUsable(entry(picture: "thumb.jpg")), "two different files")
        var empty = entry()
        empty.picture.size = 0
        XCTAssertFalse(HostedStatics.isUsable(empty), "an empty picture is wrong")
        var badHash = entry()
        badHash.picture.sha256 = "xyz"
        XCTAssertFalse(HostedStatics.isUsable(badHash))
    }

    func testListSkipsWhatItCannotRead() throws {
        let good = entry()
        let data = try JSONEncoder().encode(HostedStatics.List(wallpapers: [good]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(object["wallpapers"] as? [Any])
        items.append(["id": "static-broken"])
        object["wallpapers"] = items
        let mixed = try JSONSerialization.data(withJSONObject: object)
        let list = try JSONDecoder().decode(HostedStatics.List.self, from: mixed)
        XCTAssertEqual(list.wallpapers, [good])
    }

    /// The pinned one first (AJ's picture), then newest first.
    func testOrder() {
        let older = entry(id: "static-older", title: "Older", added: "2026-11-01")
        let newer = entry(id: "static-newer", title: "Newer", added: "2026-12-01")
        let pinned = entry(id: "static-pinned", title: "Pinned", added: "2026-10-01", order: 0)
        let second = entry(id: "static-second", title: "Second", added: "2026-09-01", order: 1)
        let sorted = HostedStatics.sorted([older, second, newer, pinned])
        XCTAssertEqual(sorted.map(\.id), ["static-pinned", "static-second", "static-newer", "static-older"])
    }

    func testCatalogEntry() throws {
        let base = try XCTUnwrap(URL(string: "https://cdn.example.com/"))
        let e = entry()
        let card = HostedStatics.catalogEntry(for: e, base: base)
        XCTAssertEqual(card.category, HostedStatics.category)
        XCTAssertEqual(card.width, 3840)
        XCTAssertEqual(card.sizeBytes, e.picture.size)
        XCTAssertEqual(card.video.absoluteString, "https://cdn.example.com/statics/static-test/\(e.version)/picture.png")
        XCTAssertEqual(card.thumbnail.absoluteString, "https://cdn.example.com/statics/static-test/\(e.version)/thumb.jpg")
        XCTAssertNotNil(card.publishedAt)
        XCTAssertEqual(
            HostedStatics.listURL(catalogURL: try XCTUnwrap(URL(string: "https://cdn.example.com/catalog.json"))).absoluteString,
            "https://cdn.example.com/statics.json"
        )
    }

    func testVersionFollowsTheFiles() {
        XCTAssertNotEqual(entry().version, entry(pictureText: "another picture").version)
        XCTAssertNotEqual(entry().version, entry(thumbnailText: "another card").version)
        XCTAssertEqual(entry().version, entry().version)
    }

    func testInstallChecksAndPlacesTheFiles() throws {
        let e = entry()
        let download = root.appendingPathComponent("download.tmp")
        try Data("picture".utf8).write(to: download)
        XCTAssertFalse(HostedStatics.isDownloaded(e, root: root))
        try HostedStatics.install(e, picture: download, thumbnail: Data("thumb".utf8), root: root)
        XCTAssertTrue(HostedStatics.isDownloaded(e, root: root))
        XCTAssertEqual(try Data(contentsOf: HostedStatics.pictureFile(for: e, root: root)), Data("picture".utf8))
        XCTAssertEqual(try Data(contentsOf: HostedStatics.thumbnailFile(for: e, root: root)), Data("thumb".utf8))
        XCTAssertEqual(HostedStatics.downloadedIDs(root: root), ["static-test"])

        HostedStatics.removeDownloads(id: e.id, root: root)
        XCTAssertFalse(HostedStatics.isDownloaded(e, root: root))
        XCTAssertTrue(HostedStatics.downloadedIDs(root: root).isEmpty)
    }

    /// A downloaded one is a library entry Muro can show, read from its own
    /// files, so the engine needs no list.
    func testDownloadedEntriesBecomeLibraryEntries() throws {
        let e = entry(id: "static-shown", title: "Shown", order: 0)
        let download = root.appendingPathComponent("download.tmp")
        try Data("picture".utf8).write(to: download)
        try HostedStatics.install(e, picture: download, thumbnail: Data("thumb".utf8), root: root)

        XCTAssertEqual(HostedStatics.downloadedEntries(root: root), [e])
        let library = try XCTUnwrap(HostedStatics.libraryEntries(root: root).first)
        XCTAssertEqual(library.id, "static-shown")
        XCTAssertTrue(library.isStatic)
        XCTAssertFalse(library.isInteractive)
        XCTAssertEqual(library.file, "Statics/static-shown/\(e.version)/picture.png")
        XCTAssertEqual(library.thumbnail, "Statics/static-shown/\(e.version)/thumb.jpg")
        XCTAssertEqual(library.fps, 0)
        XCTAssertEqual(library.category, HostedStatics.category)
        XCTAssertEqual(
            resolveLibraryFile(library.file, root: root).path,
            HostedStatics.pictureFile(for: e, root: root).path
        )
        XCTAssertEqual(
            HostedStatics.stillVideoFile(for: library, root: root).path,
            HostedStatics.home(for: e, root: root).appendingPathComponent("still.mov").path
        )
    }

    /// A download made before the record beside the files existed is still
    /// found, through the copy of the list.
    func testDownloadedEntriesFallBackToTheList() throws {
        let e = entry(id: "static-older-download")
        let home = HostedStatics.home(for: e, root: root)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("picture".utf8).write(to: HostedStatics.pictureFile(for: e, root: root))
        try Data("thumb".utf8).write(to: HostedStatics.thumbnailFile(for: e, root: root))
        XCTAssertTrue(HostedStatics.downloadedEntries(root: root).isEmpty, "no record and no list: not shown")
        try HostedStatics.saveLocalList(HostedStatics.List(wallpapers: [e]), root: root)
        XCTAssertEqual(HostedStatics.downloadedEntries(root: root), [e])
    }

    /// A new version replaces the old one on disk.
    func testInstallKeepsOneVersion() throws {
        let first = entry(id: "static-versions")
        let second = entry(id: "static-versions", pictureText: "picture two")
        let download = root.appendingPathComponent("download.tmp")
        try Data("picture".utf8).write(to: download)
        try HostedStatics.install(first, picture: download, thumbnail: Data("thumb".utf8), root: root)
        try Data("picture two".utf8).write(to: download)
        try HostedStatics.install(second, picture: download, thumbnail: Data("thumb".utf8), root: root)
        let versions = try FileManager.default.contentsOfDirectory(
            atPath: HostedStatics.folder(root: root).appendingPathComponent("static-versions").path
        )
        XCTAssertEqual(versions, [second.version])
        XCTAssertEqual(HostedStatics.downloadedEntries(root: root), [second])
    }

    func testInstallRefusesAChangedFile() throws {
        let e = entry()
        let download = root.appendingPathComponent("download.tmp")
        try Data("pictur3".utf8).write(to: download)
        XCTAssertThrowsError(try HostedStatics.install(e, picture: download, thumbnail: Data("thumb".utf8), root: root))
        XCTAssertFalse(HostedStatics.isDownloaded(e, root: root))
        try Data("picture".utf8).write(to: download)
        XCTAssertThrowsError(try HostedStatics.install(e, picture: download, thumbnail: Data("thumX".utf8), root: root))
        XCTAssertFalse(HostedStatics.isDownloaded(e, root: root))
    }
}

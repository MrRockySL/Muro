import XCTest
@testable import MuroKit

/// Moving the wallpaper videos out of the library and back. The library path
/// `Masters/<id>.mov` must keep working wherever they are, and nothing may be
/// lost or deleted that Muro did not make.
final class DownloadFolderTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        base = manager.temporaryDirectory
            .appendingPathComponent("muro-folder-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Library", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? manager.removeItem(at: base)
    }

    // MARK: - Helpers

    private var masters: URL { DownloadFolder.mastersURL(root: root) }

    private func place(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func addVideos(_ names: [String], to folder: URL) throws {
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in names.enumerated() {
            try Data(repeating: UInt8(index + 1), count: 1000 * (index + 1))
                .write(to: folder.appendingPathComponent(name))
        }
    }

    private func isLink(_ url: URL) -> Bool {
        (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func names(in folder: URL) -> [String] {
        ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: - Moving

    func testALibraryStartsWithItsOwnFolder() {
        XCTAssertEqual(DownloadFolder.location(root: root), .builtIn)
    }

    func testMovingOutLinksMastersToTheNewFolder() throws {
        try addVideos(["a.mov", "b.mov", "c.mov"], to: masters)
        let drive = try place("Drive")
        var steps: [Int] = []

        try DownloadFolder.move(root: root, into: drive) { done, _ in steps.append(done) }

        let folder = drive.appendingPathComponent(DownloadFolder.folderName, isDirectory: true)
        XCTAssertEqual(DownloadFolder.location(root: root), .custom(folder))
        XCTAssertTrue(isLink(masters))
        XCTAssertEqual(names(in: folder), ["a.mov", "b.mov", "c.mov"])
        // The paths the rest of Muro uses still reach every video.
        XCTAssertEqual(try Data(contentsOf: masters.appendingPathComponent("c.mov")).count, 3000)
        XCTAssertTrue(DownloadFolder.isOurs(folder))
        XCTAssertEqual(steps, [0, 1, 2, 3])
        // Nothing is left behind in the library.
        XCTAssertEqual(names(in: root), ["Masters"])
    }

    func testMovingBackPutsARealFolderInTheLibrary() throws {
        try addVideos(["a.mov", "b.mov"], to: masters)
        let drive = try place("Drive")
        try DownloadFolder.move(root: root, into: drive)

        try DownloadFolder.move(root: root, into: nil)

        XCTAssertEqual(DownloadFolder.location(root: root), .builtIn)
        XCTAssertFalse(isLink(masters))
        XCTAssertEqual(names(in: masters), ["a.mov", "b.mov"])
        XCTAssertFalse(manager.fileExists(atPath: drive.appendingPathComponent(DownloadFolder.folderName).path))
        XCTAssertEqual(names(in: root), ["Masters"])
    }

    func testMovingBetweenTwoPlaces() throws {
        try addVideos(["a.mov"], to: masters)
        let first = try place("First")
        let second = try place("Second")
        try DownloadFolder.move(root: root, into: first)

        try DownloadFolder.move(root: root, into: second)

        let folder = second.appendingPathComponent(DownloadFolder.folderName, isDirectory: true)
        XCTAssertEqual(DownloadFolder.location(root: root), .custom(folder))
        XCTAssertEqual(names(in: folder), ["a.mov"])
        XCTAssertFalse(manager.fileExists(atPath: first.appendingPathComponent(DownloadFolder.folderName).path))
    }

    func testAnEmptyLibraryMovesToo() throws {
        let drive = try place("Drive")
        try DownloadFolder.move(root: root, into: drive)
        let folder = drive.appendingPathComponent(DownloadFolder.folderName, isDirectory: true)
        XCTAssertEqual(DownloadFolder.location(root: root), .custom(folder))
        // A download after the move lands in the new place.
        try Data([1, 2, 3]).write(to: masters.appendingPathComponent("new.mov"))
        XCTAssertEqual(names(in: folder), ["new.mov"])
    }

    func testMovingBackWhenAlreadyHomeDoesNothing() throws {
        try addVideos(["a.mov"], to: masters)
        try DownloadFolder.move(root: root, into: nil)
        XCTAssertEqual(DownloadFolder.location(root: root), .builtIn)
        XCTAssertEqual(names(in: masters), ["a.mov"])
    }

    // MARK: - Refusals

    func testAFolderThatHoldsOtherFilesIsNeverUsed() throws {
        try addVideos(["a.mov"], to: masters)
        let drive = try place("Drive")
        let theirs = drive.appendingPathComponent(DownloadFolder.folderName, isDirectory: true)
        try manager.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: theirs.appendingPathComponent("notes.txt"))

        XCTAssertThrowsError(try DownloadFolder.move(root: root, into: drive)) { error in
            XCTAssertEqual(error as? DownloadFolder.MoveError, .folderInUse)
        }
        XCTAssertEqual(DownloadFolder.location(root: root), .builtIn)
        XCTAssertEqual(names(in: masters), ["a.mov"])
        XCTAssertEqual(names(in: theirs), ["notes.txt"])
    }

    func testAPlaceInsideTheLibraryIsRefused() throws {
        XCTAssertThrowsError(try DownloadFolder.move(root: root, into: root)) { error in
            XCTAssertEqual(error as? DownloadFolder.MoveError, .insideLibrary)
        }
    }

    func testTheSamePlaceTwiceSaysSo() throws {
        let drive = try place("Drive")
        try DownloadFolder.move(root: root, into: drive)
        XCTAssertThrowsError(try DownloadFolder.move(root: root, into: drive)) { error in
            XCTAssertEqual(error as? DownloadFolder.MoveError, .alreadyThere)
        }
    }

    func testPickingMurosOwnFolderIsRefused() throws {
        let drive = try place("Drive")
        try DownloadFolder.move(root: root, into: drive)
        let folder = drive.appendingPathComponent(DownloadFolder.folderName, isDirectory: true)
        XCTAssertThrowsError(try DownloadFolder.move(root: root, into: folder)) { error in
            XCTAssertEqual(error as? DownloadFolder.MoveError, .insideLibrary)
        }
    }

    func testAFolderThatIsGoneIsNotConnected() throws {
        try addVideos(["a.mov"], to: masters)
        let drive = try place("Drive")
        try DownloadFolder.move(root: root, into: drive)
        try manager.removeItem(at: drive)

        guard case .unavailable = DownloadFolder.location(root: root) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertThrowsError(try DownloadFolder.move(root: root, into: nil)) { error in
            guard case .notConnected = error as? DownloadFolder.MoveError else {
                return XCTFail("expected notConnected, got \(error)")
            }
        }
        // Still a link: nothing was rebuilt on this disk while it was away.
        XCTAssertTrue(isLink(masters))
    }

    // MARK: - Pieces

    func testAVideoThatArrivedDuringTheMoveIsCarriedAcross() throws {
        let old = try place("Old")
        let new = try place("New")
        try addVideos(["late.mov"], to: old)
        try Data("marker".utf8).write(to: old.appendingPathComponent(DownloadFolder.markerName))

        DownloadFolder.finishLeaving(old, for: new, removeFolder: true)

        XCTAssertEqual(names(in: new), ["late.mov"])
        XCTAssertFalse(manager.fileExists(atPath: old.path))
    }

    func testItsOwnFolderIsReusedWithoutCopyingAgain() throws {
        try addVideos(["a.mov"], to: masters)
        let drive = try place("Drive")
        let folder = drive.appendingPathComponent(DownloadFolder.folderName, isDirectory: true)
        try addVideos(["a.mov"], to: folder)
        try Data("marker".utf8).write(to: folder.appendingPathComponent(DownloadFolder.markerName))

        try DownloadFolder.move(root: root, into: drive)

        XCTAssertEqual(DownloadFolder.location(root: root), .custom(folder))
        XCTAssertEqual(names(in: folder), ["a.mov"])
    }

    func testPlaceNames() {
        XCTAssertEqual(DownloadFolder.placeName(URL(fileURLWithPath: "/Volumes/ALL/Muro Wallpapers")), "ALL")
        XCTAssertEqual(DownloadFolder.placeName(URL(fileURLWithPath: "/Users/someone/Movies/Muro Wallpapers")), "Movies")
    }
}

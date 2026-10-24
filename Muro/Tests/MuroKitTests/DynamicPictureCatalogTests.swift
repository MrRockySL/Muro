import XCTest
@testable import MuroKit

/// Where Apple's still Dynamic Wallpapers download from (issue #53).
///
/// macOS keeps a catalogue of their addresses and sizes, but only once it has
/// needed one. On a Mac without it every still picture had no address, the
/// cards said 0 MB and Download failed with "no such file". Muro now keeps its
/// own copy of Apple's public catalogue for that case. The shapes below are
/// copied from the real catalogue, 2026-10-24.
final class DynamicPictureCatalogTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("picture-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        AppleAerialInfo.directoryOverride = folder
    }

    override func tearDownWithError() throws {
        AppleAerialInfo.directoryOverride = nil
        StubbedCatalog.reply = nil
        try? FileManager.default.removeItem(at: folder)
    }

    /// One picture, the way Apple's catalogue lists it.
    private func asset(_ id: String, file: String, bytes: Int) -> [String: Any] {
        [
            "DesktopPictureID": id,
            "__BaseURL": "https://updates.cdn-apple.com/2025/mobileassets/072-29818/74AF556A/",
            "__RelativePath": "com_apple_MobileAsset_DesktopPicture/\(file).zip",
            "_DownloadSize": bytes,
            "_CompressionAlgorithm": "zip",
        ]
    }

    private func catalogue(_ assets: [[String: Any]]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["AssetType": "com.apple.MobileAsset.DesktopPicture", "Assets": assets],
            format: .xml, options: 0)
    }

    func testCatalogueGivesEachPictureItsAddressAndSize() throws {
        let found = DynamicWallpapers.downloads(from: try catalogue([
            asset("Chroma Red", file: "da5d0b60", bytes: 41_338_164),
        ]))
        XCTAssertEqual(
            found["Chroma Red"]?.url.absoluteString,
            "https://updates.cdn-apple.com/2025/mobileassets/072-29818/74AF556A/"
                + "com_apple_MobileAsset_DesktopPicture/da5d0b60.zip")
        XCTAssertEqual(found["Chroma Red"]?.bytes, 41_338_164)
    }

    /// The case in issue #53: no catalogue on the Mac at all.
    func testMuroCopyGivesAddressesWhenTheMacHasNone() throws {
        let saved = folder.appendingPathComponent("saved.xml")
        try catalogue([asset("Big Sur", file: "a", bytes: 5), asset("Chroma Red", file: "b", bytes: 7)])
            .write(to: saved)
        let found = DynamicWallpapers.assetDownloads(
            macOS: folder.appendingPathComponent("not-there.xml"), saved: saved)
        XCTAssertEqual(Set(found.keys), ["Big Sur", "Chroma Red"])
        XCTAssertEqual(found["Chroma Red"]?.bytes, 7)
    }

    /// macOS's own copy is the one macOS downloads with, so it always wins.
    /// Muro's copy only fills the gaps.
    func testMacOSCopyWinsAndMuroCopyFillsTheGaps() throws {
        let macOS = folder.appendingPathComponent("macos.xml")
        let saved = folder.appendingPathComponent("saved.xml")
        try catalogue([asset("Chroma Red", file: "from-macos", bytes: 1)]).write(to: macOS)
        try catalogue([
            asset("Chroma Red", file: "from-muro", bytes: 2),
            asset("Big Sur", file: "only-muro", bytes: 3),
        ]).write(to: saved)
        let found = DynamicWallpapers.assetDownloads(macOS: macOS, saved: saved)
        XCTAssertEqual(found["Chroma Red"]?.url.lastPathComponent, "from-macos.zip")
        XCTAssertEqual(found["Chroma Red"]?.bytes, 1)
        XCTAssertEqual(found["Big Sur"]?.url.lastPathComponent, "only-muro.zip")
    }

    /// The placeholder path was never a file, and copying it was the "no such
    /// file" error. Only a still picture can be left with one.
    func testOnlyAPictureWithNoAddressLacksOne() {
        let maker = DynamicWallpapers.Maker(category: "D", categoryOrder: 0, cacheDir: folder)
        let placeholder = maker.picture(
            slug: "chroma-red-light", name: "Chroma Red Light", order: 0, thumbnail: nil,
            source: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Chroma Red"),
            width: 6016, height: 6016, bytes: nil)
        let addressed = maker.picture(
            slug: "chroma-red-light", name: "Chroma Red Light", order: 0, thumbnail: nil,
            source: URL(string: "https://updates.cdn-apple.com/x.zip")!,
            width: 6016, height: 6016, bytes: 41_338_164)
        let sonoma = maker.video(
            slug: "sonoma-light", name: "Sonoma Light", order: 0, thumbnail: nil,
            videoURL: URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers/Sonoma/x.mov"),
            applePath: "/System/Library/Desktop Pictures/.wallpapers/Sonoma/x.mov")
        XCTAssertTrue(DynamicWallpapers.lacksAddress(placeholder))
        XCTAssertFalse(DynamicWallpapers.lacksAddress(addressed))
        XCTAssertFalse(DynamicWallpapers.lacksAddress(sonoma), "a video on the Mac is played where it lies")
    }

    func testFetchKeepsApplesCatalogue() async throws {
        StubbedCatalog.reply = (200, try catalogue([asset("Chroma Red", file: "b", bytes: 7)]))
        try await DynamicWallpapers.fetchPublicCatalog(session: StubbedCatalog.session)
        XCTAssertEqual(
            DynamicWallpapers.downloads(in: DynamicWallpapers.savedCatalog)["Chroma Red"]?.bytes, 7)
    }

    /// A Wi-Fi sign-in page answers with HTML, and a server error may carry
    /// anything. Neither may count as a catalogue or replace the good copy.
    func testFetchNeverKeepsAPageThatIsNotACatalogue() async throws {
        let good = try catalogue([asset("Chroma Red", file: "b", bytes: 7)])
        try good.write(to: DynamicWallpapers.savedCatalog)
        let replies: [(status: Int, body: Data)] = [
            (200, Data("<html>Sign in to the Wi-Fi</html>".utf8)),
            (404, good),
        ]
        for reply in replies {
            StubbedCatalog.reply = reply
            do {
                try await DynamicWallpapers.fetchPublicCatalog(session: StubbedCatalog.session)
                XCTFail("an answer with status \(reply.status) was kept")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: DynamicWallpapers.savedCatalog), good)
        }
    }
}

/// Answers every request with `reply`, so the tests never reach Apple.
private final class StubbedCatalog: URLProtocol {
    nonisolated(unsafe) static var reply: (status: Int, body: Data)?

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedCatalog.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = Self.reply, let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

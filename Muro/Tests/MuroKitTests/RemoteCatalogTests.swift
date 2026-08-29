import XCTest
@testable import MuroKit

/// catalog.json is fetched from the network and is the one file that reaches
/// every installed copy of Muro at once, so decoding it must never be brittle.
final class RemoteCatalogTests: XCTestCase {
    private func decode(_ json: String) throws -> RemoteCatalog {
        try RemoteCatalog.makeDecoder().decode(RemoteCatalog.self, from: Data(json.utf8))
    }

    private func entryJSON(
        id: String,
        preview: Bool = true,
        published: Bool = true
    ) -> String {
        """
        {
          "id": "\(id)", "title": "Test", "category": "Nature",
          "width": 3840, "height": 2160, "fps": 30, "duration": 29.97,
          "sizeBytes": 41792484,
          "video": "https://example.com/masters/\(id).mov",
          "thumbnail": "https://example.com/thumbs/\(id).jpg"
          \(preview ? ", \"preview720\": \"https://example.com/p720/\(id).mov\"" : "")
          \(published ? ", \"publishedAt\": \"2026-08-03T10:00:00Z\"" : "")
        }
        """
    }

    func testDecodesAFullEntry() throws {
        let catalog = try decode("""
        {"wallpapers": [\(entryJSON(id: "abc"))]}
        """)
        XCTAssertEqual(catalog.wallpapers.count, 1)
        let entry = catalog.wallpapers[0]
        XCTAssertEqual(entry.id, "abc")
        XCTAssertEqual(entry.width, 3840)
        XCTAssertNotNil(entry.preview720)
        XCTAssertNotNil(entry.publishedAt)
    }

    /// Catalogs published before these fields existed are still live for old
    /// installs, and 33 of the 99 entries have no publishedAt today.
    func testDecodesAnEntryMissingTheOptionalFields() throws {
        let catalog = try decode("""
        {"wallpapers": [\(entryJSON(id: "abc", preview: false, published: false))]}
        """)
        XCTAssertNil(catalog.wallpapers[0].preview720)
        XCTAssertNil(catalog.wallpapers[0].publishedAt)
    }

    /// A duplicate id used to crash the app at launch, for everyone, until a
    /// new catalog was published. Decoding must simply hand both over.
    func testDuplicateIDsDecodeWithoutCrashing() throws {
        let catalog = try decode("""
        {"wallpapers": [\(entryJSON(id: "same")), \(entryJSON(id: "same"))]}
        """)
        XCTAssertEqual(catalog.wallpapers.count, 2)
    }

    /// The lookup the app builds from that list, which is where the crash was.
    func testBuildingALookupFromDuplicateIDsKeepsTheFirst() throws {
        let catalog = try decode("""
        {"wallpapers": [\(entryJSON(id: "same")), \(entryJSON(id: "same"))]}
        """)
        var first = catalog.wallpapers[0]
        first.title = "First"
        var second = catalog.wallpapers[1]
        second.title = "Second"
        let byID = Dictionary(
            [first, second].map { ($0.id, $0) },
            uniquingKeysWith: { earlier, _ in earlier }
        )
        XCTAssertEqual(byID.count, 1)
        XCTAssertEqual(byID["same"]?.title, "First")
    }

    /// The app decodes and muro-publish encodes, from different targets, so
    /// the date format has to survive a round trip.
    func testPublishedAtSurvivesARoundTrip() throws {
        let original = try decode("{\"wallpapers\": [\(entryJSON(id: "abc"))]}")
        let data = try RemoteCatalog.makeEncoder().encode(original)
        let again = try RemoteCatalog.makeDecoder().decode(RemoteCatalog.self, from: data)
        XCTAssertEqual(again.wallpapers[0].publishedAt, original.wallpapers[0].publishedAt)
        XCTAssertEqual(again.wallpapers[0].preview720, original.wallpapers[0].preview720)
    }

    func testMalformedJSONThrowsRatherThanCrashing() {
        XCTAssertThrowsError(try decode("{\"wallpapers\": \"not an array\"}"))
    }

    // MARK: - Why the catalog did not arrive
    //
    // A user reported an empty Explore as "how can I view the explore
    // section". The catalog was live and correct; his machine could not reach
    // it, and the app had no way to say so because every failure was swallowed
    // and answered with "Nothing matches that". These pin the three answers
    // apart.

    /// A static host answers a rate limit or a missing key with an HTML page,
    /// so the body decodes as garbage. Classifying on the body alone is what
    /// made a throttled CDN look like a badly filtered page, and it is why the
    /// status code is checked before the decoder ever sees the bytes.
    func testAnHTMLErrorPageIsNotMistakenForAnEmptyCatalog() {
        let html = Data("<!doctype html><html><title>Not Found</title></html>".utf8)
        XCTAssertThrowsError(
            try RemoteCatalog.makeDecoder().decode(RemoteCatalog.self, from: html)
        ) { error in
            XCTAssertEqual(CatalogError.classify(error), .unreadable)
        }
    }

    func testOfflineIsReportedAsUnreachable() {
        XCTAssertEqual(
            CatalogError.classify(URLError(.notConnectedToInternet)), .unreachable
        )
    }

    /// A blocked or unresolvable host is the shape a DNS filter, a VPN or a
    /// company network takes.
    func testABlockedHostIsReportedAsUnreachable() {
        for code in [URLError.cannotFindHost, .timedOut, .networkConnectionLost,
                     .secureConnectionFailed, .cannotConnectToHost] {
            XCTAssertEqual(CatalogError.classify(URLError(code)), .unreachable)
        }
    }

    func testAServerErrorKeepsItsStatusCode() {
        let rateLimited = CatalogError.server(status: 429)
        XCTAssertEqual(CatalogError.classify(rateLimited), rateLimited)
        XCTAssertTrue(rateLimited.detail.contains("429"))
    }

    /// Anything unrecognised has to land on unreachable: that sends someone to
    /// look at their connection rather than at filters that were never the
    /// problem.
    func testAnUnknownErrorFallsBackToUnreachable() {
        struct Odd: Error {}
        XCTAssertEqual(CatalogError.classify(Odd()), .unreachable)
    }

    /// Every case has to be sayable out loud, and the project does not put
    /// em-dashes in front of users.
    func testEveryCaseHasCopyAPersonCanRead() {
        for problem in [CatalogError.unreachable, .server(status: 503), .unreadable] {
            XCTAssertFalse(problem.title.isEmpty)
            XCTAssertFalse(problem.detail.isEmpty)
            XCTAssertFalse(problem.title.contains("—"), "em-dash in \(problem)")
            XCTAssertFalse(problem.detail.contains("—"), "em-dash in \(problem)")
            // Never the old message, which blamed the filters for a network
            // failure.
            XCTAssertFalse(problem.detail.lowercased().contains("category"))
        }
    }
}

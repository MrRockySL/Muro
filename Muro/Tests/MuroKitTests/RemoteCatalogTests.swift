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
}

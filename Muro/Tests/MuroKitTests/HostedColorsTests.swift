import XCTest
@testable import MuroKit

/// Colour options: a few live wallpapers in more colours, each colour a live
/// wallpaper of its own, from a list of their own.
final class HostedColorsTests: XCTestCase {
    private let familyID = "a117033d-2cdf-4462-8154-351decce4b6e"

    private func file(_ name: String, _ text: String) -> HostedInteractive.File {
        HostedInteractive.File(path: name, size: Int64(text.utf8.count), sha256: HostedInteractive.sha256(Data(text.utf8)))
    }

    private func variant(_ key: String, name: String? = nil, hex: String = "#F83D31", text: String = "x") -> HostedColors.Variant {
        let master = file(HostedColors.masterName, "master \(key) \(text)")
        let preview = file(HostedColors.previewName, "preview \(key) \(text)")
        let thumbnail = file(HostedColors.thumbnailName, "thumb \(key) \(text)")
        return HostedColors.Variant(
            key: key, name: name ?? key.capitalized, hex: hex,
            version: HostedColors.version(master: master, preview: preview, thumbnail: thumbnail),
            width: 4096, height: 2304, fps: 30, duration: 30,
            master: master, preview: preview, thumbnail: thumbnail
        )
    }

    private func family(
        id: String? = nil, original: String = "blue", keys: [String] = ["red", "purple", "silver"],
        order: Int? = 0, added: String = "2026-11-27"
    ) -> HostedColors.Family {
        HostedColors.Family(
            id: id ?? familyID,
            original: HostedColors.Swatch(key: original, name: original.capitalized, hex: "#0E9BFB"),
            colors: keys.map { variant($0) }, order: order, added: added
        )
    }

    private func catalogEntry(id: String, title: String = "Sword in Blue Flowers") throws -> CatalogEntry {
        CatalogEntry(
            id: id, title: title, category: "Abstract", width: 4096, height: 2304, fps: 30, duration: 30,
            sizeBytes: 59_763_581,
            video: try XCTUnwrap(URL(string: "https://cdn.example.com/masters/\(id).mov")),
            thumbnail: try XCTUnwrap(URL(string: "https://cdn.example.com/thumbs/\(id).jpg"))
        )
    }

    func testIDs() throws {
        let id = HostedColors.id(family: familyID, key: "red")
        XCTAssertEqual(id, "color-red-\(familyID)")
        XCTAssertTrue(HostedColors.isColor(id))
        XCTAssertFalse(HostedColors.isColor(familyID))
        let parsed = try XCTUnwrap(HostedColors.parse(id))
        XCTAssertEqual(parsed.key, "red")
        XCTAssertEqual(parsed.family, familyID)
        XCTAssertEqual(HostedColors.familyID(of: id), familyID)
        XCTAssertEqual(HostedColors.familyID(of: familyID), familyID, "the original is its own family")
        XCTAssertNil(HostedColors.parse("color-"), "nothing after the prefix")
        XCTAssertNil(HostedColors.parse("color-red"), "no family")
        XCTAssertNil(HostedColors.parse("color-Red-\(familyID)"), "keys are lower case")
        XCTAssertNil(HostedColors.parse("color-red-color-blue-\(familyID)"), "a colour is never a family")
    }

    func testUsableFamily() {
        XCTAssertTrue(HostedColors.isUsable(family()))
    }

    func testUnusableFamilies() {
        XCTAssertFalse(HostedColors.isUsable(family(id: "color-red-abc")), "a colour cannot have colours")
        XCTAssertFalse(HostedColors.isUsable(family(id: "a/b")), "no folders in an id")
        XCTAssertFalse(HostedColors.isUsable(family(id: "ABC")), "lower case ids only")
        XCTAssertFalse(HostedColors.isUsable(family(keys: [])), "at least one colour")
        XCTAssertFalse(HostedColors.isUsable(family(keys: ["a", "b", "c", "d", "e", "f", "g", "h"])), "at most seven colours")
        XCTAssertFalse(HostedColors.isUsable(family(keys: ["red", "red"])), "a key once")
        XCTAssertFalse(HostedColors.isUsable(family(original: "red", keys: ["red", "silver"])), "not the original's key again")
        XCTAssertFalse(HostedColors.isUsable(family(added: "27 Nov")), "the day as yyyy-MM-dd")

        var badHex = family()
        badHex.colors[0].hex = "red"
        XCTAssertFalse(HostedColors.isUsable(badHex))
        var badName = family()
        badName.colors[0].name = "  "
        XCTAssertFalse(HostedColors.isUsable(badName))
        var badFile = family()
        badFile.colors[0].master.path = "video.mov"
        XCTAssertFalse(HostedColors.isUsable(badFile), "the master is master.mov")
        var badHash = family()
        badHash.colors[0].preview.sha256 = "xyz"
        XCTAssertFalse(HostedColors.isUsable(badHash))
        var empty = family()
        empty.colors[0].thumbnail.size = 0
        XCTAssertFalse(HostedColors.isUsable(empty))
        var badVersion = family()
        badVersion.colors[0].version = "v1"
        XCTAssertFalse(HostedColors.isUsable(badVersion))
        var noLength = family()
        noLength.colors[0].duration = 0
        XCTAssertFalse(HostedColors.isUsable(noLength))
    }

    func testListSkipsWhatItCannotRead() throws {
        let good = family()
        let data = try JSONEncoder().encode(HostedColors.List(wallpapers: [good]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var items = try XCTUnwrap(object["wallpapers"] as? [Any])
        items.append(["id": "broken"])
        object["wallpapers"] = items
        let mixed = try JSONSerialization.data(withJSONObject: object)
        let list = try JSONDecoder().decode(HostedColors.List.self, from: mixed)
        XCTAssertEqual(list.wallpapers, [good])
    }

    /// The pinned ones first, then newest first.
    func testOrder() {
        let older = family(id: "older", order: nil, added: "2026-11-01")
        let newer = family(id: "newer", order: nil, added: "2026-12-01")
        let pinned = family(id: "pinned", order: 0, added: "2026-10-01")
        let second = family(id: "second", order: 1, added: "2026-09-01")
        XCTAssertEqual(
            HostedColors.sorted([older, second, newer, pinned]).map(\.id),
            ["pinned", "second", "newer", "older"]
        )
    }

    func testVersionFollowsTheFiles() {
        XCTAssertEqual(variant("red").version, variant("red").version)
        XCTAssertNotEqual(variant("red").version, variant("red", text: "y").version)
    }

    /// A colour is the original's live wallpaper in its own files: its title
    /// and category, its own video, preview, card picture and size.
    func testCatalogEntry() throws {
        let base = try XCTUnwrap(URL(string: "https://cdn.example.com/"))
        let fam = family()
        let colour = fam.colors[0]
        let entry = HostedColors.catalogEntry(
            for: colour, family: fam, original: try catalogEntry(id: familyID), base: base)
        XCTAssertEqual(entry.id, "color-red-\(familyID)")
        XCTAssertEqual(entry.title, "Sword in Blue Flowers")
        XCTAssertEqual(entry.category, "Abstract")
        XCTAssertEqual(entry.sizeBytes, colour.master.size)
        XCTAssertEqual(entry.fps, 30)
        let folder = "https://cdn.example.com/colors/\(familyID)/red/\(colour.version)"
        XCTAssertEqual(entry.video.absoluteString, "\(folder)/master.mov")
        XCTAssertEqual(entry.preview720?.absoluteString, "\(folder)/p720.mov")
        XCTAssertEqual(entry.thumbnail.absoluteString, "\(folder)/thumb.jpg")
        XCTAssertNotNil(entry.publishedAt)
        XCTAssertEqual(
            HostedColors.listURL(catalogURL: try XCTUnwrap(URL(string: "https://cdn.example.com/catalog.json"))).absoluteString,
            "https://cdn.example.com/colors.json"
        )
    }

    /// Only usable families whose original is in the catalog, each colour once.
    func testCatalogEntries() throws {
        let base = try XCTUnwrap(URL(string: "https://cdn.example.com/"))
        let listed = family()
        let notInCatalog = family(id: "elsewhere")
        var broken = family(id: "broken")
        broken.colors[1].hex = "nope"
        let list = HostedColors.List(wallpapers: [listed, notInCatalog, broken, listed])
        let catalog = [try catalogEntry(id: familyID), try catalogEntry(id: "broken")]
        let entries = HostedColors.catalogEntries(list: list, catalog: catalog, base: base)
        XCTAssertEqual(entries.map(\.id), ["red", "purple", "silver"].map { "color-\($0)-\(familyID)" })
    }

    func testLocalListRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-colors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(HostedColors.loadLocalList(root: root))
        let list = HostedColors.List(wallpapers: [family()])
        try HostedColors.saveLocalList(list, root: root)
        XCTAssertEqual(HostedColors.loadLocalList(root: root), list)
    }
}

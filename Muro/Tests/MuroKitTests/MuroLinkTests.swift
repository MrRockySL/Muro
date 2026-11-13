import XCTest
@testable import MuroKit

/// muro:// links. Any web page can open one, so what a link is allowed to ask
/// for is decided here, before the app changes anything.
final class MuroLinkTests: XCTestCase {
    private let builtIn = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    private let external = "02D09DD0-D622-4EDA-BA48-8E65D3A37737"
    private var connected: Set<String> { [builtIn, external] }

    private func read(_ text: String, connected: Set<String>? = nil) -> Result<MuroLink, MuroLink.Refusal> {
        MuroLink.read(URL(string: text)!, connectedDisplays: connected ?? self.connected)
    }

    // MARK: Pause and resume

    func testPauseAndResume() {
        XCTAssertEqual(read("muro://pause"), .success(.pause))
        XCTAssertEqual(read("muro://resume"), .success(.resume))
    }

    func testTheActionIsReadWithoutRegardToCase() {
        XCTAssertEqual(read("muro://Pause"), .success(.pause))
        XCTAssertEqual(read("MURO://resume"), .success(.resume))
    }

    // MARK: Set

    func testSetWithOnlyAnIDGoesEverywhereTheMenuBarWouldPutIt() {
        XCTAssertEqual(read("muro://set?id=abc"), .success(.set(id: "abc", display: nil, surface: nil)))
    }

    func testSetOnAConnectedDisplay() {
        XCTAssertEqual(
            read("muro://set?id=abc&display=\(external)"),
            .success(.set(id: "abc", display: external, surface: nil))
        )
    }

    func testADisplayIsMatchedWithoutRegardToCaseAndPassedOnAsTheConfigSpellsIt() {
        XCTAssertEqual(
            read("muro://set?id=abc&display=\(builtIn.lowercased())"),
            .success(.set(id: "abc", display: builtIn, surface: nil))
        )
    }

    func testADisplayThatIsNotConnectedIsRefused() {
        // A screen that was unplugged, or a made-up one, would stop a
        // playlist and leave an entry in the config for nothing.
        let unplugged = "11111111-2222-3333-4444-555555555555"
        XCTAssertEqual(read("muro://set?id=abc&display=\(unplugged)"), .failure(.displayNotConnected(unplugged)))
        XCTAssertEqual(read("muro://set?id=abc&display=\(external)", connected: [builtIn]),
                       .failure(.displayNotConnected(external)))
        XCTAssertEqual(read("muro://set?id=abc&display="), .failure(.displayNotConnected("")))
    }

    func testEverySurface() {
        for surface in MuroLink.Surface.allCases {
            XCTAssertEqual(
                read("muro://set?id=abc&surface=\(surface.rawValue)"),
                .success(.set(id: "abc", display: nil, surface: surface))
            )
        }
        XCTAssertEqual(read("muro://set?id=abc&surface=LockScreen"),
                       .success(.set(id: "abc", display: nil, surface: .lockscreen)))
    }

    func testAnUnknownSurfaceIsRefusedRatherThanGuessed() {
        XCTAssertEqual(read("muro://set?id=abc&surface=ceiling"), .failure(.unknownSurface("ceiling")))
    }

    func testDisplayAndSurfaceTogether() {
        XCTAssertEqual(
            read("muro://set?display=\(builtIn)&surface=desktop&id=abc"),
            .success(.set(id: "abc", display: builtIn, surface: .desktop))
        )
    }

    func testSetWithoutAnIDIsRefused() {
        XCTAssertEqual(read("muro://set"), .failure(.missingID))
        XCTAssertEqual(read("muro://set?id="), .failure(.missingID))
        XCTAssertEqual(read("muro://set?display=\(builtIn)"), .failure(.missingID))
    }

    func testTheFirstOfARepeatedParameterWins() {
        XCTAssertEqual(read("muro://set?id=first&id=second"), .success(.set(id: "first", display: nil, surface: nil)))
    }

    func testAPercentEncodedIDIsDecoded() {
        XCTAssertEqual(read("muro://set?id=apple-picture-a%20b"),
                       .success(.set(id: "apple-picture-a b", display: nil, surface: nil)))
    }

    // MARK: Anything else

    func testAnUnknownActionIsRefused() {
        XCTAssertEqual(read("muro://download?id=abc"), .failure(.unknownAction("download")))
        XCTAssertEqual(read("muro://"), .failure(.unknownAction("")))
    }

    func testALinkForAnotherAppIsRefused() {
        XCTAssertEqual(read("https://pause"), .failure(.notMuro))
    }

    func testALinkThatIsTooLongIsRefusedBeforeItIsRead() {
        let padding = String(repeating: "a", count: MuroLink.longestLink)
        XCTAssertEqual(read("muro://set?id=\(padding)"), .failure(.tooLong))
        XCTAssertEqual(read("muro://pause?x=\(padding)"), .failure(.tooLong))
        // The longest one that is still read.
        let longest = "muro://set?id="
        let id = String(repeating: "a", count: MuroLink.longestLink - longest.utf8.count)
        XCTAssertEqual(read(longest + id), .success(.set(id: id, display: nil, surface: nil)))
    }
}

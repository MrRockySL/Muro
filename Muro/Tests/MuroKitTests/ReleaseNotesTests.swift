import XCTest
@testable import MuroKit

/// The update prompt is built from text the owner will write months from now,
/// in a field with no schema. These tests fix the shapes it has to survive.
final class ReleaseNotesTests: XCTestCase {

    // MARK: - Parsing the body

    func testHeadingsBecomeSections() {
        let notes = ReleaseNotes.parse("""
        ## New
        - Automations
        - Pause after

        ## Fixed
        - Downloads are faster
        """)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].name, "New")
        XCTAssertEqual(notes[0].lines, ["Automations", "Pause after"])
        XCTAssertEqual(notes[1].name, "Fixed")
        XCTAssertEqual(notes[1].lines, ["Downloads are faster"])
    }

    func testNotesWithoutHeadingsStillParse() {
        let notes = ReleaseNotes.parse("- One\n- Two")
        XCTAssertEqual(notes.count, 1)
        XCTAssertNil(notes[0].name)
        XCTAssertEqual(notes[0].lines, ["One", "Two"])
    }

    func testPlainProseIsKept() {
        // Not every release is written as bullets, and dropping the whole body
        // because it lacks dashes would show an empty update.
        let notes = ReleaseNotes.parse("This release fixes the lock screen.")
        XCTAssertEqual(notes.first?.lines, ["This release fixes the lock screen."])
    }

    func testMarkdownDecorationIsStripped() {
        let notes = ReleaseNotes.parse("- **Bold** and `code` and [a link](https://example.com)")
        XCTAssertEqual(notes.first?.lines, ["Bold and code and a link"])
    }

    func testBulletStylesAndNumbering() {
        let notes = ReleaseNotes.parse("* Star\n+ Plus\n1. Numbered")
        XCTAssertEqual(notes.first?.lines, ["Star", "Plus", "Numbered"])
    }

    func testChromeIsSkipped() {
        let notes = ReleaseNotes.parse("""
        - Real note
        ---
        ![screenshot](a.png)
        <img src="b.png">
        **Full Changelog**: https://github.com/x/y/compare/v1...v2
        """)
        XCTAssertEqual(notes.first?.lines, ["Real note"])
    }

    func testEmptyBodyGivesNoSections() {
        XCTAssertTrue(ReleaseNotes.parse("").isEmpty)
        XCTAssertTrue(ReleaseNotes.parse("\n\n   \n").isEmpty)
    }

    func testAVeryLongBodyIsCapped() {
        let body = (1...500).map { "- Note \($0)" }.joined(separator: "\n")
        let total = ReleaseNotes.parse(body).reduce(0) { $0 + $1.lines.count }
        XCTAssertEqual(total, ReleaseNotes.lineLimit)
    }

    // MARK: - Reading the GitHub payload

    private func payload(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = [
            "tag_name": "v4.0",
            "name": "Muro 4.0",
            "html_url": "https://github.com/MrRockySL/Muro/releases/tag/v4.0",
            "published_at": "2026-09-01T10:00:00Z",
            "body": "## New\n- A thing",
            "assets": [
                ["name": "Muro-4.0.dmg",
                 "browser_download_url": "https://github.com/MrRockySL/Muro/releases/download/v4.0/Muro-4.0.dmg"],
            ],
        ]
        for (key, value) in overrides { json[key] = value }
        return json
    }

    func testReadsVersionNotesAndDMG() throws {
        let release = try XCTUnwrap(ReleaseInfo.from(json: payload()))
        XCTAssertEqual(release.version, "4.0")
        XCTAssertNil(release.title)  // "Muro 4.0" is what the heading already says
        XCTAssertEqual(release.downloadURL?.lastPathComponent, "Muro-4.0.dmg")
        XCTAssertEqual(release.notes.first?.name, "New")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertFalse(release.isEmpty)
    }

    /// The download button must not offer someone the source tarball.
    func testIgnoresNonDMGAssets() throws {
        let release = try XCTUnwrap(ReleaseInfo.from(json: payload([
            "assets": [
                ["name": "source.zip", "browser_download_url": "https://example.com/source.zip"],
                ["name": "Muro-4.0.dmg", "browser_download_url": "https://example.com/Muro-4.0.dmg"],
            ],
        ])))
        XCTAssertEqual(release.downloadURL?.lastPathComponent, "Muro-4.0.dmg")
    }

    func testMissingDMGLeavesTheReleasePage() throws {
        let release = try XCTUnwrap(ReleaseInfo.from(json: payload(["assets": [[String: Any]]()])))
        XCTAssertNil(release.downloadURL)
        XCTAssertEqual(release.page.absoluteString.hasSuffix("v4.0"), true)
    }

    /// A name that just repeats the heading would print "Muro 4.0" twice, one
    /// line under the other. Caught by looking at the real v2.0 release in the
    /// running app, where the name is exactly "Muro 2.0".
    func testTitleThatRepeatsTheHeadingIsDropped() throws {
        for name in ["v4.0", "4.0", "Muro 4.0", "muro 4.0", "MURO V4.0", "  "] {
            XCTAssertNil(
                try XCTUnwrap(ReleaseInfo.from(json: payload(["name": name]))).title,
                "\(name) should not be shown under the heading"
            )
        }
    }

    /// A name that says something keeps its place.
    func testARealTitleIsKept() throws {
        let release = try XCTUnwrap(ReleaseInfo.from(json: payload([
            "name": "Lock screen live wallpapers",
        ])))
        XCTAssertEqual(release.title, "Lock screen live wallpapers")
    }

    /// A shape we do not recognise means "nothing to show", never a crash and
    /// never an update prompt with no version in it.
    func testMalformedPayloadsAreRefused() {
        XCTAssertNil(ReleaseInfo.from(json: [:]))
        XCTAssertNil(ReleaseInfo.from(json: ["tag_name": "v4.0"]))
        XCTAssertNil(ReleaseInfo.from(json: payload(["tag_name": "v"])))
        XCTAssertNil(ReleaseInfo.from(json: payload(["html_url": 7])))
    }

    func testAnEmptyBodyIsStillAValidRelease() throws {
        let release = try XCTUnwrap(ReleaseInfo.from(json: payload(["body": ""])))
        XCTAssertTrue(release.isEmpty)
        XCTAssertEqual(release.version, "4.0")
    }

    /// The real v2.0 release, word for word from the GitHub API. Synthetic
    /// bodies only prove the parser handles what I imagined; this proves it
    /// handles what the owner actually writes.
    func testTheRealTwoPointZeroRelease() throws {
        let body = """
        ## Lock screen live wallpapers

        Muro can now play a live wallpaper on your lock screen, not just the desktop.

        Pick any wallpaper, choose **Lockscreen** or **Both**, and it plays behind your \
        lock and login screen.

        ## Updating

        Already have Muro? Download the DMG below and replace your copy in Applications.
        """
        let release = try XCTUnwrap(ReleaseInfo.from(json: [
            "tag_name": "v2.0",
            "name": "Muro 2.0",
            "html_url": "https://github.com/MrRockySL/Muro/releases/tag/v2.0",
            "body": body,
            "assets": [
                ["name": "Muro-2.0.dmg", "browser_download_url": "https://example.com/Muro-2.0.dmg"],
                ["name": "muro-demo.mp4", "browser_download_url": "https://example.com/muro-demo.mp4"],
            ],
        ]))
        XCTAssertEqual(release.version, "2.0")
        // "Muro 2.0" under a heading that already reads "Muro 2.0".
        XCTAssertNil(release.title)
        // The demo video sits next to the DMG in that release; offering it as
        // "the update" would be a download that installs nothing.
        XCTAssertEqual(release.downloadURL?.lastPathComponent, "Muro-2.0.dmg")
        XCTAssertEqual(release.notes.map(\.name), ["Lock screen live wallpapers", "Updating"])
        XCTAssertEqual(release.notes[0].lines.count, 2)
        XCTAssertTrue(release.notes[0].lines[1].contains("Lockscreen or Both"))
    }

    /// The whole point of the feature: 4.0 must read as newer than 3.0.
    func testANewReleaseIsSeenAsNewerThanThisBuild() throws {
        let release = try XCTUnwrap(ReleaseInfo.from(json: payload()))
        XCTAssertTrue(AppVersion.isNewer(release.version, than: "3.0"))
        XCTAssertFalse(AppVersion.isNewer("3.0", than: release.version))
    }
}

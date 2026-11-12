import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MuroKit

/// #58: Muro only on the lock screen, the person's own picture on the desktop.
///
/// macOS has one slot per display for both, so Muro stays in it and shows the
/// picture itself. These cover the three things that has to get right: reading
/// which picture is in a slot, making the copy the extension draws, and
/// teaching the backup the picture so a removal gives it back.
final class OwnDesktopPictureTests: XCTestCase {
    let muro = "com.mrrockysl.muro.wallpaper-extension"
    let macBook = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    let dell = "C4497200-61AC-4C2C-B727-10348E552634"

    let early = Date(timeIntervalSince1970: 1_791_000_000)
    let late = Date(timeIntervalSince1970: 1_792_992_899)

    func muroSurface(_ setAt: Date?) -> [String: Any] {
        var surface: [String: Any] = [
            "Content": [
                "Choices": [["Provider": muro, "Configuration": Data("lock".utf8)]],
                "Shuffle": "$null",
            ]
        ]
        if let setAt { surface["LastSet"] = setAt }
        return surface
    }

    func pictureSurface(_ path: String, _ setAt: Date?, shuffle: Any = "$null") -> [String: Any] {
        var surface: [String: Any] = [
            "Content": [
                "Choices": [MacOSWallpaperChoice.picture(file: URL(fileURLWithPath: path))],
                "Shuffle": shuffle,
            ]
        ]
        if let setAt { surface["LastSet"] = setAt }
        return surface
    }

    func node(_ desktop: [String: Any]) -> [String: Any] {
        ["Type": "individual", "Desktop": desktop, "Idle": muroSurface(early)]
    }

    // MARK: Reading the slot

    func testAPictureSetInSystemSettingsIsRead() {
        let surface = pictureSurface("/Users/someone/Pictures/Beach Day.jpg", late)
        XCTAssertEqual(
            OwnDesktopPicture.occupant(of: surface),
            .picture(URL(fileURLWithPath: "/Users/someone/Pictures/Beach Day.jpg"))
        )
    }

    func testMuroItselfIsNotAPicture() {
        XCTAssertEqual(OwnDesktopPicture.occupant(of: muroSurface(late)), .other)
    }

    func testTheDefaultWallpaperIsToldApart() {
        let surface: [String: Any] = [
            "Content": ["Choices": [MacOSWallpaperChoice.macOSDefault], "Shuffle": "$null"]
        ]
        XCTAssertEqual(OwnDesktopPicture.occupant(of: surface), .macOSDefault)
    }

    func testAnAerialIsNotAPicture() {
        let surface: [String: Any] = [
            "Content": [
                "Choices": [["Provider": "com.apple.wallpaper.choice.aerials", "Configuration": Data()]],
                "Shuffle": "$null",
            ]
        ]
        XCTAssertEqual(OwnDesktopPicture.occupant(of: surface), .other)
    }

    /// A folder macOS moves through by itself cannot be shown as one file.
    func testAShufflingSetIsNotAPicture() {
        XCTAssertEqual(
            OwnDesktopPicture.occupant(of: pictureSurface("/a.jpg", late, shuffle: ["Interval": 300])),
            .other
        )
        var two = pictureSurface("/a.jpg", late)
        var content = two["Content"] as! [String: Any]
        content["Choices"] = [
            MacOSWallpaperChoice.picture(file: URL(fileURLWithPath: "/a.jpg")),
            MacOSWallpaperChoice.picture(file: URL(fileURLWithPath: "/b.jpg")),
        ]
        two["Content"] = content
        XCTAssertEqual(OwnDesktopPicture.occupant(of: two), .other)
    }

    /// The owner's Mac after a picture was set on the MacBook alone: the
    /// MacBook's nodes in the current Space hold it, another Space's node and
    /// the DELL keep Muro.
    func testTheNewestChoiceForTheDisplayIsTheOneRead() {
        let store: [String: Any] = [
            "SystemDefault": node(pictureSurface("/p.jpg", late)),
            "Displays": [macBook: node(pictureSurface("/p.jpg", late))],
            "Spaces": [
                "": ["Displays": [
                    macBook: node(pictureSurface("/p.jpg", late)),
                    dell: node(muroSurface(early)),
                ]],
                "OTHER": ["Displays": [macBook: node(muroSurface(early))]],
            ],
        ]
        XCTAssertEqual(
            OwnDesktopPicture.pick(forDisplay: macBook, in: store),
            OwnDesktopPicture.Pick(file: URL(fileURLWithPath: "/p.jpg"), setAt: late)
        )
        // The DELL has nodes of its own, so the shared node's picture is not its.
        XCTAssertNil(OwnDesktopPicture.pick(forDisplay: dell, in: store))
        XCTAssertEqual(OwnDesktopPicture.occupant(forDisplay: dell, in: store), .other)
    }

    /// A Mac that has never had a wallpaper per screen keeps one in the
    /// shared nodes, and that is every display's.
    func testADisplayWithNoNodeOfItsOwnReadsTheSharedOne() {
        let store: [String: Any] = ["AllSpacesAndDisplays": node(pictureSurface("/p.jpg", late))]
        XCTAssertEqual(
            OwnDesktopPicture.occupant(forDisplay: macBook, in: store),
            .picture(URL(fileURLWithPath: "/p.jpg"))
        )
        XCTAssertNil(OwnDesktopPicture.occupant(forDisplay: macBook, in: nil))
    }

    func testAStillOfMurosOwnIsNotThePersonsPicture() {
        let root = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Muro")
        let still = pictureSurface(root.appendingPathComponent("DesktopStills/abc.jpg").path, late)
        XCTAssertFalse(OwnDesktopPicture.isOwnPicture(still, muroFolders: [root]))
        XCTAssertTrue(OwnDesktopPicture.isOwnPicture(
            pictureSurface("/Users/someone/Pictures/a.jpg", late), muroFolders: [root]
        ))
        XCTAssertFalse(OwnDesktopPicture.isOwnPicture(muroSurface(late), muroFolders: [root]))
        // A folder whose name only starts the same is not inside it.
        XCTAssertTrue(OwnDesktopPicture.isOwnPicture(
            pictureSurface("/Users/someone/Library/Application Support/Muro Photos/a.jpg", late),
            muroFolders: [root]
        ))
    }

    // MARK: The copy

    func testACopyIsNoBiggerThanTheScreenNeeds() {
        // An 8K photo on a 4K screen comes down to 4K.
        XCTAssertEqual(
            OwnDesktopPicture.copyPixelSize(
                image: CGSize(width: 7680, height: 4320), screen: CGSize(width: 3840, height: 2160)
            ),
            3840
        )
        // A 1080p screen is counted as 4K, so a sharper mode later still looks right.
        XCTAssertEqual(
            OwnDesktopPicture.copyPixelSize(
                image: CGSize(width: 7680, height: 4320), screen: CGSize(width: 1920, height: 1080)
            ),
            3840
        )
        // A small picture is never made bigger.
        XCTAssertEqual(
            OwnDesktopPicture.copyPixelSize(
                image: CGSize(width: 1280, height: 720), screen: CGSize(width: 3840, height: 2160)
            ),
            1280
        )
        // An upright photo fills a wide screen by its width, so it is its
        // width that has to reach the screen's, not its longer side.
        XCTAssertEqual(
            OwnDesktopPicture.copyPixelSize(
                image: CGSize(width: 6000, height: 9000), screen: CGSize(width: 3840, height: 2160)
            ),
            5760
        )
    }

    func testACopyIsMadeUprightAndReadable() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A photo stored on its side: 400 by 200 pixels, with a note that the
        // top of the picture is its left edge. Seen upright it is 200 by 400.
        let source = folder.appendingPathComponent("photo.jpg")
        try writePicture(to: source, width: 400, height: 200, orientation: 6)
        XCTAssertTrue(OwnDesktopPicture.isStillPicture(source))

        let copy = folder.appendingPathComponent("copies/one.jpg")
        try OwnDesktopPicture.makeCopy(
            of: source, to: copy, screen: CGSize(width: 3840, height: 2160)
        )
        let made = try XCTUnwrap(CGImageSourceCreateWithURL(copy as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(made, 0, nil))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 400)
        // Nothing is left beside it.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path),
            ["one.jpg"]
        )

        // A second picture over the first replaces it.
        let wide = folder.appendingPathComponent("wide.png")
        try writePicture(to: wide, width: 300, height: 100, orientation: 1, type: .png)
        try OwnDesktopPicture.makeCopy(of: wide, to: copy, screen: CGSize(width: 3840, height: 2160))
        let again = try XCTUnwrap(CGImageSourceCreateWithURL(copy as CFURL, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(again, 0, nil)?.width, 300)
    }

    func testWhatIsNotOneStillPictureIsTurnedAway() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let missing = folder.appendingPathComponent("gone.jpg")
        XCTAssertFalse(OwnDesktopPicture.isStillPicture(missing))

        let text = folder.appendingPathComponent("notes.jpg")
        try Data("not a picture".utf8).write(to: text)
        XCTAssertFalse(OwnDesktopPicture.isStillPicture(text))

        // Two pictures in one file, the way a light and dark wallpaper is kept.
        let pair = folder.appendingPathComponent("pair.heic")
        try writePicture(to: pair, width: 64, height: 64, orientation: 1, type: .heic, count: 2)
        XCTAssertFalse(OwnDesktopPicture.isStillPicture(pair))
        XCTAssertThrowsError(try OwnDesktopPicture.makeCopy(
            of: pair, to: folder.appendingPathComponent("copy.jpg"),
            screen: CGSize(width: 1920, height: 1080)
        ))
    }

    private func writePicture(
        to url: URL, width: Int, height: Int, orientation: Int,
        type: UTType = .jpeg, count: Int = 1
    ) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, count, nil
        ))
        for _ in 0..<count {
            CGImageDestinationAddImage(
                writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary
            )
        }
        XCTAssertTrue(CGImageDestinationFinalize(writer))
    }

    // MARK: Teaching the backup

    /// The backup was taken with one picture in the MacBook's slot. The
    /// person set another since, and Muro's lock screen is about to go back
    /// over it. The backup has to end up with the new one.
    func testTheBackupLearnsThePictureAboutToBeCovered() {
        let store: [String: Any] = [
            "Displays": [
                macBook: node(pictureSurface("/new.jpg", late)),
                dell: node(pictureSurface("/dell-new.jpg", late)),
            ],
            "Spaces": ["": ["Displays": [macBook: node(pictureSurface("/new.jpg", late))]]],
        ]
        var backup: Any = [
            "Displays": [
                macBook: node(pictureSurface("/old.jpg", early)),
                dell: node(pictureSurface("/dell-old.jpg", early)),
            ],
        ]
        let learned = AppleWallpaperStore.rememberSurfaces(
            of: store, in: &backup, targetKey: macBook
        ) { OwnDesktopPicture.isOwnPicture($0, muroFolders: []) }
        XCTAssertEqual(learned, 2)

        XCTAssertEqual(
            OwnDesktopPicture.occupant(forDisplay: macBook, in: backup),
            .picture(URL(fileURLWithPath: "/new.jpg"))
        )
        // A Space the backup had never seen is there now too.
        let spaces = (backup as? [String: Any])?["Spaces"] as? [String: Any]
        let space = (spaces?[""] as? [String: Any])?["Displays"] as? [String: Any]
        XCTAssertNotNil((space?[macBook] as? [String: Any])?["Desktop"])
        // The other display was not the target, and keeps what it had.
        XCTAssertEqual(
            OwnDesktopPicture.occupant(forDisplay: dell, in: backup),
            .picture(URL(fileURLWithPath: "/dell-old.jpg"))
        )
        // The screen saver in the same node is not this role's to change.
        let displays = (backup as? [String: Any])?["Displays"] as? [String: Any]
        XCTAssertNotNil((displays?[macBook] as? [String: Any])?["Idle"])
    }

    /// Muro's own record in the slot teaches the backup nothing, and neither
    /// does a wallpaper macOS put there by itself.
    func testOnlyAPictureIsLearnt() {
        let store: [String: Any] = [
            "Displays": [macBook: node(muroSurface(late))],
            "Spaces": ["": ["Displays": [macBook: [
                "Type": "individual",
                "Desktop": ["Content": ["Choices": [MacOSWallpaperChoice.macOSDefault], "Shuffle": "$null"]],
                "Idle": muroSurface(early),
            ] as [String: Any]]]],
        ]
        var backup: Any = ["Displays": [macBook: node(pictureSurface("/old.jpg", early))]]
        let learned = AppleWallpaperStore.rememberSurfaces(
            of: store, in: &backup, targetKey: macBook
        ) { OwnDesktopPicture.isOwnPicture($0, muroFolders: []) }
        XCTAssertEqual(learned, 0)
        XCTAssertEqual(
            OwnDesktopPicture.occupant(forDisplay: macBook, in: backup),
            .picture(URL(fileURLWithPath: "/old.jpg"))
        )
    }

    /// A Mac with only the shared nodes: the write for one display lands in
    /// them, so they are what the backup learns.
    func testAStoreWithOnlySharedNodesTeachesThose() {
        let store: [String: Any] = ["AllSpacesAndDisplays": node(pictureSurface("/new.jpg", late))]
        var backup: Any = ["AllSpacesAndDisplays": node(pictureSurface("/old.jpg", early))]
        let learned = AppleWallpaperStore.rememberSurfaces(
            of: store, in: &backup, targetKey: macBook
        ) { OwnDesktopPicture.isOwnPicture($0, muroFolders: []) }
        XCTAssertEqual(learned, 1)
        XCTAssertEqual(
            OwnDesktopPicture.occupant(forDisplay: macBook, in: backup),
            .picture(URL(fileURLWithPath: "/new.jpg"))
        )
    }
}

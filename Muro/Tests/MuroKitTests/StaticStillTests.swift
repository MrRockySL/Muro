import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MuroKit

/// The picture sizes a static wallpaper is decoded at, and the still video
/// its lock screen and screen saver play.
final class StaticStillTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-still-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A picture of `width` by `height` in two colours, so a wrong crop or a
    /// flipped picture would show.
    private func makePicture(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(context.makeImage())
        let url = folder.appendingPathComponent("picture.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testFillPixels() {
        // A 4K picture on a 2560 by 1664 screen: the height decides.
        XCTAssertEqual(
            StaticStill.fillPixels(picture: CGSize(width: 3840, height: 2160), screen: CGSize(width: 2560, height: 1664)),
            2959
        )
        // On a 1080p screen the width and height fit alike.
        XCTAssertEqual(
            StaticStill.fillPixels(picture: CGSize(width: 3840, height: 2160), screen: CGSize(width: 1920, height: 1080)),
            1920
        )
        // Never bigger than the picture is.
        XCTAssertEqual(
            StaticStill.fillPixels(picture: CGSize(width: 1280, height: 720), screen: CGSize(width: 3840, height: 2160)),
            1280
        )
    }

    func testImageAndJPEG() throws {
        let picture = try makePicture(width: 801, height: 451)
        XCTAssertEqual(StaticStill.pixelSize(of: picture), CGSize(width: 801, height: 451))
        let small = try XCTUnwrap(StaticStill.image(at: picture, maxPixels: 400))
        XCTAssertEqual(max(small.width, small.height), 400)
        let jpeg = folder.appendingPathComponent("still.jpg")
        try StaticStill.writeJPEG(from: picture, to: jpeg, maxPixels: 3840)
        XCTAssertEqual(StaticStill.pixelSize(of: jpeg), CGSize(width: 801, height: 451))
    }

    /// The still video: HEVC, even sizes, the picture held for the whole of
    /// it, and nothing half written left behind.
    func testMakeVideo() async throws {
        let picture = try makePicture(width: 801, height: 451)
        let video = folder.appendingPathComponent("still.mov")
        try await StaticStill.makeVideo(from: picture, to: video)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))

        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 800, height: 450))
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_HEVC)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, Double(StaticStill.videoSeconds), accuracy: 0.01)

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(Set(left), ["picture.png", "still.mov"])

        // Made again over itself, it is replaced, not doubled.
        try await StaticStill.makeVideo(from: picture, to: video)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["picture.png", "still.mov"])
    }
}

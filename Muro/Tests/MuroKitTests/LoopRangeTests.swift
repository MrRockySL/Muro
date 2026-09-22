import XCTest
import AVFoundation
@testable import MuroKit

/// Issue #39. A file that opens with an empty edit loops from its first real
/// frame; every other file loops exactly as it did.
final class LoopRangeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The rule

    func testAFileWithoutAGapLoopsWhole() {
        XCTAssertNil(LoopRange.range(firstFrameAt: .zero, duration: CMTime(value: 24117, timescale: 1000)))
    }

    func testAGapIsSkippedAndTheEndKept() {
        // Camper Van on the Hill: 33 ms of nothing, 24.117 s in all.
        let start = CMTime(value: 1, timescale: 30)
        let duration = CMTime(value: 24117, timescale: 1000)
        let range = LoopRange.range(firstFrameAt: start, duration: duration)
        XCTAssertEqual(range?.start, start)
        XCTAssertEqual(range?.end, duration)
    }

    func testTimesThatMakeNoSenseLoopWhole() {
        let ten = CMTime(value: 10, timescale: 1)
        XCTAssertNil(LoopRange.range(firstFrameAt: .invalid, duration: ten))
        XCTAssertNil(LoopRange.range(firstFrameAt: CMTime(value: 1, timescale: 30), duration: .indefinite))
        XCTAssertNil(LoopRange.range(firstFrameAt: ten, duration: ten))
    }

    // MARK: - Real files

    func testAMovieThatOpensWithAGapLoopsFromItsFirstFrame() throws {
        let url = try makeMovie(firstFrameAt: CMTime(value: 1, timescale: 30))
        let range = try XCTUnwrap(LoopRange.trimmed(AVURLAsset(url: url)))
        XCTAssertEqual(range.start.seconds, 1.0 / 30, accuracy: 0.0001)
        XCTAssertEqual(range.end.seconds, 7.0 / 30, accuracy: 0.0001)
    }

    func testAMovieWithoutAGapIsLeftAlone() throws {
        let url = try makeMovie(firstFrameAt: .zero)
        XCTAssertNil(LoopRange.trimmed(AVURLAsset(url: url)))
    }

    func testAStreamIsNeverWaitedOn() {
        let url = URL(string: "https://cdn.murowallpaper.com/p720/example.mov")!
        XCTAssertNil(LoopRange.trimmed(AVURLAsset(url: url)))
    }

    func testAMissingFileLoopsAsBefore() {
        XCTAssertNil(LoopRange.trimmed(AVURLAsset(url: root.appendingPathComponent("missing.mov"))))
    }

    /// Six frames at 30 fps, written the way the gap gets made: the session
    /// starts at zero and the first frame arrives later, so the writer puts an
    /// empty edit in front of it.
    private func makeMovie(firstFrameAt first: CMTime) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 128,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<6 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let time = first + CMTime(value: CMTimeValue(frame), timescale: 30)
            XCTAssertTrue(adaptor.append(try XCTUnwrap(buffer), withPresentationTime: time))
        }
        input.markAsFinished()
        let finished = expectation(description: "movie written")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}

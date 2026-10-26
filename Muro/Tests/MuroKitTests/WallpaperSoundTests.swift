import XCTest
import AVFoundation
@testable import MuroKit

/// Issue #54: a video the person adds keeps its sound, and only one live
/// wallpaper is heard at a time. The displays are the owner's: a MacBook and
/// a DELL.
final class WallpaperSoundTests: XCTestCase {
    let macBook = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    let dell = "C4497200-61AC-4C2C-B727-10348E552634"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - One sound at a time

    func testSwitchedOffNothingIsHeard() {
        XCTAssertNil(WallpaperSound.display(
            enabled: false, preferred: macBook, displays: [macBook, dell], hasSound: { _ in true }
        ))
    }

    func testTheDisplayAppliedLastIsHeard() {
        XCTAssertEqual(WallpaperSound.display(
            enabled: true, preferred: dell, displays: [macBook, dell], hasSound: { _ in true }
        ), dell)
    }

    /// The DELL's sound was replaced by a silent live wallpaper: the MacBook's
    /// still has sound, so that is what plays now.
    func testWhenTheLastOneIsSilentTheOtherIsHeard() {
        XCTAssertEqual(WallpaperSound.display(
            enabled: true, preferred: dell, displays: [macBook, dell], hasSound: { $0 == self.macBook }
        ), macBook)
    }

    /// Nothing applied with sound yet, or the display it was applied to is
    /// unplugged: the main display comes first.
    func testWithoutALastOneTheMainDisplayComesFirst() {
        XCTAssertEqual(WallpaperSound.display(
            enabled: true, preferred: nil, displays: [macBook, dell], hasSound: { _ in true }
        ), macBook)
        XCTAssertEqual(WallpaperSound.display(
            enabled: true, preferred: "unplugged", displays: [macBook, dell], hasSound: { _ in true }
        ), macBook)
    }

    func testNoSoundAnywhereIsSilence() {
        XCTAssertNil(WallpaperSound.display(
            enabled: true, preferred: macBook, displays: [macBook, dell], hasSound: { _ in false }
        ))
    }

    // MARK: - Keeping the sound

    func testAnOwnVideoKeepsItsSound() throws {
        let source = try makeMovie(frames: 30, soundSeconds: 1.5)
        let out = root.appendingPathComponent("kept.mov")
        let result = try transcodeToHEVC(source: source, destination: out, keepAudio: true)
        XCTAssertTrue(result.hasSound)
        let asset = AVURLAsset(url: out)
        let audio = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let video = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let format = try XCTUnwrap(audio.formatDescriptions.first.map { $0 as! CMAudioFormatDescription })
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kAudioFormatMPEG4AAC)
        // The source's sound runs half a second past its picture; the copy's
        // stops with the picture, give or take AAC's padding.
        XCTAssertLessThanOrEqual(audio.timeRange.end.seconds, video.timeRange.end.seconds + 0.05)
        XCTAssertEqual(video.timeRange.duration.seconds, 1.0, accuracy: 0.05)
    }

    func testEveryOtherImportStaysSilent() throws {
        let source = try makeMovie(frames: 30, soundSeconds: 1)
        let out = root.appendingPathComponent("silent.mov")
        let result = try transcodeToHEVC(source: source, destination: out)
        XCTAssertFalse(result.hasSound)
        XCTAssertTrue(AVURLAsset(url: out).tracks(withMediaType: .audio).isEmpty)
    }

    func testAVideoWithoutSoundComesInWithout() throws {
        let source = try makeMovie(frames: 30, soundSeconds: nil)
        let out = root.appendingPathComponent("none.mov")
        let result = try transcodeToHEVC(source: source, destination: out, keepAudio: true)
        XCTAssertFalse(result.hasSound)
        XCTAssertTrue(AVURLAsset(url: out).tracks(withMediaType: .audio).isEmpty)
        XCTAssertEqual(
            AVURLAsset(url: out).tracks(withMediaType: .video).first?.timeRange.duration.seconds ?? 0,
            1.0, accuracy: 0.05
        )
    }

    func testTheEfficientCopyKeepsTheSound() throws {
        let source = try makeMovie(frames: 30, soundSeconds: 1)
        let out = root.appendingPathComponent("eff.mov")
        let result = try transcodeToHEVC(
            source: source, destination: out, halveFrameRate: true, keepAudio: true
        )
        XCTAssertTrue(result.hasSound)
        XCTAssertEqual(result.fps, 15, accuracy: 0.5)
        XCTAssertFalse(AVURLAsset(url: out).tracks(withMediaType: .audio).isEmpty)
    }

    /// A video with sound loops its picture and nothing past it; a silent one
    /// loops the way it always did.
    func testASoundFileLoopsItsPictureOnly() throws {
        let source = try makeMovie(frames: 30, soundSeconds: 1.5)
        let out = root.appendingPathComponent("loop.mov")
        _ = try transcodeToHEVC(source: source, destination: out, keepAudio: true)
        let range = try XCTUnwrap(LoopRange.withSound(AVURLAsset(url: out)))
        XCTAssertEqual(range.start.seconds, 0, accuracy: 0.001)
        XCTAssertEqual(range.end.seconds, 1.0, accuracy: 0.05)

        let silent = root.appendingPathComponent("loop-silent.mov")
        _ = try transcodeToHEVC(source: source, destination: silent)
        XCTAssertNil(LoopRange.withSound(AVURLAsset(url: silent)))
    }

    // MARK: - Playing it

    /// Not heard, a video with sound plays a copy holding its picture alone.
    /// A muted player still runs the Mac's audio output, so muting is not
    /// enough.
    func testUnheardItPlaysItsPictureAlone() throws {
        let source = try makeMovie(frames: 30, soundSeconds: 1)
        let out = root.appendingPathComponent("p.mov")
        _ = try transcodeToHEVC(source: source, destination: out, keepAudio: true)

        let quiet = LoopRange.make(player: AVQueuePlayer(), url: out, sound: false)
        XCTAssertTrue(quiet.hasSound)
        XCTAssertEqual(quiet.pictureStart, .zero)
        let quietItem = try XCTUnwrap(quiet.looper.loopingPlayerItems.first)
        XCTAssertTrue(quietItem.asset.tracks(withMediaType: .audio).isEmpty)
        XCTAssertFalse(quietItem.asset.tracks(withMediaType: .video).isEmpty)
        XCTAssertEqual(quietItem.asset.duration.seconds, 1.0, accuracy: 0.05)

        // A looper given a time range makes its items a moment later.
        let heard = LoopRange.make(player: AVQueuePlayer(), url: out, sound: true)
        let deadline = Date().addingTimeInterval(3)
        while heard.looper.loopingPlayerItems.isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let heardItem = try XCTUnwrap(heard.looper.loopingPlayerItems.first)
        XCTAssertFalse(heardItem.asset.tracks(withMediaType: .audio).isEmpty)
    }

    /// A silent file is built the way every live wallpaper always was.
    func testASilentFileIsBuiltAsBefore() throws {
        let source = try makeMovie(frames: 30, soundSeconds: nil)
        let built = LoopRange.make(player: AVQueuePlayer(), url: source, sound: true)
        XCTAssertFalse(built.hasSound)
        XCTAssertEqual(built.pictureStart, .zero)
        let item = try XCTUnwrap(built.looper.loopingPlayerItems.first)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url, source)
    }

    // MARK: - A movie with sound

    /// `frames` of 128 by 128 H.264 at 30 fps, and `soundSeconds` of a quiet
    /// 440 Hz tone as AAC, written in time order so the writer never waits on
    /// one track for the other.
    private func makeMovie(frames: Int, soundSeconds: Double?) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 128,
        ])
        writer.add(video)

        let rate = 48_000
        var audio: AVAssetWriterInput?
        var format: CMAudioFormatDescription?
        if soundSeconds != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
            )
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
            )
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let chunk = rate / 10
        let chunks = Int(((soundSeconds ?? 0) * 10).rounded())
        var nextFrame = 0
        var nextChunk = 0
        while nextFrame < frames || nextChunk < chunks {
            let frameTime = Double(nextFrame) / 30
            let chunkTime = Double(nextChunk) / 10
            if nextFrame < frames && (nextChunk >= chunks || frameTime <= chunkTime) {
                while !video.isReadyForMoreMediaData { usleep(1000) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
                XCTAssertTrue(adaptor.append(
                    try XCTUnwrap(buffer), withPresentationTime: CMTime(value: CMTimeValue(nextFrame), timescale: 30)
                ))
                nextFrame += 1
            } else if let audio, let format {
                while !audio.isReadyForMoreMediaData { usleep(1000) }
                var samples = [Int16](repeating: 0, count: chunk * 2)
                for i in 0..<chunk {
                    let t = Double(nextChunk * chunk + i) / Double(rate)
                    let value = Int16(sin(2 * .pi * 440 * t) * 3000)
                    samples[2 * i] = value
                    samples[2 * i + 1] = value
                }
                let bytes = samples.count * 2
                var block: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                    customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                    flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
                )
                let data = try XCTUnwrap(block)
                _ = samples.withUnsafeBytes {
                    CMBlockBufferReplaceDataBytes(
                        with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes
                    )
                }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: data, formatDescription: format, sampleCount: chunk,
                    presentationTimeStamp: CMTime(value: CMTimeValue(nextChunk * chunk), timescale: CMTimeScale(rate)),
                    packetDescriptions: nil, sampleBufferOut: &sample
                )
                XCTAssertTrue(audio.append(try XCTUnwrap(sample)))
                nextChunk += 1
            }
        }
        video.markAsFinished()
        audio?.markAsFinished()
        let finished = expectation(description: "movie written")
        writer.finishWriting { finished.fulfill() }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(writer.status, .completed)
        return url
    }
}

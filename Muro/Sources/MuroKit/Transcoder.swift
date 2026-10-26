import AVFoundation
import VideoToolbox
import Foundation

public struct TranscodeResult {
    public let width: Int
    public let height: Int
    public let fps: Double
    public let duration: Double
    /// Whether the file written carries the source's sound (issue #54).
    public var hasSound = false
}

public enum TranscodeError: Error, CustomStringConvertible {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)

    public var description: String {
        switch self {
        case .noVideoTrack: return "source has no video track"
        case .readerFailed(let why): return "reader failed: \(why)"
        case .writerFailed(let why): return "writer failed: \(why)"
        }
    }
}

/// Re-encodes a video to HEVC (.mov), video track only (audio is dropped).
/// Frame rate is preserved unless `halveFrameRate` is set, which drops every
/// second frame — the cheap, exact way to turn 60 fps into 30 fps for the
/// "Efficient" playback mode. Decoding and encoding are both hardware
/// (Media Engine) on Apple Silicon.
///
/// `keepAudio` keeps the source's sound as well, as AAC (issue #54). Only a
/// video the person adds themselves asks for it; every live wallpaper Muro
/// publishes stays silent. The sound is the extra here and never the reason a
/// video fails to come in: if writing it fails, the video is written again
/// without it.
///
/// `progress`, when given, is told how far through the video the encode is,
/// 0 to 1, in steps of about a hundredth, on the encoding queue.
public func transcodeToHEVC(
    source: URL,
    destination: URL,
    halveFrameRate: Bool = false,
    keepAudio: Bool = false,
    progress: ((Double) -> Void)? = nil
) throws -> TranscodeResult {
    if keepAudio, let result = try? writeHEVC(
        source: source, destination: destination, halveFrameRate: halveFrameRate,
        keepAudio: true, progress: progress
    ) {
        return result
    }
    return try writeHEVC(
        source: source, destination: destination, halveFrameRate: halveFrameRate,
        keepAudio: false, progress: progress
    )
}

private func writeHEVC(
    source: URL,
    destination: URL,
    halveFrameRate: Bool,
    keepAudio: Bool,
    progress: ((Double) -> Void)?
) throws -> TranscodeResult {
    let asset = AVURLAsset(url: source)

    // Load the video track (async API bridged for CLI use).
    var loadedTrack: AVAssetTrack?
    var loadError: Error?
    let loadDone = DispatchSemaphore(value: 0)
    asset.loadTracks(withMediaType: .video) { tracks, error in
        loadedTrack = tracks?.first
        loadError = error
        loadDone.signal()
    }
    loadDone.wait()
    if let error = loadError { throw TranscodeError.readerFailed("\(error)") }
    guard let track = loadedTrack else { throw TranscodeError.noVideoTrack }

    // The sound, when it is wanted and the video has any.
    var audioTrack: AVAssetTrack?
    if keepAudio {
        let audioLoaded = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .audio) { tracks, _ in
            audioTrack = tracks?.first
            audioLoaded.signal()
        }
        audioLoaded.wait()
    }

    let transformedSize = track.naturalSize.applying(track.preferredTransform)
    let width = Int(abs(transformedSize.width).rounded())
    let height = Int(abs(transformedSize.height).rounded())
    let sourceFPS = Double(track.nominalFrameRate)
    let outputFPS = halveFrameRate ? sourceFPS / 2 : sourceFPS
    let duration = CMTimeGetSeconds(track.timeRange.duration)

    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
    )
    readerOutput.alwaysCopiesSampleData = false
    reader.add(readerOutput)

    try? FileManager.default.removeItem(at: destination)
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    // Put the moov atom at the FRONT of the file. A player needs that index
    // before it can decode anything, so without this a streamed wallpaper has
    // to pull the whole file before the first frame appears.
    writer.shouldOptimizeForNetworkUse = true
    let compression: [String: Any] = [
        AVVideoAverageBitRateKey: recommendedBitrate(width: width, height: height, fps: outputFPS),
        AVVideoExpectedSourceFrameRateKey: Int(outputFPS.rounded()),
        AVVideoMaxKeyFrameIntervalKey: max(1, Int(outputFPS.rounded()) * 2),
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
    ]
    let writerInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
    )
    writerInput.expectsMediaDataInRealTime = false
    writerInput.transform = track.preferredTransform
    writer.add(writerInput)

    // Decoded to stereo PCM and written as AAC, whatever the source used, so
    // every video that plays on a Mac comes in with sound a Mac can play.
    // Both halves are added or neither: an output nobody reads would hold the
    // reader up.
    var audioOutput: AVAssetReaderTrackOutput?
    var audioInput: AVAssetWriterInput?
    if let audioTrack {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let stereo = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: stereo,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: stereo,
            AVEncoderBitRateKey: 192_000,
        ])
        input.expectsMediaDataInRealTime = false
        if reader.canAdd(output), writer.canAdd(input) {
            reader.add(output)
            writer.add(input)
            audioOutput = output
            audioInput = input
            // No sound past the last frame. A longer sound would make the
            // file longer than its picture, and the loop would hold the last
            // frame until the sound ran out.
            reader.timeRange = track.timeRange
        }
    }

    guard reader.startReading() else {
        throw TranscodeError.readerFailed(reader.error.map { "\($0)" } ?? "unknown")
    }
    guard writer.startWriting() else {
        throw TranscodeError.writerFailed(writer.error.map { "\($0)" } ?? "unknown")
    }

    let queue = DispatchQueue(label: "muro.transcode")
    let copyDone = DispatchSemaphore(value: 0)
    var frameIndex = 0
    var sessionStarted = false
    var firstTime: CMTime?
    var reported = 0.0

    // With sound, the session starts before either track is fed. A writer
    // turns away any sample that comes before its session, and the sound can
    // be ready first; the first frame's time is still where it starts.
    var firstFrame: CMSampleBuffer?
    if audioInput != nil {
        guard let first = readerOutput.copyNextSampleBuffer() else {
            throw TranscodeError.readerFailed(reader.error.map { "\($0)" } ?? "no frames")
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(first))
        sessionStarted = true
        firstFrame = first
    }

    writerInput.requestMediaDataWhenReady(on: queue) {
        while writerInput.isReadyForMoreMediaData {
            let next = firstFrame ?? readerOutput.copyNextSampleBuffer()
            firstFrame = nil
            guard let sample = next else {
                writerInput.markAsFinished()
                copyDone.signal()
                return
            }
            if halveFrameRate {
                let keep = frameIndex % 2 == 0
                frameIndex += 1
                if !keep { continue }
            }
            if !sessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
                sessionStarted = true
            }
            if let progress, duration > 0 {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if firstTime == nil { firstTime = time }
                if let start = firstTime {
                    let done = min(max(CMTimeGetSeconds(CMTimeSubtract(time, start)) / duration, 0), 1)
                    if done - reported >= 0.01 {
                        reported = done
                        progress(done)
                    }
                }
            }
            if !writerInput.append(sample) {
                reader.cancelReading()
                writerInput.markAsFinished()
                copyDone.signal()
                return
            }
        }
    }

    let audioDone = DispatchSemaphore(value: 0)
    if let audioInput, let audioOutput {
        audioInput.requestMediaDataWhenReady(on: queue) {
            while audioInput.isReadyForMoreMediaData {
                guard let sample = audioOutput.copyNextSampleBuffer(),
                      audioInput.append(sample)
                else {
                    audioInput.markAsFinished()
                    audioDone.signal()
                    return
                }
            }
        }
    } else {
        audioDone.signal()
    }
    copyDone.wait()
    audioDone.wait()

    if reader.status == .failed {
        throw TranscodeError.readerFailed(reader.error.map { "\($0)" } ?? "unknown")
    }

    let finishDone = DispatchSemaphore(value: 0)
    writer.finishWriting { finishDone.signal() }
    finishDone.wait()
    guard writer.status == .completed else {
        throw TranscodeError.writerFailed(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")
    }
    removeSafeSaveLeftovers(for: destination)

    return TranscodeResult(
        width: width, height: height, fps: outputFPS, duration: duration,
        hasSound: audioInput != nil
    )
}

/// With `shouldOptimizeForNetworkUse`, AVAssetWriter produces the faststart
/// file via a safe-save sibling (`<name>.sb-…`) that macOS 27 sometimes fails
/// to delete — one stray temp per encode, silently doubling disk use. Sweep
/// them after every successful write.
func removeSafeSaveLeftovers(for destination: URL) {
    let dir = destination.deletingLastPathComponent()
    let prefix = destination.lastPathComponent + ".sb-"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
    for name in names where name.hasPrefix(prefix) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

/// Bitrate heuristic for HEVC wallpaper loops: ~0.045 bits/pixel/frame,
/// clamped to a sane range. 4K@30 ≈ 11 Mbps, 4K@60 ≈ 22 Mbps, 1080p@30 ≈ 3 Mbps.
func recommendedBitrate(width: Int, height: Int, fps: Double) -> Int {
    let bitsPerSecond = Double(width * height) * fps * 0.045
    return max(3_000_000, min(Int(bitsPerSecond), 25_000_000))
}

/// Brings a video into the library **without re-encoding a single frame**.
///
/// `transcodeToHEVC` decodes every frame and encodes it again at a bitrate
/// `recommendedBitrate` chooses. That is a second generation of lossy
/// compression on top of whatever the source already went through, and it is
/// where quality was being lost: a 40 Mbps 4K master came out the far side at
/// the 25 Mbps ceiling, and even a clip well under the ceiling still paid for
/// one more encode.
///
/// This copies the compressed samples across instead, so the picture that
/// lands in the library is the picture that was handed in, to the bit. What
/// still happens is everything around the video: the audio is dropped (a
/// wallpaper is silent), the container becomes `.mov` like every other master,
/// and `moov` goes to the front so the file streams.
///
/// It goes through a composition holding only the video track, exported with
/// the passthrough preset. Copying the samples by hand with a reader and a
/// writer looks simpler and is not: the reader hands back the first sample of
/// a file with an edit list carrying **no** presentation timestamp, which
/// crashes `startSession` outright, and writing it at the session start
/// instead puts a junk frame at time zero that renders black. Both showed up
/// on real clips. A composition makes AVFoundation own that timing, which it
/// gets right.
///
/// The cost is size. An H.264 source stays H.264 sized rather than shrinking
/// into HEVC, which is the trade the owner asked for: original quality first,
/// a smaller file only if it costs nothing to look at.
@discardableResult
public func copyVideoStream(source: URL, destination: URL) throws -> TranscodeResult {
    let asset = AVURLAsset(url: source)

    var loadedTrack: AVAssetTrack?
    var loadError: Error?
    let loadDone = DispatchSemaphore(value: 0)
    asset.loadTracks(withMediaType: .video) { tracks, error in
        loadedTrack = tracks?.first
        loadError = error
        loadDone.signal()
    }
    loadDone.wait()
    if let error = loadError { throw TranscodeError.readerFailed("\(error)") }
    guard let track = loadedTrack else { throw TranscodeError.noVideoTrack }

    let transformedSize = track.naturalSize.applying(track.preferredTransform)
    let width = Int(abs(transformedSize.width).rounded())
    let height = Int(abs(transformedSize.height).rounded())
    let fps = Double(track.nominalFrameRate)
    let duration = CMTimeGetSeconds(track.timeRange.duration)

    // Video only. This is also how the audio is stripped: the audio track is
    // simply never inserted, so nothing has to be filtered out later.
    let composition = AVMutableComposition()
    guard let videoTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
        throw TranscodeError.writerFailed("could not add a video track")
    }
    do {
        try videoTrack.insertTimeRange(track.timeRange, of: track, at: .zero)
    } catch {
        throw TranscodeError.readerFailed("\(error)")
    }
    videoTrack.preferredTransform = track.preferredTransform

    guard let export = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetPassthrough
    ) else {
        throw TranscodeError.writerFailed("no passthrough export session")
    }
    try? FileManager.default.removeItem(at: destination)
    export.outputURL = destination
    export.outputFileType = .mov
    // The moov atom belongs at the front, or a player has to pull the whole
    // file before it can show anything.
    export.shouldOptimizeForNetworkUse = true

    let exportDone = DispatchSemaphore(value: 0)
    export.exportAsynchronously { exportDone.signal() }
    exportDone.wait()

    guard export.status == .completed else {
        throw TranscodeError.writerFailed(
            export.error.map { "\($0)" } ?? "status \(export.status.rawValue)"
        )
    }
    removeSafeSaveLeftovers(for: destination)

    return TranscodeResult(width: width, height: height, fps: fps, duration: duration)
}

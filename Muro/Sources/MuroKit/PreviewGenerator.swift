import AVFoundation
import VideoToolbox
import Foundation

/// The streaming preview tier. Previews exist so a wallpaper can be *seen*
/// moving before anyone commits to pulling a 14–66 MB master: the detail
/// view plays `p720`. There is deliberately no larger tier — the Home hero
/// only ever plays local files (the bundled wallpaper or a downloaded
/// master), so a `p1080` tier was designed and then cut (owner, 2026-07-19).
public struct PreviewSpec: Sendable {
    public let name: String
    public let height: Int
    public let maxSeconds: Double
    public let bitrate: Int

    /// Detail view. Deliberately soft — it shows the motion while leaving a
    /// reason to download the real thing.
    public static let p720 = PreviewSpec(
        name: "p720", height: 720, maxSeconds: 6, bitrate: 1_500_000
    )
}

public struct PreviewResult {
    public let width: Int
    public let height: Int
    public let duration: Double
    public let sizeBytes: Int64
}

/// Renders a short, downscaled, stream-ready HEVC loop from a master.
///
/// Scaling goes through an `AVMutableVideoComposition` rather than by handing
/// mismatched buffers to the writer — the composition is what actually resizes
/// frames. Output is capped at 30 fps: a preview gains nothing from 60 and it
/// would double the bitrate needed to look clean.
///
/// A master smaller than the target height is passed through at its own size
/// rather than upscaled, so a 1080p source never becomes a fake 1080p preview
/// that costs more bytes for no extra detail.
@discardableResult
public func generatePreview(
    source: URL,
    destination: URL,
    spec: PreviewSpec
) throws -> PreviewResult {
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

    let transformed = track.naturalSize.applying(track.preferredTransform)
    let sourceW = abs(transformed.width)
    let sourceH = abs(transformed.height)
    guard sourceW > 0, sourceH > 0 else { throw TranscodeError.noVideoTrack }

    // Never upscale; keep the source aspect and land on even dimensions,
    // which the HEVC encoder requires.
    let scale = min(1.0, CGFloat(spec.height) / sourceH)
    let targetH = evenSide(sourceH * scale)
    let targetW = evenSide(sourceW * scale)

    let sourceFPS = Double(track.nominalFrameRate)
    let outputFPS = sourceFPS > 0 ? min(sourceFPS, 30) : 30

    let fullDuration = CMTimeGetSeconds(track.timeRange.duration)

    // Start a fixed quarter second in, not at zero.
    //
    // Some clips present their first picture late. The composition has nothing
    // to draw in that gap, so it renders it, and the preview opened on a flash
    // of black before the picture appeared. Nothing in AVFoundation will admit
    // to the offset: `timeRange.start` reads zero, and the first sample's
    // stamp reads zero too, because the edit list has already been applied.
    //
    // Counting source frames was tried twice and is the wrong shape. One frame
    // left 13 of 42 clips in a drop still opening on black. Two frames fixed
    // 11 of those, and the two survivors showed why: the real offset is a
    // property of the file, not of the frame rate. `ffprobe` reads their
    // `start_time` as 0.066733 and 0.100100, two and three frames at 29.97,
    // and a two frame start lands exactly on the first one's boundary.
    //
    // So do not try to match it. Clear it. A quarter second is longer than any
    // offset seen, and it is still invisible in a six second loop cut from a
    // clip many times that long.
    let headTrim = 0.25
    let clipStart = CMTime(seconds: min(headTrim, fullDuration / 4),
                           preferredTimescale: 600)

    // Take the window from there, never past the end of the track.
    let clipSeconds = min(spec.maxSeconds,
                          fullDuration - CMTimeGetSeconds(clipStart))
    let clipDuration = CMTime(seconds: clipSeconds, preferredTimescale: 600)
    let clipRange = CMTimeRange(start: clipStart, duration: clipDuration)

    let composition = AVMutableVideoComposition()
    composition.renderSize = CGSize(width: targetW, height: targetH)
    composition.frameDuration = CMTime(
        value: 1, timescale: CMTimeScale(outputFPS.rounded())
    )

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = clipRange
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(
        track.preferredTransform.concatenating(
            CGAffineTransform(scaleX: scale, y: scale)
        ),
        at: .zero
    )
    instruction.layerInstructions = [layer]
    composition.instructions = [instruction]

    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = clipRange
    let readerOutput = AVAssetReaderVideoCompositionOutput(
        videoTracks: [track],
        videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
    )
    readerOutput.videoComposition = composition
    readerOutput.alwaysCopiesSampleData = false
    reader.add(readerOutput)

    try? FileManager.default.removeItem(at: destination)
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    writer.shouldOptimizeForNetworkUse = true

    let writerInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: targetW,
            AVVideoHeightKey: targetH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: spec.bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(outputFPS.rounded()),
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(outputFPS.rounded()) * 2),
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
            ] as [String: Any]
        ]
    )
    writerInput.expectsMediaDataInRealTime = false
    writer.add(writerInput)

    guard reader.startReading() else {
        throw TranscodeError.readerFailed(reader.error.map { "\($0)" } ?? "unknown")
    }
    guard writer.startWriting() else {
        throw TranscodeError.writerFailed(writer.error.map { "\($0)" } ?? "unknown")
    }
    writer.startSession(atSourceTime: clipStart)

    let queue = DispatchQueue(label: "muro.preview")
    let copyDone = DispatchSemaphore(value: 0)
    writerInput.requestMediaDataWhenReady(on: queue) {
        while writerInput.isReadyForMoreMediaData {
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                writerInput.markAsFinished()
                copyDone.signal()
                return
            }
            if !writerInput.append(sample) {
                reader.cancelReading()
                writerInput.markAsFinished()
                copyDone.signal()
                return
            }
        }
    }
    copyDone.wait()

    if reader.status == .failed {
        throw TranscodeError.readerFailed(reader.error.map { "\($0)" } ?? "unknown")
    }

    let finishDone = DispatchSemaphore(value: 0)
    writer.finishWriting { finishDone.signal() }
    finishDone.wait()
    guard writer.status == .completed else {
        throw TranscodeError.writerFailed(
            writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)"
        )
    }
    removeSafeSaveLeftovers(for: destination)

    let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? Int64
    return PreviewResult(
        width: targetW, height: targetH,
        duration: clipSeconds, sizeBytes: size ?? 0
    )
}

/// Rewrites a `.mov` with the `moov` atom at the front so it can stream,
/// without re-encoding a single frame — a passthrough export just relocates
/// the atom. Used to repair masters published before the writer set
/// `shouldOptimizeForNetworkUse`.
public func remuxForStreaming(source: URL, destination: URL) throws {
    let asset = AVURLAsset(url: source)
    guard let export = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetPassthrough
    ) else {
        throw TranscodeError.writerFailed("no passthrough export session")
    }
    try? FileManager.default.removeItem(at: destination)
    export.outputURL = destination
    export.outputFileType = .mov
    export.shouldOptimizeForNetworkUse = true

    let done = DispatchSemaphore(value: 0)
    export.exportAsynchronously { done.signal() }
    done.wait()

    guard export.status == .completed else {
        throw TranscodeError.writerFailed(
            export.error.map { "\($0)" } ?? "status \(export.status.rawValue)"
        )
    }
    removeSafeSaveLeftovers(for: destination)
}

private func evenSide(_ value: CGFloat) -> Int {
    let rounded = Int(value.rounded())
    return rounded % 2 == 0 ? rounded : rounded - 1
}

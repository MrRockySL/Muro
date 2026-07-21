// AVSampleBufferDisplayLayer renderer derived from Phosphene (MIT),
// copyright 2026 kageroumado; see THIRD_PARTY_NOTICES.md.
import AVFoundation
import CoreMedia
import ObjectiveC
import QuartzCore

private func disallowEmptyVideoLayerCompositing(_ layer: CALayer) {
    let selector = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: selector),
          let implementation = class_getMethodImplementation(type(of: layer), selector)
    else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(implementation, to: Setter.self)(layer, selector, true)
}

final class VideoRenderer: @unchecked Sendable {
    private let displayLayer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let asset: AVURLAsset
    private let videoTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "com.mrrockysl.muro.video-renderer", qos: .userInitiated)

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?
    private var presentationOffset: CMTime = .zero
    private var lastEnqueuedEnd: CMTime = .zero
    private var isRunning = true
    private var isPaused = false

    static func create(rootLayer: CALayer, videoURL: URL) throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loadedTrack: AVAssetTrack?
        nonisolated(unsafe) var loadError: Error?
        asset.loadTracks(withMediaType: .video) { tracks, error in
            loadedTrack = tracks?.first
            loadError = error
            semaphore.signal()
        }
        semaphore.wait()
        guard let track = loadedTrack else {
            throw loadError ?? CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track in \(videoURL.lastPathComponent)",
            ])
        }

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        displayLayer.isOpaque = true
        disallowEmptyVideoLayerCompositing(displayLayer)

        return VideoRenderer(
            rootLayer: rootLayer,
            displayLayer: displayLayer,
            asset: asset,
            videoTrack: track
        )
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack
    ) {
        self.displayLayer = displayLayer
        renderer = displayLayer.sampleBufferRenderer
        self.asset = asset
        self.videoTrack = videoTrack

        var createdTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &createdTimebase
        )
        timebase = createdTimebase!
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)
        displayLayer.controlTimebase = timebase

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(displayLayer)
        CATransaction.commit()
        CATransaction.flush()
    }

    func start(initiallyPaused: Bool, firstFrameReady: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self, isRunning else { firstFrameReady(); return }
            guard let reader = try? AVAssetReader(asset: asset) else {
                firstFrameReady()
                return
            }
            let output = makeOutput()
            reader.add(output)
            guard reader.startReading() else {
                extensionLog("renderer could not start reading: \(reader.error?.localizedDescription ?? "unknown")")
                firstFrameReady()
                return
            }

            currentReader = reader
            currentOutput = output
            presentationOffset = .zero
            lastEnqueuedEnd = .zero
            CMTimebaseSetTime(timebase, time: .zero)

            if let first = output.copyNextSampleBuffer() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                renderer.enqueue(first)
                noteEnd(of: first)
                CATransaction.commit()
                CATransaction.flush()
                extensionLog("renderer composited first frame")
            } else {
                extensionLog("renderer produced no first frame")
            }

            isPaused = initiallyPaused
            CMTimebaseSetRate(timebase, rate: initiallyPaused ? 0 : 1)
            firstFrameReady()
            prepareNextReader()
            feedCurrentReader()
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self, isRunning, !isPaused else { return }
            isPaused = true
            CMTimebaseSetRate(timebase, rate: 0)
        }
    }

    func resume() {
        queue.async { [weak self] in
            guard let self, isRunning, isPaused else { return }
            isPaused = false
            CMTimebaseSetRate(timebase, rate: 1)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            isRunning = false
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
            displayLayer.removeFromSuperlayer()
        }
    }

    private func makeOutput() -> AVAssetReaderTrackOutput {
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        return output
    }

    private func prepareNextReader() {
        guard isRunning, let reader = try? AVAssetReader(asset: asset) else { return }
        let output = makeOutput()
        reader.add(output)
        nextReader = reader
        nextOutput = output
    }

    private func feedCurrentReader() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning else {
                self?.renderer.stopRequestingMediaData()
                return
            }
            if renderer.status == .failed {
                extensionLog("video renderer failed: \(renderer.error?.localizedDescription ?? "unknown")")
                renderer.stopRequestingMediaData()
                return
            }
            if renderer.requiresFlushToResumeDecoding { renderer.flush() }

            while renderer.isReadyForMoreMediaData {
                guard let sample = currentOutput?.copyNextSampleBuffer() else {
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in self?.beginNextLoop() }
                    return
                }
                let adjusted = offsetTiming(of: sample)
                noteEnd(of: adjusted)
                renderer.enqueue(adjusted)
            }
        }
    }

    private func beginNextLoop() {
        presentationOffset = lastEnqueuedEnd
        if let preparedReader = nextReader, let preparedOutput = nextOutput {
            currentReader = preparedReader
            currentOutput = preparedOutput
        } else if let reader = try? AVAssetReader(asset: asset) {
            let output = makeOutput()
            reader.add(output)
            currentReader = reader
            currentOutput = output
        } else {
            extensionLog("renderer could not prepare next loop")
            return
        }
        nextReader = nil
        nextOutput = nil
        guard currentReader?.startReading() == true else {
            extensionLog("renderer could not start next loop")
            return
        }
        prepareNextReader()
        feedCurrentReader()
    }

    private func noteEnd(of sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        let duration = CMSampleBufferGetDuration(sample)
        let end = duration.isValid && duration > .zero
            ? CMTimeAdd(pts, duration)
            : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
        if end > lastEnqueuedEnd { lastEnqueuedEnd = end }
    }

    private func offsetTiming(of sample: CMSampleBuffer) -> CMSampleBuffer {
        guard presentationOffset > .zero else { return sample }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, presentationOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, presentationOffset) : .invalid
        )
        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjusted
        )
        return adjusted ?? sample
    }
}

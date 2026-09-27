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
    /// The earliest frame time the reader gives for this file. See
    /// `beginNextLoop`.
    private var firstFrameTime: CMTime = .invalid
    private var isRunning = true
    private var isPaused = false

    /// `behind` puts the video under any video already on the surface rather
    /// than over it. A playlist or automation step is built that way, so the
    /// video on screen stays in front until the new one can take over.
    static func create(rootLayer: CALayer, videoURL: URL, behind: Bool = false) throws -> VideoRenderer {
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
            videoTrack: track,
            behind: behind
        )
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        behind: Bool
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
        if behind {
            rootLayer.insertSublayer(displayLayer, at: 0)
        } else {
            rootLayer.addSublayer(displayLayer)
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// `firstFrameReady` carries whether a frame actually reached the layer.
    ///
    /// It used to carry nothing, so every caller was told "ready" even when the
    /// asset would not open. That mattered once the app started waiting on this
    /// answer to decide whether a lock-screen apply really took.
    func start(initiallyPaused: Bool, firstFrameReady: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, isRunning else { firstFrameReady(false); return }
            guard let reader = try? AVAssetReader(asset: asset) else {
                extensionLog("renderer could not open the video")
                firstFrameReady(false)
                return
            }
            let output = makeOutput()
            reader.add(output)
            guard reader.startReading() else {
                extensionLog("renderer could not start reading: \(reader.error?.localizedDescription ?? "unknown")")
                firstFrameReady(false)
                return
            }

            currentReader = reader
            currentOutput = output
            presentationOffset = .zero
            lastEnqueuedEnd = .zero
            CMTimebaseSetTime(timebase, time: .zero)

            var composited = false
            if let first = output.copyNextSampleBuffer() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                renderer.enqueue(first)
                noteEnd(of: first)
                CATransaction.commit()
                CATransaction.flush()
                composited = true
                extensionTrace("renderer composited first frame")
            } else {
                extensionLog("renderer produced no first frame")
            }

            isPaused = initiallyPaused
            CMTimebaseSetRate(timebase, rate: initiallyPaused ? 0 : 1)
            firstFrameReady(composited)
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

    /// Hidden while the desktop is showing its own still. Not the same as
    /// pausing: a paused layer still draws its last frame, which is the wrong
    /// wallpaper, or nothing at all when the first frame never composited.
    func setHidden(_ hidden: Bool) {
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.isHidden = hidden
            CATransaction.commit()
            CATransaction.flush()
        }
    }

    /// Strongly, on purpose.
    ///
    /// This captured self weakly, and the caller is a surface being taken away:
    /// it calls stop and then releases the renderer, so the block usually ran
    /// after the object was already gone and did nothing at all. Nothing at all
    /// leaves the media-data request armed. See `feedCurrentReader` for what
    /// that costs. The block releases self as soon as it has run, so holding it
    /// for the length of one teardown keeps nothing alive.
    func stop() {
        queue.async {
            self.isRunning = false
            self.renderer.stopRequestingMediaData()
            self.currentReader?.cancelReading()
            self.nextReader?.cancelReading()
            self.displayLayer.removeFromSuperlayer()
        }
    }

    // MARK: - Playlist steps

    /// Moves the stopped clock onto the first frame.
    ///
    /// A paused layer shows the frame at the clock's time, and in many files
    /// the first frame is not at zero: Camper Van on the Hill starts at 33 ms.
    /// With the clock left at zero, such a file has nothing to show until it
    /// plays, so a step waiting for its first frame would wait for nothing.
    /// Playing then starts from that frame.
    func showFirstFrame() {
        queue.async { [weak self] in
            guard let self, isRunning, isPaused, firstFrameTime.isValid else { return }
            CMTimebaseSetTime(timebase, time: firstFrameTime)
        }
    }

    /// Calls back once the layer really has a frame to show, or with false
    /// after `timeout`.
    ///
    /// A frame handed to the layer is not yet a frame on screen: it is still
    /// compressed, and decoding it takes a moment. Taking the old video away
    /// in that moment is what flashed whatever was underneath it at a
    /// playlist step. macOS says when the frame is ready. It is polled a few
    /// milliseconds apart, because it usually comes within a few frames.
    ///
    /// Holds itself strongly until it has answered, so the answer always
    /// comes and a step never waits on a renderer that went away.
    func whenReadyForDisplay(timeout: TimeInterval, _ body: @escaping @Sendable (Bool) -> Void) {
        let deadline = DispatchTime.now() + timeout
        queue.async { [self] in pollReady(until: deadline, body) }
    }

    private func pollReady(until deadline: DispatchTime, _ body: @escaping @Sendable (Bool) -> Void) {
        guard isRunning else { body(false); return }
        if displayLayer.isReadyForDisplay { body(true); return }
        guard DispatchTime.now() < deadline else { body(false); return }
        queue.asyncAfter(deadline: .now() + .milliseconds(8)) { [self] in
            pollReady(until: deadline, body)
        }
    }

    /// Fades this video out over `seconds`, then stops it and takes its layer
    /// away. Zero takes it away at once.
    ///
    /// A playlist step builds the next video underneath this one, so fading
    /// this one out is the crossfade: the next video shows through it. The
    /// fade runs in the system compositor rather than in this process. The
    /// layer goes in a transaction of its own, flushed, because this queue has
    /// no run loop that would commit it. Strongly held for the same reason as
    /// `stop`.
    func fadeOutAndStop(over seconds: TimeInterval) {
        queue.async { [self] in
            guard isRunning else { return }
            if seconds > 0 {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = displayLayer.opacity
                fade.toValue = 0
                fade.duration = seconds
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                displayLayer.add(fade, forKey: "muro.stepFade")
                displayLayer.opacity = 0
                CATransaction.commit()
                CATransaction.flush()
            }
            queue.asyncAfter(deadline: .now() + seconds) { [self] in
                isRunning = false
                renderer.stopRequestingMediaData()
                currentReader?.cancelReading()
                nextReader?.cancelReading()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                displayLayer.removeFromSuperlayer()
                CATransaction.commit()
                CATransaction.flush()
            }
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
        // The renderer is captured weakly beside self, because `self?.renderer`
        // is nil in the one case that matters. AVFoundation owns this block and
        // goes on calling it until something calls `stopRequestingMediaData`.
        // When the surface has gone, self is nil, so `self?.renderer` reached
        // nothing, the request stayed armed, and the block was called again the
        // instant it returned. That loop is one CPU core, held for as long as
        // the extension lives, per surface that was ever taken away. Measured
        // at 100% of a core each, against 0% for a surface that is simply
        // sitting there. The video renderer outlives this object, so a weak
        // handle to it is still something to switch off.
        renderer.requestMediaDataWhenReady(on: queue) { [weak self, weak armed = self.renderer] in
            guard let self, isRunning else {
                armed?.stopRequestingMediaData()
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
        // A loop step is queued from inside the callback, so it can be waiting
        // behind a stop. Without this it would arm the request again on a
        // renderer that has just been switched off.
        guard isRunning else { return }
        presentationOffset = lastEnqueuedEnd
        // Issue #39, on the lock screen and the screen saver. This reader gives
        // the file's raw frame times, and in many files the first frame is not
        // at zero: Camper Van on the Hill and Miles Morales in Space both start
        // at 33 ms. Placed at the last frame's end, every loop then began with
        // that much nothing, and the last frame stayed up that much longer each
        // time round. The screen saver runs for minutes, so it loops. Moving
        // the loop back by the first frame's time makes it start right after
        // the last frame. A file whose first frame is at zero keeps the line
        // above as it was.
        if firstFrameTime.isValid, firstFrameTime > .zero {
            presentationOffset = CMTimeSubtract(lastEnqueuedEnd, firstFrameTime)
            extensionTrace("renderer loop moved back \(Int((firstFrameTime.seconds * 1000).rounded())) ms to its first frame")
        }
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
        // Only the first pass can set it: every later loop is moved forward.
        if !firstFrameTime.isValid || pts < firstFrameTime { firstFrameTime = pts }
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

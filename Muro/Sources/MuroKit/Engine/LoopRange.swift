import AVFoundation

/// Issue #39. Some wallpapers open with an empty edit: their video track shows
/// nothing for the first 17 to 100 ms. AVPlayerLooper plays that gap again at
/// every loop, so the picture stops for a few frames each time round, and on
/// some Macs the stop reads as a flick. Camper Van on the Hill has 33 ms of
/// gap and stopped for 52 ms at the loop against a 16 ms frame; looped from
/// its first real frame it stopped for 20 ms. 31 of the 271 live wallpapers
/// have the gap, all of them original H.264 uploads.
///
/// So every loop starts at the first real frame. A file without the gap gets
/// exactly the looper it always had.
public enum LoopRange {
    public static func looper(player: AVQueuePlayer, url: URL) -> AVPlayerLooper {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        guard let range = trimmed(asset) else {
            return AVPlayerLooper(player: player, templateItem: item)
        }
        return AVPlayerLooper(player: player, templateItem: item, timeRange: range)
    }

    /// Where the real frames are, for a file that opens with a gap. Nil for a
    /// file without one, and for anything that cannot be read straight away:
    /// a streamed preview (those never have the gap) or a file that does not
    /// answer, which then loops as it always did.
    static func trimmed(_ asset: AVURLAsset) -> CMTimeRange? {
        guard asset.url.isFileURL else { return nil }
        var loadedTrack: AVAssetTrack?
        let loaded = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            loadedTrack = tracks?.first
            loaded.signal()
        }
        // A file on disk answers in a few milliseconds.
        guard loaded.wait(timeout: .now() + 1) == .success,
              let track = loadedTrack,
              let firstFrame = track.segments.first(where: { !$0.isEmpty })
        else { return nil }
        return range(firstFrameAt: firstFrame.timeMapping.target.start, duration: asset.duration)
    }

    /// The rule on its own: from the first real frame to the end, and only
    /// when there is a gap before that frame to skip.
    static func range(firstFrameAt start: CMTime, duration: CMTime) -> CMTimeRange? {
        guard start.isNumeric, duration.isNumeric, start > .zero, start < duration else { return nil }
        return CMTimeRange(start: start, end: duration)
    }
}

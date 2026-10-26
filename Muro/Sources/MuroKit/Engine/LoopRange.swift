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
    /// What `make` built.
    public struct Built {
        public let looper: AVPlayerLooper
        /// The file has sound in it, which only a video the person added
        /// keeps (issue #54). Whether the looper plays it is the caller's
        /// `sound`.
        public let hasSound: Bool
        /// Where the first real frame sits in the item the looper plays: zero
        /// for the picture on its own, later for a file with a gap played
        /// with its sound. A change between the two keeps its place by it.
        public let pictureStart: CMTime
    }

    /// The picture only, which is all every silent file has.
    public static func looper(player: AVQueuePlayer, url: URL) -> AVPlayerLooper {
        make(player: player, url: url, sound: false).looper
    }

    /// Issue #54. A file without sound loops exactly as it always did.
    ///
    /// A file with sound loops its picture, from the first real frame to the
    /// last: the sound can run a few milliseconds past the picture, AAC pads
    /// its ends, and looping the whole file would hold the last frame at every
    /// loop, the stop issue #39 was about. Its sound is played only when
    /// `sound` asks for it. Otherwise the looper plays a copy holding the
    /// picture alone, because muting is not enough: measured on the owner's
    /// Mac on 2026-10-26, a muted player kept the Mac's audio output running
    /// the whole time and cost twice the CPU of the picture alone, and
    /// switching the sound track off on the player items changed neither.
    public static func make(player: AVQueuePlayer, url: URL, sound: Bool) -> Built {
        let asset = AVURLAsset(url: url)
        guard let picture = pictureWithSound(asset) else {
            let item = AVPlayerItem(asset: asset)
            guard let range = trimmed(asset) else {
                return Built(
                    looper: AVPlayerLooper(player: player, templateItem: item),
                    hasSound: false, pictureStart: .zero
                )
            }
            return Built(
                looper: AVPlayerLooper(player: player, templateItem: item, timeRange: range),
                hasSound: false, pictureStart: range.start
            )
        }
        if !sound, let silent = pictureOnly(picture.track, range: picture.range) {
            return Built(
                looper: AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: silent)),
                hasSound: true, pictureStart: .zero
            )
        }
        return Built(
            looper: AVPlayerLooper(
                player: player, templateItem: AVPlayerItem(asset: asset), timeRange: picture.range
            ),
            hasSound: true, pictureStart: picture.range.start
        )
    }

    /// The real frames of a file with sound in it, from the first to the
    /// last. Nil for a silent file, which loops exactly as it did before.
    static func withSound(_ asset: AVURLAsset) -> CMTimeRange? {
        pictureWithSound(asset)?.range
    }

    private static func pictureWithSound(_ asset: AVURLAsset) -> (range: CMTimeRange, track: AVAssetTrack)? {
        guard asset.url.isFileURL else { return nil }
        var videoTrack: AVAssetTrack?
        var hasAudio = false
        // Both asked at once, so a slow disk costs the one second `trimmed`
        // has always allowed and no more; `trimmed` then finds the video
        // track already loaded.
        let loaded = DispatchGroup()
        loaded.enter()
        asset.loadTracks(withMediaType: .audio) { tracks, _ in
            hasAudio = !(tracks ?? []).isEmpty
            loaded.leave()
        }
        loaded.enter()
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            videoTrack = tracks?.first
            loaded.leave()
        }
        guard loaded.wait(timeout: .now() + 1) == .success,
              hasAudio,
              let track = videoTrack,
              let firstFrame = track.segments.first(where: { !$0.isEmpty }),
              let lastFrame = track.segments.last(where: { !$0.isEmpty })
        else { return nil }
        let start = firstFrame.timeMapping.target.start
        let end = lastFrame.timeMapping.target.end
        guard start.isNumeric, end.isNumeric, end > start else { return nil }
        return (CMTimeRange(start: start, end: end), track)
    }

    /// The picture alone, from its first real frame: a composition holding
    /// the video track and nothing else, so no sound can start.
    static func pictureOnly(_ track: AVAssetTrack, range: CMTimeRange) -> AVComposition? {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        do {
            try video.insertTimeRange(range, of: track, at: .zero)
        } catch {
            return nil
        }
        video.preferredTransform = track.preferredTransform
        return composition
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

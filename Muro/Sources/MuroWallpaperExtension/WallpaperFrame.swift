import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A still frame of the lock wallpaper itself, taken from the staged video.
///
/// Two things need one and neither can do without it.
///
/// The layer behind the video needs something to draw when the app has not
/// staged a desktop still, and the wallpaper's own thumbnail was doing that
/// job. A thumbnail is capped at 1280 wide and it is not always there: it is
/// staged next to the video, and a library entry that has lost either file
/// reads as absent. That left the still layer empty, which is the black
/// desktop, so the last fallback has to be something that cannot go missing
/// while the wallpaper itself is playable.
///
/// macOS needs one too, for `snapshot`. See `WallpaperSnapshot`.
///
/// Sampled a second in rather than at zero, the same as the library's own
/// thumbnails, because a clip that fades in from black would otherwise give a
/// black frame. Written next to the video it came from so it survives the
/// process, and so a second request costs a JPEG decode rather than a video
/// one.
enum WallpaperFrame {
    private static let sampleSeconds = 1.0

    /// One entry, because Muro keeps one lock-screen wallpaper. macOS asks for
    /// the same surface in bursts of dozens, and decoding even a JPEG that
    /// many times for one answer would be work for nothing.
    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var memory: (id: String, image: CGImage)?

    /// The frame for `choiceID`, decoded from the staged video the first time
    /// and kept afterwards. Nil only when there is no staged video to read.
    static func image(for choiceID: String?) -> CGImage? {
        guard let choiceID else { return nil }
        memoryLock.lock()
        let remembered = memory?.id == choiceID ? memory?.image : nil
        memoryLock.unlock()
        if let remembered { return remembered }

        guard let image = load(choiceID) else { return nil }
        memoryLock.lock()
        memory = (choiceID, image)
        memoryLock.unlock()
        return image
    }

    private static func load(_ choiceID: String) -> CGImage? {
        let cache = cacheURL(for: choiceID)
        if let existing = DesktopStill.image(at: cache) { return existing }
        guard let video = stagedVideoURL(for: choiceID) else { return nil }
        guard let frame = extractFrame(from: video) else {
            // A wallpaper whose frame will not decode still has a thumbnail,
            // and something on screen beats nothing.
            return stagedThumbnailURL(for: choiceID).flatMap(DesktopStill.image)
        }
        write(frame, to: cache)
        return frame
    }

    private static func cacheURL(for choiceID: String) -> URL {
        documentsURL
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(choiceID, isDirectory: true)
            .appendingPathComponent("frame.jpg")
    }

    private static func extractFrame(from video: URL) -> CGImage? {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Never earlier than asked for, and a second's worth of slack after,
        // so a nearby keyframe is allowed but a clip that fades in from black
        // cannot answer with its own first frame.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let at = CMTime(seconds: sampleSeconds, preferredTimescale: 600)
        return try? generator.copyCGImage(at: at, actualTime: nil)
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        CGImageDestinationFinalize(destination)
    }
}

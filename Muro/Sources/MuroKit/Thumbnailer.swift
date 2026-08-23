import AVFoundation
import AppKit

public enum ThumbnailError: Error, CustomStringConvertible {
    case encodeFailed

    public var description: String { "could not encode thumbnail JPEG" }
}

/// Extracts one frame and writes it as a JPEG, used for library cards and
/// menu-bar recents. Wide time tolerance keeps extraction near-instant.
public func generateThumbnail(
    video: URL,
    destination: URL,
    at seconds: Double = 1.0,
    maxDimension: CGFloat = 1280
) throws {
    let asset = AVURLAsset(url: video)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity

    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    let cgImage: CGImage
    do {
        cgImage = try generator.copyCGImage(at: time, actualTime: nil)
    } catch {
        // A clip shorter than the sample point may have no frame there. Fall
        // back to the very first frame rather than failing, which used to take
        // the whole import down with it.
        cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
        throw ThumbnailError.encodeFailed
    }
    try jpeg.write(to: destination, options: .atomic)
}

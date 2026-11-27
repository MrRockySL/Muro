import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// What a static wallpaper needs beyond its picture: the picture at the size
/// a screen needs, a JPEG of it for the desktop picture Muro leaves behind,
/// and a still video of it for the lock screen and the screen saver, which
/// Muro's extension shows by playing a video.
public enum StaticStill {
    /// The picture, the right way up, no bigger than `maxPixels` on its
    /// longest side. Never made bigger than it is.
    public static func image(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The picture's size as it shows, rotation applied.
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// How big the picture has to be decoded to fill a screen of `screen`
    /// pixels edge to edge, as its longest side. The picture covers the
    /// screen, so the side that fits tighter decides, and it is never asked
    /// for bigger than it is.
    public static func fillPixels(picture: CGSize, screen: CGSize) -> Int {
        guard picture.width > 0, picture.height > 0 else { return Int(max(screen.width, screen.height)) }
        let scale = min(1, max(screen.width / picture.width, screen.height / picture.height))
        return Int((max(picture.width, picture.height) * scale).rounded(.up))
    }

    /// A JPEG of the picture, for the desktop picture Muro leaves behind when
    /// it is not running (see the app's `DesktopStillService`).
    public static func writeJPEG(from picture: URL, to destination: URL, maxPixels: Int = 3840) throws {
        guard let image = image(at: picture, maxPixels: maxPixels) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(
            output, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// How long the still video is, and how far apart its two frames are.
    /// Two frames, not one, so the extension's loop has something to hand
    /// over to; both are the picture, so nothing ever changes on screen, and
    /// it decodes one frame every two seconds while it is shown at all.
    static let videoSeconds: Int64 = 4

    /// The still video the lock screen and the screen saver play: the
    /// picture, held. HEVC, with the same settings Muro's own transcodes use,
    /// written beside `destination` and moved into place once it is complete.
    public static func makeVideo(from picture: URL, to destination: URL, maxPixels: Int = 3840) async throws {
        guard let image = image(at: picture, maxPixels: maxPixels) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // HEVC wants even sizes.
        let width = max(2, image.width & ~1)
        let height = max(2, image.height & ~1)
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".still-\(UUID().uuidString).mov")

        // Not optimized for network use: the file is only ever read from
        // disk, and that option leaves a safe-save copy behind it.
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 20_000_000,
                AVVideoExpectedSourceFrameRateKey: 1,
                AVVideoMaxKeyFrameIntervalKey: 2,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        do {
            let buffer = try pixelBuffer(of: image, width: width, height: height, pool: adaptor.pixelBufferPool)
            for second in [Int64(0), videoSeconds / 2] {
                var waited = 0
                while !input.isReadyForMoreMediaData {
                    waited += 1
                    if waited > 1000 { throw CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: second, timescale: 1)) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: videoSeconds, timescale: 1))
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                writer.finishWriting { done.resume() }
            }
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            // Removed and moved rather than replaced: replacing leaves a
            // safe-save copy of the old file beside it. Nothing reads this
            // file while it is swapped; the lock screen plays its own copy.
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: partial, to: destination)
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    private static func pixelBuffer(
        of image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
        }
        if made == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary,
                &made
            )
        }
        guard let buffer = made else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

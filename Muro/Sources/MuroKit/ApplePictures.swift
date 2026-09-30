import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Apple's still Dynamic Wallpapers, made ready for macOS to show.
///
/// Each one comes from Apple's servers as a zip holding one HEIC picture of
/// 6016 by 6016, with a light and a dark image inside it (the solar ones hold
/// a whole day of them). macOS picks between those by itself. Muro shows a
/// Light and a Dark card for each (owner, 2026-09-30), so the image each card
/// stands for is cut out into a picture of its own, and that is what macOS is
/// given. Solar Gradients has no light or dark of its own and is given whole,
/// so macOS goes on changing it through the day.
///
/// The files sit beside Muro's other downloads (`AppleAerials.cacheDir`),
/// named after the card, so they follow the Download Folder and the Clear
/// sweep leaves them alone. Once both cuts exist the zip and the whole
/// picture are deleted.
public enum ApplePictures {

    /// The picture macOS is given for this card.
    public static func file(for aerial: AppleAerial, libraryRoot: URL) -> URL {
        AppleAerials.cacheDir(libraryRoot: libraryRoot)
            .appendingPathComponent(AppleAerials.pictureFileName(assetID: aerial.assetID))
    }

    public static func isReady(_ aerial: AppleAerial, libraryRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(for: aerial, libraryRoot: libraryRoot).path)
    }

    /// The light and the dark card of one picture share a download. Given
    /// either, this names both, so one download makes both ready.
    public static func sides(of aerial: AppleAerial) -> (light: String, dark: String)? {
        let id = aerial.assetID
        if id.hasSuffix("-light") {
            let base = String(id.dropLast("-light".count))
            return (base + "-light", base + "-dark")
        }
        if id.hasSuffix("-dark") {
            let base = String(id.dropLast("-dark".count))
            return (base + "-light", base + "-dark")
        }
        return nil
    }

    public enum PrepareError: LocalizedError {
        case unzipFailed
        case noPicture
        case cutFailed

        public var errorDescription: String? {
            switch self {
            case .unzipFailed: return "The picture from Apple could not be opened."
            case .noPicture: return "Apple's download held no picture."
            case .cutFailed: return "The light and dark pictures could not be made."
            }
        }
    }

    /// Turns the zip Apple sent into the pictures the cards stand for.
    ///
    /// `zip` is deleted afterwards whatever happens, and so is everything it
    /// unpacked, so a failed attempt leaves nothing behind but what was
    /// already there.
    public static func finish(zip: URL, for aerial: AppleAerial, libraryRoot: URL) throws {
        let manager = FileManager.default
        let work = zip.deletingLastPathComponent()
            .appendingPathComponent(".\(AppleAerials.idPrefix)\(aerial.assetID)-unzip-\(UUID().uuidString)",
                                    isDirectory: true)
        defer {
            try? manager.removeItem(at: work)
            try? manager.removeItem(at: zip)
        }
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, work.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw PrepareError.unzipFailed }

        guard let picture = manager.enumerator(at: work, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.pathExtension.lowercased() == "heic" })
        else { throw PrepareError.noPicture }

        let directory = AppleAerials.cacheDir(libraryRoot: libraryRoot)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let sides = sides(of: aerial) else {
            // No light and dark of its own: macOS gets the whole picture and
            // keeps changing it through the day.
            let target = file(for: aerial, libraryRoot: libraryRoot)
            try? manager.removeItem(at: target)
            try manager.moveItem(at: picture, to: target)
            return
        }
        guard let source = CGImageSourceCreateWithURL(picture as CFURL, nil) else {
            throw PrepareError.noPicture
        }
        let indexes = appearanceIndexes(of: source)
        for (assetID, index) in [(sides.light, indexes.light), (sides.dark, indexes.dark)] {
            let target = directory.appendingPathComponent(AppleAerials.pictureFileName(assetID: assetID))
            try cut(source, index: index, to: target)
        }
    }

    /// Which image is the light one and which the dark, from the note Apple
    /// writes into the picture: `apple_desktop:apr` for a light and dark
    /// pair, `apple_desktop:solar` for one that changes with the sun, whose
    /// `ap` entry names the light and dark images of the day. Without a note,
    /// the first image is light and the last is dark.
    static func appearanceIndexes(of source: CGImageSource) -> (light: Int, dark: Int) {
        let count = CGImageSourceGetCount(source)
        let fallback = (light: 0, dark: max(0, count - 1))
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag]
        else { return fallback }
        for tag in tags {
            guard (CGImageMetadataTagCopyPrefix(tag) as String?) == "apple_desktop",
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  let text = CGImageMetadataTagCopyValue(tag) as? String,
                  let data = Data(base64Encoded: text),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                    as? [String: Any]
            else { continue }
            let pair = name == "solar" ? plist["ap"] as? [String: Any] : plist
            if let light = pair?["l"] as? Int, let dark = pair?["d"] as? Int,
               light < count, dark < count {
                return (light, dark)
            }
        }
        return fallback
    }

    /// The picture a card and the detail view show once the real one is here:
    /// 1920 pixels wide, cut to the 16 by 9 the cards are, from the middle,
    /// which is the part a desktop shows of a square picture.
    public static func makeCardPicture(from source: URL, to destination: URL) throws {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(reader, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1920,
              ] as CFDictionary)
        else { throw PrepareError.cutFailed }
        let width = image.width
        let height = min(image.height, width * 9 / 16)
        let crop = CGRect(x: 0, y: (image.height - height) / 2, width: width, height: height)
        guard let card = image.cropping(to: crop) else { throw PrepareError.cutFailed }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw PrepareError.cutFailed }
        CGImageDestinationAddImage(writer, card, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw PrepareError.cutFailed }
    }

    /// One image of the picture, written as a picture of its own. HEIC, at
    /// full size and near full quality: this is what the desktop shows.
    static func cut(_ source: CGImageSource, index: Int, to target: URL) throws {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            throw PrepareError.cutFailed
        }
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: partial)
        guard let destination = CGImageDestinationCreateWithURL(
            partial as CFURL, UTType.heic.identifier as CFString, 1, nil
        ) else { throw PrepareError.cutFailed }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            throw PrepareError.cutFailed
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The person's own desktop picture, on a display where Muro is only the
/// lock screen (#58).
///
/// macOS keeps one wallpaper per display for the desktop and the lock screen
/// together, and a lock screen set from Muro lives in that slot. So somebody
/// who wants Muro on the lock screen and their own picture on the desktop
/// could not have both: setting the lock screen changed their desktop to a
/// frame of the live wallpaper, and putting their picture back in System
/// Settings took the lock screen away.
///
/// Muro cannot get a second slot. What it can do is stay in the one there is
/// and show their picture itself: its wallpaper extension already draws a
/// still on the desktop while the Mac is unlocked and plays the video once it
/// locks. So the picture that was in the slot is read before Muro takes it,
/// and read again whenever the person sets another one, and the extension is
/// handed a copy to draw.
///
/// Only a plain still picture counts. Anything macOS draws or changes by
/// itself (an aerial, a folder that shuffles, a picture that follows the time
/// of day) cannot be shown as one file, and is left to macOS.
public enum OwnDesktopPicture {

    /// What macOS most recently put in one display's desktop role.
    public enum Occupant: Equatable {
        /// One picture file.
        case picture(URL)
        /// macOS's own default wallpaper.
        case macOSDefault
        /// Anything else: Muro's own extension, an aerial, a shuffling
        /// folder, a wallpaper macOS draws.
        case other
    }

    /// One picture a display's desktop role was given, and when.
    public struct Pick: Equatable {
        public var file: URL
        public var setAt: Date?

        public init(file: URL, setAt: Date?) {
            self.file = file
            self.setAt = setAt
        }
    }

    /// What this display's desktop role holds now, or `nil` when the store
    /// says nothing about it.
    public static func occupant(forDisplay uuid: String, in store: Any?) -> Occupant? {
        LockScreenReplacement.latestDesktopSurface(forDisplay: uuid, in: store).map(occupant(of:))
    }

    /// The still picture this display's desktop role holds now, if that is
    /// what it holds.
    public static func pick(forDisplay uuid: String, in store: Any?) -> Pick? {
        guard let surface = LockScreenReplacement.latestDesktopSurface(forDisplay: uuid, in: store),
              case .picture(let file) = occupant(of: surface)
        else { return nil }
        return Pick(file: file, setAt: surface["LastSet"] as? Date)
    }

    /// Reads one surface of Apple's store.
    ///
    /// A picture is the shape macOS writes for one, read off the owner's Mac
    /// (see `MacOSWallpaperChoice.picture`): a single choice from the image
    /// provider whose configuration is an `imageFile` with a file address.
    /// More than one choice, or a `Shuffle` that is switched on, is a set
    /// macOS moves through by itself.
    public static func occupant(of surface: [String: Any]) -> Occupant {
        guard let content = surface["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              choices.count == 1,
              let provider = choices[0]["Provider"] as? String
        else { return .other }
        if provider == MacOSWallpaperChoice.defaultProvider { return .macOSDefault }
        guard provider == MacOSWallpaperChoice.imageProvider else { return .other }
        // A property list cannot hold a null, so macOS writes this word for
        // "no shuffle". Anything else there is a shuffle of some kind.
        if let shuffle = content["Shuffle"], (shuffle as? String) != "$null" { return .other }
        guard let data = choices[0]["Configuration"] as? Data, !data.isEmpty,
              let configuration = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any],
              configuration["type"] as? String == "imageFile",
              let relative = (configuration["url"] as? [String: Any])?["relative"] as? String,
              let url = URL(string: relative), url.isFileURL
        else { return .other }
        return .picture(url.standardizedFileURL)
    }

    /// Whether a surface holds a still picture of the person's own: a picture
    /// that is not one of Muro's files.
    ///
    /// For the backup of Apple's store, which learns a picture just before
    /// Muro's lock screen is written over it, so taking the lock screen off
    /// puts back the picture the person has now and not the one they had the
    /// first time. Only a picture is learnt. macOS can also put its default
    /// wallpaper in a slot by itself, when it throws an extension out, and
    /// that is not something the person chose.
    public static func isOwnPicture(_ surface: [String: Any], muroFolders: [URL]) -> Bool {
        guard case .picture(let file) = occupant(of: surface) else { return false }
        return !muroFolders.contains { isInside(file, $0) }
    }

    /// Whether `file` sits somewhere under `folder`.
    public static func isInside(_ file: URL, _ folder: URL) -> Bool {
        let base = folder.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    // MARK: - The file

    /// Whether this is one still picture that can be read.
    ///
    /// A file holding several pictures is one macOS changes between (light
    /// and dark, or the time of day), or an animation, and showing only its
    /// first would not be the person's desktop.
    public static func isStillPicture(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1
        else { return false }
        return pixelSize(of: source) != nil
    }

    /// The picture's size the way it is seen: a photo stored on its side is
    /// measured upright.
    static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// How long the copy's longest side has to be, in pixels.
    ///
    /// The picture fills the screen, so it is the screen it has to cover and
    /// nothing more: the extension keeps the whole copy decoded in memory, and
    /// a 12,000 pixel photo there is hundreds of megabytes for a desktop that
    /// cannot show them. A screen under 4K is counted as 4K, so the copy still
    /// looks right after the display is set to a sharper mode. A picture
    /// smaller than that is never made bigger.
    public static func copyPixelSize(image: CGSize, screen: CGSize) -> Int {
        let longest = max(image.width, image.height)
        guard image.width > 0, image.height > 0, screen.width > 0, screen.height > 0 else {
            return Int(longest.rounded(.up))
        }
        let boost = max(1, 3840 / max(screen.width, screen.height))
        let cover = max(
            screen.width * boost / image.width,
            screen.height * boost / image.height
        )
        return Int((cover >= 1 ? longest : longest * cover).rounded(.up))
    }

    public enum CopyError: Error {
        case unreadable
        case notWritten
    }

    /// Writes a copy of `source` the extension can draw: upright, no larger
    /// than the screen needs, as a JPEG.
    ///
    /// A copy rather than the file itself for two reasons. The person may move
    /// or delete their picture, and the desktop must not go blank when they
    /// do. And the extension draws the pixels exactly as they are stored, so a
    /// photo kept on its side with a note saying which way is up has to be
    /// turned here.
    public static func makeCopy(of source: URL, to destination: URL, screen: CGSize) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) == 1,
              let size = pixelSize(of: imageSource)
        else { throw CopyError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: copyPixelSize(image: size, screen: screen),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        else { throw CopyError.unreadable }

        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Written beside it and moved into place, so nothing ever reads half
        // a picture.
        let incoming = destination.appendingPathExtension("incoming")
        try? manager.removeItem(at: incoming)
        guard let writer = CGImageDestinationCreateWithURL(
            incoming as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CopyError.notWritten }
        CGImageDestinationAddImage(
            writer, image,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
        )
        guard CGImageDestinationFinalize(writer) else {
            try? manager.removeItem(at: incoming)
            throw CopyError.notWritten
        }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: incoming)
        } else {
            try manager.moveItem(at: incoming, to: destination)
        }
    }
}

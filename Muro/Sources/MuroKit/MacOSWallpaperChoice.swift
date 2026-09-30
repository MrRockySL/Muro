import Foundation

/// The records macOS keeps in its wallpaper store for the wallpapers only
/// macOS can show: Apple's still pictures and the ones drawn by code.
///
/// Each shape is the one macOS itself writes, read off the owner's Mac on
/// macOS 27 (2026-09-30): a picture is `com.apple.wallpaper.choice.image` with
/// a binary property list naming the file; Sequoia and Macintosh are their own
/// providers and start from an empty configuration, which macOS draws with
/// the Mac's own light or dark mode. Muro writes these with the same helpers
/// it writes its own lock screen with (`AppleWallpaperStore`), so the same
/// care about linked and per-display nodes applies to them.
public enum MacOSWallpaperChoice {

    public static let imageProvider = "com.apple.wallpaper.choice.image"
    public static let defaultProvider = "default"

    /// A still picture, shown by macOS's own image wallpaper.
    public static func picture(file: URL) -> [String: Any] {
        let configuration: [String: Any] = [
            "type": "imageFile",
            "url": ["relative": file.absoluteString],
        ]
        return [
            "Provider": imageProvider,
            // macOS writes this empty itself, and then logs "Failed
            // transformation of image choice. No files include in the
            // descriptor" for the screen saver role (seen 2026-09-30). Naming
            // the file here too, the way Muro's own lock screen does, is what
            // it asks for, and costs nothing where it is not needed.
            "Files": [["relative": file.absoluteString]],
            "Configuration": (try? PropertyListSerialization.data(
                fromPropertyList: configuration, format: .binary, options: 0)) ?? Data(),
        ]
    }

    /// One of the wallpapers macOS draws with its own code.
    public static func drawn(provider: String) -> [String: Any] {
        ["Provider": provider, "Files": [], "Configuration": Data()]
    }

    /// macOS's own default wallpaper, for taking one of these away again.
    public static var macOSDefault: [String: Any] {
        ["Provider": defaultProvider, "Files": [], "Configuration": Data()]
    }

    /// The provider macOS draws a drawn wallpaper with, from its card's id:
    /// `apple-drawn-sequoia` is `com.apple.wallpaper.choice.sequoia`.
    public static func drawnProvider(forAssetID assetID: String) -> String? {
        guard assetID.hasPrefix("drawn-") else { return nil }
        let name = String(assetID.dropFirst("drawn-".count))
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return "com.apple.wallpaper.choice.\(name)"
    }

    /// Whether a store surface is showing exactly this choice: the same
    /// provider and the same configuration, so a desktop still Muro wrote
    /// through the same image provider never counts as one of these.
    public static func surface(_ surface: [String: Any], shows choice: [String: Any]) -> Bool {
        guard let content = surface["Content"] as? [String: Any],
              let first = (content["Choices"] as? [[String: Any]])?.first
        else { return false }
        return first["Provider"] as? String == choice["Provider"] as? String
            && (first["Configuration"] as? Data ?? Data()) == (choice["Configuration"] as? Data ?? Data())
    }
}

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
            // Empty, exactly as macOS writes it itself (read back from a
            // picture set through NSWorkspace on macOS 27, 2026-09-30). With
            // the file named here as well, macOS's picture reader failed with
            // NSCocoaErrorDomain 4865, a value missing, and showed its default
            // wallpaper instead.
            "Files": [],
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

    /// Whether a store surface is showing this choice.
    ///
    /// Compared by what the record means, not by its bytes: macOS rewrites
    /// the store in its own encoding once it has read it, and Macintosh came
    /// back with a configuration of its own, so a byte compare decided Muro's
    /// choice was gone and the desktop still was written over it (seen
    /// 2026-09-30). The same provider is enough for one macOS draws; a
    /// picture or a screen saver also has to name the same file, so a desktop
    /// still Muro wrote through the same image provider never counts.
    public static func surface(_ surface: [String: Any], shows choice: [String: Any]) -> Bool {
        guard let content = surface["Content"] as? [String: Any],
              let first = (content["Choices"] as? [[String: Any]])?.first,
              let provider = choice["Provider"] as? String,
              first["Provider"] as? String == provider
        else { return false }
        guard let wanted = address(in: choice) else { return true }
        return address(in: first) == wanted
    }

    /// The file a picture or a screen saver record names, or nil for a record
    /// that names none.
    static func address(in choice: [String: Any]) -> String? {
        guard let data = choice["Configuration"] as? Data, !data.isEmpty,
              let configuration = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any]
        else { return nil }
        let entry = configuration["url"] as? [String: Any] ?? configuration["module"] as? [String: Any]
        guard let relative = entry?["relative"] as? String else { return nil }
        // "file:///a/b" and "file:///a/b/" name the same module.
        return URL(string: relative)?.standardizedFileURL.path ?? relative
    }
}

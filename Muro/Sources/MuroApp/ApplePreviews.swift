import AppKit
import MuroKit

/// The pictures Muro keeps on its own server for Apple's wallpapers that only
/// macOS shows: the 30 still pictures (each side), Sequoia and Macintosh, and
/// eight of Apple's screen savers.
///
/// **Why.** Apple ships only small pictures of these, 214 to 356 pixels
/// across, and its still pictures come as one file of 7 to 139 MB with the
/// dark image at the end, so no small part of Apple's file holds a preview
/// (measured 2026-09-30). So each was made once from Apple's original, on the
/// owner's Mac: a card picture of 1280 by 720 (about 0.2 MB) and a
/// full-screen one of 2880 by 1800 (about 1 MB). The drawn wallpapers and the
/// screen savers were photographed while macOS drew them. Photos, Album
/// Artwork and Message were left out, since a picture of them would show the
/// owner's own photos, music and computer name.
///
/// Anything not on the server, like a screen saver someone installed or a
/// picture a later macOS adds, simply keeps Apple's small picture.
enum ApplePreviews {
    static let base = URL(string: "https://cdn.murowallpaper.com/apple/")!

    /// Screen savers whose picture would be the owner's own content.
    private static let personal: Set<String> = [
        "saver-album-artwork", "saver-ilifeslideshows", "saver-computer-name",
    ]

    static func isHosted(_ assetID: String) -> Bool {
        if assetID.hasPrefix("picture-") || assetID.hasPrefix("drawn-") { return true }
        if assetID.hasPrefix("saver-yours-") { return false }
        return assetID.hasPrefix("saver-") && !personal.contains(assetID)
    }

    static func cardURL(_ assetID: String) -> URL {
        base.appendingPathComponent("thumbs/\(assetID).jpg")
    }

    static func fullURL(_ assetID: String) -> URL {
        base.appendingPathComponent("previews/\(assetID).jpg")
    }

    private static func fullFile(_ assetID: String) -> URL {
        AppleAerialInfo.directory.appendingPathComponent("\(assetID)-full.jpg")
    }

    /// The card picture, saved where the sharp picture of an aerial goes, so
    /// every card finds it the same way. False when there is none to fetch.
    static func fetchCardPicture(assetID: String) async -> Bool {
        guard isHosted(assetID) else { return false }
        let destination = URL(fileURLWithPath: AppleAerialInfo.framePath(assetID: assetID))
        return await fetch(cardURL(assetID), to: destination)
    }

    /// The full-screen picture, fetched once and kept.
    static func fullPicture(assetID: String) async -> NSImage? {
        guard isHosted(assetID) else { return nil }
        let file = fullFile(assetID)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard await fetch(fullURL(assetID), to: file) else { return nil }
        }
        let path = file.path
        return await Task.detached(priority: .userInitiated) {
            ImageCache.load(path: path, maxPixels: 2880)
        }.value
    }

    /// The full-screen pictures fetched so far. Fetched again when opened, so
    /// Clear can take them.
    static func fullPictures() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: AppleAerialInfo.directory.path)) ?? []
        return names.filter { $0.hasSuffix("-full.jpg") }
            .map { AppleAerialInfo.directory.appendingPathComponent($0) }
    }

    private static func fetch(_ url: URL, to destination: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return false }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: destination, options: .atomic)) != nil
    }
}

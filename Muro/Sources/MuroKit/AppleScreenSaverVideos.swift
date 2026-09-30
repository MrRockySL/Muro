import Foundation

/// Apple's eight public screen savers, as Muro's own seamless 4K recordings
/// on its server (owner, 2026-09-30).
///
/// **Why recordings.** macOS draws Apple's screen savers itself, and on the
/// desktop it draws some of them in bursts that lag, where the lock screen
/// and the screen saver are smooth (measured 2026-09-30,
/// `diagnostics/saver-lag-2026-09-30/`). It also keeps one setting for the
/// desktop and the lock screen together. Recorded once as videos, each is a
/// wallpaper Muro plays like an aerial: smooth everywhere, and set on the
/// desktop, the lock screen and the screen saver separately. How they were
/// recorded: `diagnostics/saver-videos-2026-09-30/README.md`.
///
/// Photos, Album Artwork and Message are not here: they show the person's
/// own photos, music and computer name, so there is nothing to record.
///
/// They join the aerial list (`AppleAerials.cachedAerials`) so downloading,
/// deleting, liking and the Library treat them like any aerial, under a
/// category of their own that only the Apple section's Screen Savers page
/// shows. They are never in `catalog.json`, so Explore and every Muro before
/// 6.0 never see them.
public enum AppleScreenSaverVideos {
    /// Their category, shown on the Screen Savers page and never among the
    /// aerials.
    public static let category = "Screen Savers"

    /// How their asset ids begin: `screensaver-<name>`. Not `saver-`, which
    /// names the screen savers macOS runs (`AppleScreenSavers`).
    public static let assetPrefix = "screensaver-"
    public static let idPrefix = AppleAerials.idPrefix + assetPrefix

    /// Muro's own server. The videos are in `savers/`, their six-second 720p
    /// previews in `p720/<asset id>.mov` (made with `generatePreview`, like
    /// Explore's, from a moment that shows what the card promises), and the
    /// pictures beside Muro's other pictures of Apple's wallpapers,
    /// `thumbs/<asset id>.jpg`.
    static let base = URL(string: "https://cdn.murowallpaper.com/apple/")!

    struct Recording {
        let slug: String
        let name: String
        let bytes: Int64
        let seconds: Double
    }

    /// The files as uploaded, so a card has its real size and length before
    /// anything is asked of the server.
    static let recordings: [Recording] = [
        Recording(slug: "arabesque", name: "Arabesque", bytes: 622_108_824, seconds: 154.5),
        Recording(slug: "drift", name: "Drift", bytes: 1_458_219_679, seconds: 155),
        Recording(slug: "flurry", name: "Flurry", bytes: 1_438_649_076, seconds: 266.25),
        Recording(slug: "hello", name: "Hello", bytes: 680_269_097, seconds: 285.75),
        Recording(slug: "monterey", name: "Monterey", bytes: 135_145_856, seconds: 333.35),
        Recording(slug: "shell", name: "Shell", bytes: 883_424_399, seconds: 179.75),
        Recording(slug: "ventura", name: "Ventura", bytes: 333_750_603, seconds: 167.27),
        Recording(slug: "word-of-the-day", name: "Word of the Day", bytes: 913_713_084, seconds: 252.5),
    ]

    public static func found(categoryOrder: Int, cacheDir: URL) -> [AppleAerial] {
        recordings.enumerated().map { index, recording in
            let assetID = assetPrefix + recording.slug
            return AppleAerial(
                id: AppleAerials.muroID(assetID: assetID), assetID: assetID, name: recording.name,
                category: category, categoryOrder: categoryOrder, order: index,
                thumbnailPath: nil,
                previewImageURL: base.appendingPathComponent("thumbs/\(assetID).jpg"),
                videoURL: base.appendingPathComponent("savers/\(recording.slug).mov"),
                applePath: "",
                cachePath: cacheDir.appendingPathComponent(
                    AppleAerials.downloadFileName(assetID: assetID)).path,
                stillMatchesVideo: false,
                knownWidth: 3840, knownHeight: 2160, knownBytes: recording.bytes,
                knownDuration: recording.seconds, knownFPS: 60,
                previewVideoURL: base.appendingPathComponent("p720/\(assetID).mov")
            )
        }
    }
}

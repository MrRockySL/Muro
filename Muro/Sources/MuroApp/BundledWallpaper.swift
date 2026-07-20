import Foundation
import MuroKit

/// The wallpaper shipped inside the app bundle — "Snowfall in Forest" at full
/// 4K (owner decision 2026-07-18: quality over DMG size) — so a fresh install
/// always has exactly one wallpaper playing in the Home hero before anything
/// has been downloaded.
///
/// It shares its id with the real catalog entry, so the moment the user
/// "downloads" it, or downloads anything else, it behaves like any other
/// wallpaper. Downloading it never touches the network: the master is copied
/// straight out of the bundle (see `AppStore.download`).
///
/// Resources are optional on purpose — the bare `.build/release/muro-app`
/// dev binary has no bundle resources, and the app must degrade to the old
/// empty-hero behaviour rather than crash.
enum BundledWallpaper {
    static let id = "c0b0484f-80b9-40f3-bf02-03cd0886ba82"

    static var videoURL: URL? {
        Bundle.main.url(forResource: "BundledWallpaper", withExtension: "mov")
    }

    static var thumbnailURL: URL? {
        Bundle.main.url(forResource: "BundledWallpaper", withExtension: "jpg")
    }

    /// Stand-in catalog entry with file:// URLs into the bundle. Used when
    /// the remote catalog hasn't loaded (first seconds of a fresh install, or
    /// offline forever). Metadata mirrors the published entry exactly.
    static var fallbackEntry: CatalogEntry? {
        guard let videoURL, let thumbnailURL else { return nil }
        return CatalogEntry(
            id: id, title: "Snowfall in Forest", category: "Nature",
            width: 3840, height: 2160, fps: 30, duration: 29.97,
            sizeBytes: 41_792_484, video: videoURL, thumbnail: thumbnailURL
        )
    }
}

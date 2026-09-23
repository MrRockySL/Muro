import AppKit
import SwiftUI

/// Whether the gallery window is out of sight, so the pictures on its cards can
/// be let go while nobody can see them.
///
/// Closing or minimising the gallery only orders it out (see `mainWindow`), so
/// its views, and every picture they held, stayed in memory for as long as Muro
/// ran. Measured on 2026-09-14 with the window hidden: 42 card pictures, each
/// held twice, once decoded and once as Core Animation's copy, about 150 MB of
/// a 267 MB footprint. While the window is hidden the cards now hold nothing,
/// and the pictures come back from memory or disk when it is shown again.
///
/// This only works on a window that is ordered out. A window that is really
/// closed is one SwiftUI stops updating, so its cards never hear the news: 20
/// pictures and their 20 copies were still held 90 seconds after a red button
/// close on 2026-09-23. That is why the red button and Command-W put the
/// gallery away instead of closing it (`makeCloseHideTheGallery`).
///
/// Only the gallery is watched. The menu bar panel and Settings keep their
/// pictures exactly as before.
@MainActor
final class GalleryVisibility: ObservableObject {
    static let shared = GalleryVisibility()

    /// Hidden until the window is seen on screen. At launch SwiftUI builds the
    /// gallery and the launch suppressor puts it away in the same moment, so it
    /// is never visible and no notification ever says so. Starting from "shown",
    /// its cards loaded every picture into a window nobody had opened: 19 held
    /// right after a launch on 2026-09-23. A window that really appears always
    /// reports it, and that is what lets them load.
    @Published private(set) var isHidden = true

    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow,
                          window.title == MuroWindow.gallery
                    else { return }
                    GalleryVisibility.shared.update(for: window)
                }
            })
        }
        if let window = mainWindow { update(for: window) }
    }

    private func update(for window: NSWindow) {
        // Covered by another window is not hidden. `isVisible` stays true then,
        // and the cards keep their pictures so switching back is instant.
        let hidden = !window.isVisible || window.isMiniaturized
        guard hidden != isHidden else { return }
        isHidden = hidden
        // The shared cache keeps decoded pictures too, up to 64 MB, and nothing
        // in a hidden gallery needs them.
        if hidden { ImageCache.removeAll() }
    }

    /// Asks the window itself, for a card about to load a picture or keep one
    /// it has just decoded. Notifications alone left two gaps: a gallery put
    /// away the moment it was shown, as at launch, and a picture that finished
    /// decoding just after the window went away, after the cache was emptied.
    func isHiddenNow() -> Bool {
        if let window = mainWindow { update(for: window) }
        return isHidden
    }
}

private struct GalleryHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InGalleryKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the gallery window while that window is hidden. False
    /// everywhere else, the menu bar panel and Settings included.
    var galleryHidden: Bool {
        get { self[GalleryHiddenKey.self] }
        set { self[GalleryHiddenKey.self] = newValue }
    }

    /// True for everything inside the gallery window, shown or hidden. Its
    /// cards check the window before they load or keep a picture; the menu bar
    /// panel and Settings keep theirs.
    var inGallery: Bool {
        get { self[InGalleryKey.self] }
        set { self[InGalleryKey.self] = newValue }
    }
}

/// Hands the gallery's visibility to everything inside it.
private struct GalleryHiddenModifier: ViewModifier {
    @ObservedObject private var visibility = GalleryVisibility.shared

    func body(content: Content) -> some View {
        content
            .environment(\.galleryHidden, visibility.isHidden)
            .environment(\.inGallery, true)
    }
}

extension View {
    /// Applied once, to the gallery window's root view.
    func tracksGalleryVisibility() -> some View {
        modifier(GalleryHiddenModifier())
    }
}

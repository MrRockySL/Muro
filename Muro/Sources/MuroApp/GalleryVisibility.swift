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
/// Only the gallery is watched. The menu bar panel and Settings keep their
/// pictures exactly as before.
@MainActor
final class GalleryVisibility: ObservableObject {
    static let shared = GalleryVisibility()

    @Published private(set) var isHidden = false

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
}

private struct GalleryHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the gallery window while that window is hidden. False
    /// everywhere else, the menu bar panel and Settings included.
    var galleryHidden: Bool {
        get { self[GalleryHiddenKey.self] }
        set { self[GalleryHiddenKey.self] = newValue }
    }
}

/// Hands the gallery's visibility to everything inside it.
private struct GalleryHiddenModifier: ViewModifier {
    @ObservedObject private var visibility = GalleryVisibility.shared

    func body(content: Content) -> some View {
        content.environment(\.galleryHidden, visibility.isHidden)
    }
}

extension View {
    /// Applied once, to the gallery window's root view.
    func tracksGalleryVisibility() -> some View {
        modifier(GalleryHiddenModifier())
    }
}

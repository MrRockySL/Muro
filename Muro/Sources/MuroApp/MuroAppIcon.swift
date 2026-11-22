import SwiftUI

/// Muro's app icon as it is drawn inside the app: the Glass Moon (owner,
/// 2026-10-03), in the version that matches the look Muro is in: the light
/// one on Light, the dark one on Dark. On System that is the Mac's look.
///
/// The icon macOS draws in the Dock and Finder is separate: macOS picks it
/// from `Icon/MuroIcon.icon` by its own Icon and widget style, the way it does
/// for every app.
struct MuroAppIcon: View {
    var body: some View {
        if let picture = Self.picture(for: Appearance.shared.look) {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            // A build run straight from the terminal has no Resources folder.
            MuroMark()
        }
    }

    private static var pictures: [AppearanceLook: NSImage] = [:]

    /// Rendered by Apple's own icon renderer from the same artwork as the Dock
    /// icon, so the shape and the edge match it exactly. 256 pixels, enough
    /// for the largest place it is shown (Settings, 64 points).
    private static func picture(for look: AppearanceLook) -> NSImage? {
        if let hit = pictures[look] { return hit }
        let name: String
        switch look {
        case .light: name = "MuroIcon-Light"
        case .dark: name = "MuroIcon-Dark"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let picture = NSImage(contentsOf: url) else { return nil }
        pictures[look] = picture
        return picture
    }
}

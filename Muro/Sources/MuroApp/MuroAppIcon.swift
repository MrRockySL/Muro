import SwiftUI

/// Muro's app icon as it is drawn inside the app: the Glass Moon (owner,
/// 2026-10-03), in the version that matches Muro's own Appearance setting.
/// Default shows the navy icon, Light the light one, Dark the dark one.
///
/// The Mac's own appearance never changes this. That picks only the icon
/// macOS draws in the Dock and Finder, from `Icon/MuroIcon.icon`, the way it
/// does for every app.
struct MuroAppIcon: View {
    var body: some View {
        if let picture = Self.picture(for: Appearance.shared.mode) {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            // A build run straight from the terminal has no Resources folder.
            MuroMark()
        }
    }

    private static var pictures: [AppearanceMode: NSImage] = [:]

    /// Rendered by Apple's own icon renderer from the same artwork as the Dock
    /// icon, so the shape and the edge match it exactly. 256 pixels, enough
    /// for the largest place it is shown (Settings, 64 points).
    private static func picture(for mode: AppearanceMode) -> NSImage? {
        if let hit = pictures[mode] { return hit }
        let name: String
        switch mode {
        case .standard: name = "MuroIcon-Default"
        case .light: name = "MuroIcon-Light"
        case .dark: name = "MuroIcon-Dark"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let picture = NSImage(contentsOf: url) else { return nil }
        pictures[mode] = picture
        return picture
    }
}

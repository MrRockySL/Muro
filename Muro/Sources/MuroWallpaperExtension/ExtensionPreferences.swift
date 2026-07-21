import Foundation

/// Preferences are written by the main Muro app into the extension container.
/// Lock-screen playback is intentionally the safe default: the existing Muro
/// window engine remains the only component allowed to animate the desktop.
final class ExtensionPreferences: @unchecked Sendable {
    static let shared = ExtensionPreferences()

    private struct FileContents: Codable {
        var alwaysPauseDesktop: Bool
    }

    private let lock = NSLock()
    private var pauseDesktop = true

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("muro-prefs.json")
    }

    private init() {
        reload()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in ExtensionPreferences.shared.reloadAndApply() },
            "com.mrrockysl.muro.wallpaper.preferences-changed" as CFString,
            nil,
            .deliverImmediately
        )
    }

    var alwaysPauseDesktop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pauseDesktop
    }

    func reloadAndApply() {
        reload()
        RendererState.shared.applyCurrentPlaybackPolicy()
    }

    private func reload() {
        guard let data = try? Data(contentsOf: Self.url),
              let contents = try? JSONDecoder().decode(FileContents.self, from: data)
        else { return }
        lock.lock()
        pauseDesktop = contents.alwaysPauseDesktop
        lock.unlock()
    }
}

final class ExtensionPlaybackCoordinator: @unchecked Sendable {
    static let shared = ExtensionPlaybackCoordinator()
    private var tokens: [NSObjectProtocol] = []

    private init() {
        _ = ExtensionPreferences.shared
        let center = DistributedNotificationCenter.default()
        tokens.append(center.addObserver(
            forName: .init("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { _ in
            RendererState.shared.setPresentation(mode: "locked", activity: "active")
        })
        tokens.append(center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { _ in
            RendererState.shared.setPresentation(mode: "default", activity: "active")
        })
    }
}

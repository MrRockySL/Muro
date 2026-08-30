import AppKit
import MuroKit

/// Keeps the real macOS desktop picture in step with the wallpaper Muro is
/// playing, so the menu bar tints itself from the right image.
///
/// **Why this exists.** On macOS 15 and earlier the menu bar has a real
/// background and takes its colour from the desktop picture. Muro never sets
/// the desktop picture: it plays video in its own borderless window seated
/// just under the desktop icons, and macOS knows nothing about that window. So
/// the menu bar was tinted by whatever still image the user had before
/// installing Muro, while a completely different video played underneath it.
/// Reported on r/MacOS on 2026-08-30 and answered with a promise to fix it.
///
/// **Why it is gated, and why that is not just tidiness.** macOS 26 made the
/// menu bar fully transparent, so on 26 and later there is no tint to get
/// wrong and nothing here would help. It is switched off there for a second
/// reason that matters more: `LockScreenService` writes the Apple `Desktop`
/// wallpaper surface, and `setDesktopImageURL` writes that same surface by a
/// different route, so the two could fight and knock each other out. The lock
/// screen exists only on 26 and later and this only runs on 14 and 15, so the
/// two can never be live on the same Mac. The version gate is the design.
///
/// Everything it writes outside Muro's own folders is one thing, the desktop
/// picture, and the user's own picture is read and kept before it is touched
/// so it can be put back. `SECURITY.md` discloses it.
@MainActor
final class DesktopTintService {
    /// Where the user's own desktop picture is remembered, per display, so a
    /// remove or an uninstall can put back exactly what was there.
    private struct State: Codable {
        var originals: [String: String] = [:]
    }

    private let root: URL
    private var state = State()

    /// Set `defaults write com.mrrockysl.muro simulateLegacyMacOS -bool YES`
    /// to exercise this on a Mac that does not need it. The bug is invisible
    /// on 26 and later, which is every machine Muro is developed on, so
    /// without this the code could only ever be read and never run.
    private static var simulatesLegacy: Bool {
        UserDefaults.standard.bool(forKey: "simulateLegacyMacOS")
    }

    /// True only where the menu bar actually takes a colour from the desktop.
    static var isNeeded: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
            || simulatesLegacy
    }
    var isNeeded: Bool { Self.isNeeded }

    private var stillsDir: URL { root.appendingPathComponent("DesktopStills", isDirectory: true) }
    private var stateURL: URL { root.appendingPathComponent("desktop-tint.json") }

    init(root: URL) {
        self.root = root
        load()
    }

    // MARK: - The one entry point

    /// Points every screen's desktop picture at a still of whatever Muro plays
    /// there, and puts the user's own picture back on screens Muro has left.
    ///
    /// Written as a reconcile rather than a pair of apply/remove calls for the
    /// same reason `EngineController` is: displays come and go, and an apply
    /// to "all displays" has to reach a monitor that was plugged in afterwards.
    func reconcile(config: EngineConfig, manifest: LibraryManifest) {
        guard isNeeded else { return }
        for screen in NSScreen.screens {
            guard let uuid = displayUUID(for: screen) else { continue }
            // Never take a screen the lock-screen extension is driving. The
            // version gate already means these two cannot both be live on one
            // Mac, but that is a fact about macOS versions, and this is a fact
            // about the file actually in front of us. Depending on the second
            // is what keeps the simulation flag from wrecking a real setup.
            if let current = NSWorkspace.shared.desktopImageURL(for: screen),
               isLockScreenExtensionOwned(current) { continue }
            guard
                let assignment = config.assignment(forDisplayUUID: uuid),
                let entry = manifest.wallpapers.first(where: { $0.id == assignment.wallpaperID }),
                let still = still(for: entry, mode: assignment.mode)
            else {
                restore(screen: screen, uuid: uuid)
                continue
            }
            rememberOriginal(of: screen, uuid: uuid)
            try? NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: [:])
        }
        pruneStills(manifest: manifest)
    }

    /// Drops stills for wallpapers that have left the library.
    ///
    /// Deliberately not folded into `LibraryWriter.sweepOrphans`: that decides
    /// what is orphaned by matching the manifest's own relative file paths,
    /// and a still is not one of a wallpaper's files, so every still would
    /// read as unreferenced and be deleted on the first sweep. Ownership of
    /// this folder stays here, where what belongs in it is known.
    private func pruneStills(manifest: LibraryManifest) {
        let live = Set(manifest.wallpapers.map(\.id))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stillsDir.path)
        else { return }
        for name in names where !name.hasPrefix(".") {
            let id = (name as NSString).deletingPathExtension
            guard !live.contains(id) else { continue }
            try? FileManager.default.removeItem(at: stillsDir.appendingPathComponent(name))
        }
    }

    /// Puts every remembered picture back. For removing the last wallpaper,
    /// clearing the library, or anything else that should leave the Mac as it
    /// was found.
    func restoreAll() {
        for screen in NSScreen.screens {
            guard let uuid = displayUUID(for: screen) else { continue }
            restore(screen: screen, uuid: uuid)
        }
        // A display that is unplugged right now still has a picture owed to
        // it. Nothing can be written to a screen that is not there, so the
        // record is kept rather than dropped.
        save()
    }

    // MARK: - The still

    /// A frame of the wallpaper, big enough to be a desktop picture in its own
    /// right. The library thumbnail would have been free but it is capped at
    /// 1280, and this is not only a tint source: it is what the user actually
    /// sees for the moment before Muro's window appears at login.
    private func still(for entry: WallpaperEntry, mode: String) -> URL? {
        let destination = stillsDir.appendingPathComponent("\(entry.id).jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let video = resolveVideoURL(entry: entry, mode: mode, root: root)
        guard FileManager.default.fileExists(atPath: video.path) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: stillsDir, withIntermediateDirectories: true
            )
            try generateThumbnail(
                video: video, destination: destination, at: 1.0, maxDimension: 3840
            )
            return destination
        } catch {
            // A tint is a nicety. Failing to make one must never stop a
            // wallpaper being applied.
            return nil
        }
    }

    private func isOurs(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(stillsDir.standardizedFileURL.path)
    }

    /// A wallpaper staged by Muro's own lock-screen extension. Recording one
    /// of these as "the user's own picture" would hand the lock screen's file
    /// back as a desktop still later, which is not a wallpaper the user chose.
    private func isLockScreenExtensionOwned(_ url: URL) -> Bool {
        url.path.contains("com.mrrockysl.muro.wallpaper-extension")
    }

    // MARK: - The user's own picture

    private func rememberOriginal(of screen: NSScreen, uuid: String) {
        guard state.originals[uuid] == nil else { return }
        guard let current = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        // Never record one of our own stills as the thing to restore: that
        // would make the first overwrite permanent.
        guard !isOurs(current), !isLockScreenExtensionOwned(current) else { return }
        state.originals[uuid] = current.path
        save()
    }

    private func restore(screen: NSScreen, uuid: String) {
        guard let path = state.originals[uuid] else { return }
        let current = NSWorkspace.shared.desktopImageURL(for: screen)
        // Only undo our own change. If the user picked a new picture in System
        // Settings in the meantime, that is now their choice and stands.
        if let current, isOurs(current) {
            try? NSWorkspace.shared.setDesktopImageURL(
                URL(fileURLWithPath: path), for: screen, options: [:]
            )
        }
        state.originals[uuid] = nil
        save()
    }

    // MARK: - State

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder().decode(State.self, from: data)
        else { return }
        state = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        try? data.write(to: stateURL, options: .atomic)
    }
}

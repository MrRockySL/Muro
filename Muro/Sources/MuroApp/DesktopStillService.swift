import AppKit
import MuroKit

/// Keeps the real macOS desktop picture in step with the wallpaper Muro is
/// playing, so there is always a still of the right wallpaper underneath the
/// video.
///
/// **Why this exists.** Muro never told macOS anything about what it plays.
/// The video lives in a borderless window of Muro's own, seated just under the
/// desktop icons, and the desktop picture underneath it stayed whatever it had
/// been. Quit Muro, or let it be killed, and that window goes with it: the
/// user is left looking at a picture they replaced weeks ago, or at nothing.
/// On macOS 15 and earlier it also cost the menu bar its colour, because the
/// menu bar takes its tint from the desktop picture and never saw the video.
/// That tint report, on r/MacOS on 2026-08-30, is where this started.
///
/// So every apply, every playlist step and every automation step writes a
/// still frame of the wallpaper as the actual desktop picture. Muro's video
/// covers it while Muro runs, and when Muro is not running the same image is
/// still there. It used to be switched off on macOS 26 and later, which is why
/// quitting Muro on a modern Mac left a black desktop.
///
/// **The one screen it will not touch.** macOS keeps a single wallpaper per
/// display and a lock-screen apply puts Muro's extension on it. Writing a
/// desktop picture there would throw the lock screen away, so those screens
/// are left alone and the extension is handed the still instead, through
/// `LockScreenService.publishDesktopStill`, to draw itself.
///
/// Everything it writes outside Muro's own folders is one thing, the desktop
/// picture, and the user's own picture is read and kept before it is touched
/// so it can be put back. `SECURITY.md` discloses it.
@MainActor
final class DesktopStillService {
    /// Where the user's own desktop picture is remembered, per display, so a
    /// remove or an uninstall can put back exactly what was there.
    private struct State: Codable {
        var originals: [String: String] = [:]
    }

    private let root: URL
    private var state = State()

    /// Bumped on every reconcile. A still that finishes generating after a
    /// newer wallpaper has been applied belongs to a question nobody is asking
    /// any more, and must not overwrite the answer.
    private var generation = 0

    /// The last thing asked for, so the tail of a slow generation can finish
    /// the job without carrying non-Sendable state across the hop.
    private var pending: (
        config: EngineConfig,
        manifest: LibraryManifest,
        lockScreenDisplays: Set<String>
    )?

    private var stillsDir: URL { root.appendingPathComponent("DesktopStills", isDirectory: true) }

    /// Named after the menu bar tint this started life as, and left that way
    /// deliberately: renaming the file would orphan every existing install's
    /// record of the picture it owes the user back.
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
    ///
    /// A still that already exists is set in this same turn of the run loop,
    /// so a playlist step swaps the picture at the moment it swaps the video.
    /// Only the first time a wallpaper is ever shown is there a frame to
    /// decode, and that happens off the main thread rather than holding the
    /// interface while a 4K frame is pulled out of the file.
    func reconcile(
        config: EngineConfig,
        manifest: LibraryManifest,
        lockScreenDisplays: Set<String>
    ) {
        generation += 1
        pending = (config, manifest, lockScreenDisplays)
        let token = generation

        let missing = applyCachedStills(
            config: config, manifest: manifest, lockScreenDisplays: lockScreenDisplays
        )
        pruneStills(manifest: manifest)
        guard !missing.isEmpty else { return }

        let stillsDir = self.stillsDir
        Task.detached(priority: .userInitiated) {
            for item in missing {
                Self.generateStill(id: item.id, video: item.video, into: stillsDir)
            }
            await MainActor.run {
                guard token == self.generation, let pending = self.pending else { return }
                _ = self.applyCachedStills(
                    config: pending.config,
                    manifest: pending.manifest,
                    lockScreenDisplays: pending.lockScreenDisplays
                )
            }
        }
    }

    /// Sets every still that is already on disk and reports the ones that are
    /// not, so the caller can go and make them.
    private func applyCachedStills(
        config: EngineConfig,
        manifest: LibraryManifest,
        lockScreenDisplays: Set<String>
    ) -> [(id: String, video: URL)] {
        var missing: [(id: String, video: URL)] = []
        var stillForExtension: URL?
        var anyWallpaper = false

        for screen in NSScreen.screens {
            guard let uuid = displayUUID(for: screen) else { continue }
            guard
                let assignment = config.assignment(forDisplayUUID: uuid),
                let entry = manifest.wallpapers.first(where: { $0.id == assignment.wallpaperID })
            else {
                restore(screen: screen, uuid: uuid)
                continue
            }
            anyWallpaper = true
            let still = stillURL(for: entry.id)
            guard FileManager.default.fileExists(atPath: still.path) else {
                let video = resolveVideoURL(entry: entry, mode: assignment.mode, root: root)
                if FileManager.default.fileExists(atPath: video.path) {
                    missing.append((entry.id, video))
                }
                continue
            }
            if stillForExtension == nil || screen == NSScreen.screens.first {
                stillForExtension = still
            }
            set(still, on: screen, uuid: uuid, isLockScreenOwned: lockScreenDisplays.contains(uuid))
        }

        // The extension draws one picture for the whole Mac, so it is given
        // the main display's. Muro's own window is per screen and still shows
        // the right video everywhere; this is only the frozen fallback for
        // when Muro is not running.
        //
        // Nothing is taken away while a still is only late. The first time a
        // wallpaper is applied its still has to be decoded out of the video,
        // and this ran before that finished with nothing to hand over, so
        // choosing a wallpaper Muro had not shown before pulled the picture
        // out from under the desktop for as long as the decode took. Clearing
        // is for a Mac with no Muro wallpaper at all.
        if stillForExtension != nil || !anyWallpaper {
            LockScreenService.publishDesktopStill(stillForExtension)
        }
        return missing
    }

    private func set(_ still: URL, on screen: NSScreen, uuid: String, isLockScreenOwned: Bool) {
        // Never take a screen the lock-screen extension is driving. macOS
        // gives one wallpaper slot per display, the extension is sitting on
        // it, and writing a picture here would throw the lock screen away.
        // Muro's own record is what answers that, because asking macOS does
        // not reliably name an extension as the owner. The path check stays
        // as a second line, for a wallpaper picked in System Settings that
        // Muro never recorded.
        if isLockScreenOwned { return }
        if let current = NSWorkspace.shared.desktopImageURL(for: screen),
           isLockScreenExtensionOwned(current) { return }
        // Already the picture on this screen. Writing it again is a wasted
        // round trip through the wallpaper agent on every playlist step.
        if NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == still.standardizedFileURL {
            return
        }
        rememberOriginal(of: screen, uuid: uuid)
        try? NSWorkspace.shared.setDesktopImageURL(still, for: screen, options: [:])
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
        generation += 1
        pending = nil
        for screen in NSScreen.screens {
            guard let uuid = displayUUID(for: screen) else { continue }
            restore(screen: screen, uuid: uuid)
        }
        LockScreenService.publishDesktopStill(nil)
        // A display that is unplugged right now still has a picture owed to
        // it. Nothing can be written to a screen that is not there, so the
        // record is kept rather than dropped.
        save()
    }

    // MARK: - The still

    private func stillURL(for id: String) -> URL {
        stillsDir.appendingPathComponent("\(id).jpg")
    }

    /// A frame of the wallpaper, big enough to be a desktop picture in its own
    /// right. The library thumbnail would have been free but it is capped at
    /// 1280, and this is not only a tint source: it is what the user actually
    /// sees whenever Muro is not the thing on screen.
    private nonisolated static func generateStill(id: String, video: URL, into directory: URL) {
        let destination = directory.appendingPathComponent("\(id).jpg")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try generateThumbnail(
                video: video, destination: destination, at: 1.0, maxDimension: 3840
            )
        } catch {
            // A still is a fallback. Failing to make one must never stop a
            // wallpaper being applied.
        }
    }

    private func isOurs(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(stillsDir.standardizedFileURL.path)
    }

    /// A wallpaper staged by Muro's own lock-screen extension. Recording one
    /// of these as "the user's own picture" would hand the lock screen's file
    /// back as a desktop still later, which is not a wallpaper the user chose.
    private func isLockScreenExtensionOwned(_ url: URL) -> Bool {
        url.path.contains(LockScreenService.extensionBundleID)
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

import AppKit
import MuroKit

/// Puts Apple's wallpapers that only macOS can show into macOS's own
/// wallpaper store: the still pictures and the ones drawn by code (owner,
/// 2026-09-30: "Show all the 35").
///
/// **What macOS allows.** macOS keeps one wallpaper per display for the
/// desktop and the lock screen together (the lock screen is the desktop in
/// locked mode, proven 2026-09-28), and one for the screen saver. So:
///
/// - **Desktop** puts it in the desktop role and takes Muro's own video off
///   that display, so macOS's picture is what shows. The lock screen shows it
///   too; macOS has no way to keep them apart.
/// - **Lock screen** puts it in the desktop role and leaves Muro's video
///   playing on the desktop over it, so only the lock screen shows it.
/// - **Screen saver** puts it in the screen saver role.
///
/// Whatever Muro held in a role it writes (its own lock screen or screen
/// saver) is taken back first through `LockScreenService`, so Muro's record
/// of its own wallpapers stays true.
///
/// **Its own record, checked against macOS.** Which of these Muro set, and
/// where, is kept in `macos-wallpapers.json`. Anything else that writes the
/// store (Muro's own lock screen, the desktop still, System Settings) can
/// replace one, so every entry is checked against the store again whenever
/// the store has changed, and an entry macOS no longer shows is dropped.
@MainActor
final class MacOSWallpaperService {
    struct Placement: Codable, Equatable {
        var id: String
        var provider: String
        var configuration: Data
    }

    struct Record: Codable, Equatable {
        /// The desktop role, per target key: "all" or a display's UUID.
        var desktop: [String: Placement] = [:]
        /// The screen saver, one for the whole Mac.
        var screenSaver: Placement?
    }

    private let root: URL
    private var record = Record()
    private var checkedAgainst: Date?

    init(root: URL) {
        self.root = root
        if let data = try? Data(contentsOf: recordURL),
           let decoded = try? JSONDecoder().decode(Record.self, from: data) {
            record = decoded
        }
    }

    private var recordURL: URL { root.appendingPathComponent("macos-wallpapers.json") }

    // MARK: - What is showing

    /// Where this wallpaper is in the desktop role.
    func desktopTargets(of id: String) -> [String] {
        current.desktop.filter { $0.value.id == id }.map(\.key)
    }

    func isScreenSaver(_ id: String) -> Bool { current.screenSaver?.id == id }

    /// Every one of these macOS is showing now. Their files must stay.
    var shownIDs: Set<String> {
        let record = current
        return Set(record.desktop.values.map(\.id) + [record.screenSaver?.id].compactMap { $0 })
    }

    /// Whether this display's desktop role holds one of these. The desktop
    /// still must leave such a display alone, or it would write Muro's still
    /// over the picture.
    func holdsDesktop(displayUUID: String) -> Bool {
        let desktop = current.desktop
        return desktop[displayUUID] != nil || desktop["all"] != nil
    }

    func showsOnDesktopRole(_ id: String, displayUUID: String) -> Bool {
        let desktop = current.desktop
        return (desktop[displayUUID] ?? desktop["all"])?.id == id
    }

    /// The record, with anything macOS no longer shows dropped. Re-checked
    /// only when the store file has changed since the last check.
    private var current: Record {
        let modified = Self.storeModified
        guard modified != checkedAgainst else { return record }
        checkedAgainst = modified
        guard let store = Self.load(Self.storeURLs[0]) else { return record }
        var checked = record
        checked.desktop = checked.desktop.filter { key, placement in
            Self.store(store, shows: placement, targetKey: key, surface: .desktop)
        }
        if let saver = checked.screenSaver,
           !Self.store(store, shows: saver, targetKey: "all", surface: .screenSaver) {
            checked.screenSaver = nil
        }
        if checked != record {
            record = checked
            save()
        }
        return record
    }

    // MARK: - Writing

    /// Writes `choice` into one role for one target. Nothing is shown until
    /// WallpaperAgent reads the store again: the caller restarts it once,
    /// after every write it has to make (`restartWallpaperAgent`), because
    /// each restart blanks the screens for a moment.
    ///
    /// The record is written first, so anything that asks while the store is
    /// being written, the desktop still above all, already knows this place
    /// is taken.
    func show(
        _ choice: [String: Any],
        id: String,
        surface: AppleWallpaperStore.Surface,
        targetKey: String
    ) async throws {
        let placement = Placement(
            id: id,
            provider: choice["Provider"] as? String ?? "",
            configuration: choice["Configuration"] as? Data ?? Data()
        )
        switch surface {
        case .desktop:
            if targetKey == "all" { record.desktop = [:] }
            record.desktop[targetKey] = placement
        case .screenSaver:
            record.screenSaver = placement
        }
        save()
        try await Task.detached(priority: .userInitiated) {
            try Self.write(choice, targetKey: targetKey, surface: surface)
        }.value
        checkedAgainst = Self.storeModified
    }

    /// Makes macOS read the store again, so what was written shows.
    func restartWallpaperAgent() async {
        await Task.detached(priority: .userInitiated) { Self.restartWallpaperAgent() }.value
    }

    /// Waits for `Index.plist`, the store macOS reads, to hold `choice` in
    /// this place, and says whether it did. WallpaperAgent writes the store
    /// from its own memory when it starts and when anything changes, and a
    /// write of Muro's that lands in between is simply lost; the lock screen
    /// has the same check for the same reason.
    func confirm(
        _ choice: [String: Any], surface: AppleWallpaperStore.Surface, targetKey: String
    ) async -> Bool {
        let placement = Placement(
            id: "", provider: choice["Provider"] as? String ?? "",
            configuration: choice["Configuration"] as? Data ?? Data())
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let held = await Task.detached(priority: .userInitiated) {
                Self.load(Self.storeURLs[0]).map {
                    Self.store($0, shows: placement, targetKey: targetKey, surface: surface)
                } ?? false
            }.value
            if held { return true }
        }
        return false
    }

    /// Writes again, after `confirm` found the first write lost.
    func rewrite(
        _ choice: [String: Any], surface: AppleWallpaperStore.Surface, targetKey: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.write(choice, targetKey: targetKey, surface: surface)
            Self.restartWallpaperAgent()
        }.value
        checkedAgainst = nil
    }

    private nonisolated static var storeModified: Date? {
        (try? storeURLs[0].resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// Takes one back off, leaving macOS's own default wallpaper in its place.
    func remove(id: String, surface: AppleWallpaperStore.Surface, targetKey: String) async throws {
        switch surface {
        case .desktop:
            let keys = targetKey == "all"
                ? current.desktop.filter { $0.value.id == id }.map(\.key)
                : [targetKey]
            for key in keys {
                try await Task.detached(priority: .userInitiated) {
                    try Self.write(MacOSWallpaperChoice.macOSDefault, targetKey: key, surface: .desktop)
                }.value
                record.desktop[key] = nil
            }
        case .screenSaver:
            try await Task.detached(priority: .userInitiated) {
                try Self.write(MacOSWallpaperChoice.macOSDefault, targetKey: "all", surface: .screenSaver)
            }.value
            record.screenSaver = nil
        }
        await Task.detached(priority: .userInitiated) { Self.restartWallpaperAgent() }.value
        checkedAgainst = nil
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: recordURL, options: .atomic)
    }

    // MARK: - Apple's store

    private nonisolated static var storeURLs: [URL] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store", isDirectory: true)
        return ["Index.plist", "Index2.plist"].map { directory.appendingPathComponent($0) }
    }

    private nonisolated static func load(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private nonisolated static func store(
        _ store: Any, shows placement: Placement, targetKey: String, surface: AppleWallpaperStore.Surface
    ) -> Bool {
        let choice: [String: Any] = ["Provider": placement.provider, "Configuration": placement.configuration]
        var found = false
        AppleWallpaperStore.forEachNode(in: store) { path, node in
            guard !found,
                  let name = AppleWallpaperStore.surfaceName(of: node, for: surface),
                  let occupant = node[name] as? [String: Any],
                  AppleWallpaperStore.surfaceBelongsToTarget(path + [name], targetKey: targetKey)
            else { return }
            if MacOSWallpaperChoice.surface(occupant, shows: choice) { found = true }
        }
        return found
    }

    /// The same write Muro's lock screen makes, with another choice in it:
    /// every node that serves this target, in both store files, twice with a
    /// pause because WallpaperAgent may rewrite the file in between.
    private nonisolated static func write(
        _ choice: [String: Any], targetKey: String, surface: AppleWallpaperStore.Surface
    ) throws {
        let manager = FileManager.default
        guard let primary = storeURLs.first, manager.fileExists(atPath: primary.path) else {
            throw LockScreenServiceError.wallpaperStoreMissing
        }
        for url in storeURLs where manager.fileExists(atPath: url.path) {
            var store = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: url), format: nil)
            AppleWallpaperStore.applyChoiceCreatingNode(
                choice,
                to: &store,
                targetKey: targetKey,
                surface: surface,
                desktopFallback: defaultSurface(),
                idleFallback: defaultSurface()
            )
            let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
            Thread.sleep(forTimeInterval: 0.25)
            try data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func defaultSurface() -> [String: Any] {
        [
            "Content": ["Choices": [MacOSWallpaperChoice.macOSDefault], "Shuffle": "$null"],
            "LastSet": Date(),
            "LastUse": Date(),
        ]
    }

    private nonisolated static func restartWallpaperAgent() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["WallpaperAgent"]
        try? kill.run()
        kill.waitUntilExit()
    }
}

// MARK: - The app's side

extension AppStore {

    /// One of Apple's pictures or drawn wallpapers, by its card's id.
    func macOSOnlyAerial(id: String) -> AppleAerial? {
        guard AppleAerials.isMacOSOnly(id) else { return nil }
        if id.hasPrefix(AppleScreenSavers.idPrefix) {
            return AppleScreenSavers.cached().first { $0.id == id }
        }
        return AppleAerials.cachedAerials(libraryRoot: root)?.first { $0.id == id }
    }

    /// What `setWallpaper` does for one of these. See `MacOSWallpaperService`
    /// for what each place means here.
    func showThroughMacOS(_ item: WallpaperItem, target: ApplyTarget, surface: ApplySurface) {
        guard let aerial = macOSOnlyAerial(id: item.id) else { return }
        guard lockScreenAvailable else {
            applyError = LockScreenServiceError.requiresTahoe.localizedDescription
            return
        }
        Task {
            do {
                if aerial.kind == .picture, !ApplePictures.isReady(aerial, libraryRoot: root) {
                    try await downloadApplePicture(aerial)
                }
                guard let choice = macOSChoice(for: aerial) else { return }
                applyingLockScreen = true
                defer { applyingLockScreen = false }
                let targetKey = Self.macOSTargetKey(target)
                let desktopRole = surface.coversDesktop || surface.coversLockScreen
                // macOS cannot show a still picture as the screen saver: it
                // refuses the record ("No files include in the descriptor").
                let saverRole = surface.coversScreenSaver && aerial.kind != .picture

                // 1. Every write first. What Muro held in these places is
                //    replaced here, so handing them back below restores
                //    nothing over them. Taking Muro's video off the desktop
                //    puts the user's own picture back through macOS, which
                //    then writes the store itself, so that goes first and is
                //    given a moment to land before Muro writes over it.
                if surface.coversDesktop, vacateDesktop(target) {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                if desktopRole {
                    try await macOSWallpapers.show(
                        choice, id: aerial.id, surface: .desktop, targetKey: targetKey)
                }
                if saverRole {
                    try await macOSWallpapers.show(
                        choice, id: aerial.id, surface: .screenSaver, targetKey: "all")
                }

                // 2. One restart. Handing Muro's own lock screen or screen
                //    saver back ends with one, otherwise it is made here.
                var handBack: [AppleWallpaperStore.Surface] = []
                if desktopRole, lockScreenHoldsDesktopRole(target) { handBack.append(.desktop) }
                if saverRole, screenSaverWallpaperID != nil { handBack.append(.screenSaver) }
                if handBack.isEmpty {
                    await macOSWallpapers.restartWallpaperAgent()
                } else {
                    try await removeLockScreenForMacOS(target: target, surfaces: handBack)
                }

                // 3. Make sure macOS kept it; once more if it did not.
                if desktopRole,
                   !(await macOSWallpapers.confirm(choice, surface: .desktop, targetKey: targetKey)) {
                    try await macOSWallpapers.rewrite(choice, surface: .desktop, targetKey: targetKey)
                }
                if saverRole,
                   !(await macOSWallpapers.confirm(choice, surface: .screenSaver, targetKey: "all")) {
                    try await macOSWallpapers.rewrite(choice, surface: .screenSaver, targetKey: "all")
                }
                pushRecentMacOS(aerial.id)
                objectWillChange.send()
            } catch {
                applyError = error.localizedDescription
            }
        }
    }

    /// What `removeWallpaper` does for one of these: macOS's own default
    /// wallpaper goes back in its place.
    func removeFromMacOS(_ item: WallpaperItem, target: ApplyTarget, surface: ApplySurface) {
        Task {
            do {
                if surface.coversDesktop || surface.coversLockScreen {
                    try await macOSWallpapers.remove(
                        id: item.id, surface: .desktop, targetKey: Self.macOSTargetKey(target))
                }
                if surface.coversScreenSaver, macOSWallpapers.isScreenSaver(item.id) {
                    try await macOSWallpapers.remove(id: item.id, surface: .screenSaver, targetKey: "all")
                }
                objectWillChange.send()
            } catch {
                applyError = error.localizedDescription
            }
        }
    }

    /// Mirrors `isApplied` for the wallpapers macOS shows.
    func isAppliedThroughMacOS(_ item: WallpaperItem, surface: ApplySurface, target: ApplyTarget) -> Bool {
        let uuids: [String]
        switch target {
        case .all: uuids = displays.map(\.id)
        case .display(let uuid): uuids = [uuid]
        }
        guard !uuids.isEmpty else { return false }
        let lock = uuids.allSatisfy { macOSWallpapers.showsOnDesktopRole(item.id, displayUUID: $0) }
        // On the desktop only where Muro's own video has stepped aside.
        let desktop = lock && uuids.allSatisfy { config.assignment(forDisplayUUID: $0) == nil }
        let saver = macOSWallpapers.isScreenSaver(item.id)
        switch surface {
        case .desktop: return desktop
        case .lockscreen: return lock
        case .screensaver: return saver
        case .all: return desktop && lock && saver
        }
    }

    /// Mirrors `appliedPlaces` for the wallpapers macOS shows, so their cards
    /// carry the same chips.
    func placesThroughMacOS(for id: String) -> [AppliedPlace] {
        var out: [AppliedPlace] = []
        for display in displays where macOSWallpapers.showsOnDesktopRole(id, displayUUID: display.id) {
            if config.assignment(forDisplayUUID: display.id) == nil {
                out.append(AppliedPlace(display: display, kind: .desktop))
            }
            out.append(AppliedPlace(display: display, kind: .lockScreen))
        }
        if macOSWallpapers.isScreenSaver(id) { out.append(AppliedPlace(display: nil, kind: .screenSaver)) }
        return out
    }

    // MARK: - Pieces

    private static func macOSTargetKey(_ target: ApplyTarget) -> String {
        switch target {
        case .all: return "all"
        case .display(let uuid): return uuid
        }
    }

    private func macOSChoice(for aerial: AppleAerial) -> [String: Any]? {
        switch aerial.kind {
        case .picture:
            return MacOSWallpaperChoice.picture(file: ApplePictures.file(for: aerial, libraryRoot: root))
        case .drawn:
            return MacOSWallpaperChoice.drawnProvider(forAssetID: aerial.assetID)
                .map(MacOSWallpaperChoice.drawn(provider:))
        case .screenSaver:
            return AppleScreenSavers.choice(module: aerial.videoURL)
        case .video:
            return nil
        }
    }

    /// Takes Muro's own video off these displays, so macOS's wallpaper is
    /// what the desktop shows. The same edit as a desktop Remove.
    @discardableResult
    private func vacateDesktop(_ target: ApplyTarget) -> Bool {
        switch target {
        case .all:
            guard config.allDisplays != nil || !config.perDisplay.isEmpty else { return false }
            config.allDisplays = nil
            config.perDisplay = [:]
        case .display(let uuid):
            var changed = false
            if let fallback = config.allDisplays {
                for display in displays where display.id != uuid && config.perDisplay[display.id] == nil {
                    config.perDisplay[display.id] = fallback
                }
                config.allDisplays = nil
                changed = true
            }
            if config.perDisplay[uuid] != nil {
                config.perDisplay[uuid] = nil
                changed = true
            }
            guard changed else { return false }
        }
        saveConfig()
        return true
    }

    private func lockScreenHoldsDesktopRole(_ target: ApplyTarget) -> Bool {
        guard lockScreenAvailable else { return false }
        switch target {
        case .all: return displays.contains { lockScreenOwnsDisplay($0.id) }
        case .display(let uuid): return lockScreenOwnsDisplay(uuid)
        }
    }

    private func pushRecentMacOS(_ id: String) {
        var ids = recentIDs.filter { $0 != id }
        ids.insert(id, at: 0)
        recentIDs = Array(ids.prefix(10))
        UserDefaults.standard.set(recentIDs, forKey: "recents")
    }

    /// The downloaded file of one side of a still picture, when it is here.
    func applePictureFile(_ item: WallpaperItem) -> URL? {
        guard let aerial = macOSOnlyAerial(id: item.id), aerial.kind == .picture else { return nil }
        let file = ApplePictures.file(for: aerial, libraryRoot: root)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Remove Download on a still picture's card: its side of the picture
    /// goes, unless macOS is showing it, which reads it from that file.
    func canRemoveApplePicture(_ item: WallpaperItem) -> Bool {
        applePictureFile(item) != nil && !macOSWallpapers.shownIDs.contains(item.id)
    }

    func removeApplePictureDownload(_ item: WallpaperItem) {
        guard canRemoveApplePicture(item), let file = applePictureFile(item) else { return }
        try? FileManager.default.removeItem(at: file)
        objectWillChange.send()
        recomputeSize()
    }

    /// Whether the full picture from Apple is on this Mac.
    func isApplePictureDownloaded(_ item: WallpaperItem) -> Bool {
        guard let aerial = macOSOnlyAerial(id: item.id) else { return false }
        return ApplePictures.isReady(aerial, libraryRoot: root)
    }

    /// The Download button: fetches the full picture from Apple, without
    /// setting it.
    func downloadApplePictureNow(_ item: WallpaperItem) {
        guard let aerial = macOSOnlyAerial(id: item.id), aerial.kind == .picture else { return }
        Task {
            do {
                if !ApplePictures.isReady(aerial, libraryRoot: root) {
                    try await downloadApplePicture(aerial)
                } else {
                    await makeSharpPictures(for: aerial)
                }
            } catch {
                applyError = error.localizedDescription
            }
        }
    }

    /// Fetches the picture from Apple's servers and cuts out the light and
    /// dark images, with the same progress the other downloads show.
    private func downloadApplePicture(_ aerial: AppleAerial) async throws {
        guard downloads[aerial.id] == nil else { return }
        downloads[aerial.id] = 0
        defer { downloads[aerial.id] = nil }
        let root = self.root
        let id = aerial.id
        let directory = AppleAerials.cacheDir(libraryRoot: root)
        let zip = directory.appendingPathComponent(".\(AppleAerials.idPrefix)\(aerial.assetID).zip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try await fetchMaster(from: aerial.videoURL, to: zip) { progress in
                Task { @MainActor in AppStore.shared.downloads[id] = progress }
            }
        } catch {
            try? FileManager.default.removeItem(at: zip)
            throw error
        }
        try await Task.detached(priority: .userInitiated) {
            try ApplePictures.finish(zip: zip, for: aerial, libraryRoot: root)
        }.value
        await makeSharpPictures(for: aerial)
        recomputeSize()
    }

    /// The cards and the detail view show Apple's small pictures until the
    /// real one is here. Then each side gets a sharp picture of its own, cut
    /// from it the way the desktop shows it.
    private func makeSharpPictures(for aerial: AppleAerial) async {
        let root = self.root
        let assetIDs = ApplePictures.sides(of: aerial).map { [$0.light, $0.dark] } ?? [aerial.assetID]
        await Task.detached(priority: .userInitiated) {
            for assetID in assetIDs {
                let source = AppleAerials.cacheDir(libraryRoot: root)
                    .appendingPathComponent("\(AppleAerials.idPrefix)\(assetID).heic")
                let destination = URL(fileURLWithPath: AppleAerialInfo.framePath(assetID: assetID))
                guard FileManager.default.fileExists(atPath: source.path),
                      !FileManager.default.fileExists(atPath: destination.path)
                else { continue }
                try? ApplePictures.makeCardPicture(from: source, to: destination)
            }
        }.value
        AppleAerialFetcher.shared.noteChanged()
        objectWillChange.send()
    }
}

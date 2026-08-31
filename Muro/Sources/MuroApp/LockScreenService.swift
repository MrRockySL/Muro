import Foundation
import MuroKit

enum LockScreenServiceError: LocalizedError {
    case requiresTahoe
    case extensionMissing
    case extensionNotRegistered
    case translocated
    case wallpaperStoreMissing
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresTahoe:
            return "Lock-screen live wallpapers require macOS 26 or later."
        case .extensionMissing:
            return "Muro’s lock-screen extension is missing. Reinstall this build of Muro."
        case .extensionNotRegistered:
            return """
            macOS would not load Muro’s lock-screen extension. \
            Move Muro to your Applications folder, open it once from there, and try again.
            """
        case .translocated:
            return """
            macOS is running Muro from a temporary copy, so the lock screen cannot be set. \
            Drag Muro into your Applications folder, then open it from there.
            """
        case .wallpaperStoreMissing:
            return "The macOS wallpaper store could not be found."
        case .operationFailed(let message):
            return message
        }
    }
}

/// What `apply` settled on.
///
/// A lock-screen apply is really a request to WallpaperAgent, and the agent
/// answers on its own schedule. `.needsSystemSettings` means every file and
/// record Muro owns is in place but the agent has not acknowledged it yet.
/// That is a message, not a failure: the old code treated it as one and threw
/// away a selection that was usually about to settle a second later.
enum LockScreenApplyOutcome {
    case applied
    /// Written, held by the stores, but macOS has not come to collect it yet.
    ///
    /// Deliberately separate from `.needsSystemSettings`, which puts a modal
    /// alert in front of the user. This one says nothing on screen and only
    /// reaches the diagnostics log. An apply that macOS picks up a moment late
    /// is common; telling somebody their wallpaper failed when it is about to
    /// work would be worse than the silence it replaced.
    case pendingAcknowledgement
    case needsSystemSettings
}

/// Owns the Apple-managed half of Muro playback. It stages only wallpapers
/// selected for the lock screen and writes them into the Apple `Desktop`
/// surface of both wallpaper stores (`Index.plist` and macOS 26+'s
/// authoritative `Index2.plist`).
///
/// Why `Desktop` and not `Idle`: on macOS 26/27 the lock screen renders the
/// **Desktop** wallpaper surface — there is no separate lock-only surface, and
/// `Idle` is the screen *saver*. Writing `Idle` (the old approach) made the
/// System Settings tile appear but never changed the lock screen, so the very
/// first wallpaper that reached `Desktop` (via a manual System Settings click)
/// stayed frozen there. Muro's own borderless window still owns the *visible*
/// desktop, and the extension keeps `alwaysPauseDesktop` so it is a paused
/// still (≈0% CPU) on the desktop and only plays while locked.
///
/// It restores every record it owns before deleting staged files.
final class LockScreenService {
    static let extensionBundleID = "com.mrrockysl.muro.wallpaper-extension"
    private static let removedSelection = "__none__"

    private struct SelectionState: Codable {
        var selections: [String: String] = [:] // "all" or display UUID -> wallpaper ID
    }

    private struct ExtensionEntry: Codable {
        let id: String
        let title: String
        let videoFilename: String
        let thumbnailFilename: String
    }

    private struct ExtensionLibrary: Codable {
        var wallpapers: [ExtensionEntry]
    }

    private struct ExtensionPrefs: Codable {
        let alwaysPauseDesktop: Bool
    }

    private struct StoreSnapshot: Sendable {
        let url: URL
        let data: Data?
    }

    private let root: URL
    private var state: SelectionState

    /// Cheap half only: read Muro's own small state file. Everything
    /// expensive moved to `healIfNeeded()`.
    init(root: URL) {
        self.root = root
        state = Self.loadState(root: root)
    }

    /// WallpaperAgent may reject or remove a provider (for example after a
    /// test bundle is replaced). Never keep showing "Applied" when Apple no
    /// longer has a matching record.
    ///
    /// This used to run inside `init`, which the app reaches while building
    /// its store, on the main actor, before the window is drawn. It reads and
    /// rewrites Apple's property lists, runs `pluginkit`, and restarts
    /// WallpaperAgent, so on a slow launch it froze the interface behind a
    /// process spawn. It is a background job now, and the only thing it
    /// changes in the interface is an "Applied" badge that was already wrong.
    func healIfNeeded() async {
        // Before anything else, and on every launch rather than only when a
        // lock-screen wallpaper is set: an app that is still quarantined has an
        // extension macOS will not load, and the user finds out at the worst
        // moment. Cheap when there is nothing to clear (two `getxattr` calls).
        await Task.detached(priority: .utility) { Self.clearQuarantine() }.value

        let root = self.root
        let extensionURL = extensionBundleURL

        // Muro claiming nothing is not the same as Apple holding nothing. A
        // record can outlive the wallpaper it names, and this branch used to
        // return before it could ever look. The result was a Mac where macOS
        // asked Muro for a lock-screen wallpaper on every wake, Muro answered
        // with nothing because the file was gone, and neither side knew: the
        // app showed no lock-screen wallpaper set, so there was nothing to
        // suggest anything was wrong.
        guard !activeWallpaperIDs.isEmpty else {
            let changed = await Task.detached(priority: .utility) {
                (try? Self.purgeDeadMuroSurfaces(root: root)) == true
            }.value
            if changed {
                await Task.detached(priority: .utility) { Self.restartWallpaperAgent() }.value
            }
            return
        }

        let stillSelected = await Task.detached(priority: .utility) {
            Self.wallpaperStoresHaveSelection()
        }.value
        // A healthy selection can still sit alongside records left by earlier
        // wallpapers, so this path sweeps rather than simply returning.
        guard !stillSelected else {
            let changed = await Task.detached(priority: .utility) {
                (try? Self.purgeDeadMuroSurfaces(root: root)) == true
            }.value
            if changed {
                await Task.detached(priority: .utility) { Self.restartWallpaperAgent() }.value
            }
            return
        }

        await Task.detached(priority: .utility) {
            try? await Self.restoreWallpaperStores(targetKey: "all", root: root)
            try? FileManager.default.removeItem(at: Self.stateURL(root: root))
            try? Self.pruneStagedLibrary(keeping: [])
            Self.unregisterExtension(at: extensionURL)
            try? FileManager.default.removeItem(at: Self.backupDirectoryURL(root: root))
            try? FileManager.default.removeItem(at: Self.legacyBackupURL(root: root))
            Self.restartWallpaperAgent()
        }.value
        state = SelectionState()
    }

    var isAvailable: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            && FileManager.default.fileExists(atPath: extensionBundleURL.path)
    }

    var activeWallpaperIDs: Set<String> {
        Set(state.selections.values.filter { $0 != Self.removedSelection })
    }
    var activeWallpaperID: String? {
        state.selections["all"]
            ?? state.selections.values.first(where: { $0 != Self.removedSelection })
    }

    /// The targets whose lock screen currently shows one of `ids`. A delete
    /// clears exactly those, rather than wiping the lock screen on every
    /// display because one of them happened to hold a wallpaper going away.
    func targets(showing ids: Set<String>) -> [ApplyTarget] {
        state.selections
            .filter { $0.value != Self.removedSelection && ids.contains($0.value) }
            .map { $0.key == "all" ? .all : .display($0.key) }
    }

    func isApplied(wallpaperID: String, target: ApplyTarget) -> Bool {
        switch target {
        case .all:
            guard state.selections["all"] == wallpaperID else { return false }
            return state.selections
                .filter { $0.key != "all" }
                .values
                .allSatisfy { $0 == wallpaperID }
        case .display(let uuid):
            let effective = state.selections[uuid] ?? state.selections["all"]
            return effective == wallpaperID
        }
    }

    /// The extension's side of the handshake. Mirrors the type it writes.
    private struct AcquireReceipt: Codable {
        var id: String
        var at: Date
        var ok: Bool
        var preview: Bool
        var detail: String
    }

    private static var acquireReceiptURL: URL {
        extensionDocumentsURL.appendingPathComponent("acquire-receipt.json")
    }

    private static func latestReceipt() -> AcquireReceipt? {
        guard let data = try? Data(contentsOf: acquireReceiptURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AcquireReceipt.self, from: data)
    }

    /// Waits for macOS to actually come and collect the wallpaper.
    ///
    /// This replaces re-reading the property list Muro had just written, which
    /// could only ever fail if WallpaperAgent deleted the line within a few
    /// seconds. Everything else, macOS ignoring the choice included, read as
    /// success. A receipt is written by the extension when macOS calls
    /// `acquire`, so it cannot be produced by Muro talking to itself.
    ///
    /// A preview acquire counts. It is still macOS accepting the provider and
    /// finding the staged file, and refusing it would invent failures on any
    /// Mac that previews before it commits.
    private static func awaitAcknowledgement(
        wallpaperID: String,
        since: Date,
        timeout: TimeInterval
    ) async -> Bool {
        func matches() -> Bool {
            guard let receipt = latestReceipt() else { return false }
            return receipt.ok
                && receipt.id == wallpaperID
                && receipt.at >= since.addingTimeInterval(-1)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if matches() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return matches()
    }

    @discardableResult
    func apply(
        entry: WallpaperEntry,
        videoURL: URL,
        thumbnailURL: URL,
        target: ApplyTarget
    ) async throws -> LockScreenApplyOutcome {
        try validateAvailability()
        let targetKey = Self.targetKey(target)
        let previousState = state
        var nextState = state
        if targetKey == "all" {
            nextState.selections = ["all": entry.id]
        } else {
            nextState.selections[targetKey] = entry.id
        }

        let extensionURL = extensionBundleURL
        let root = root
        let outcome = try await Task.detached(priority: .userInitiated) {
            () -> LockScreenApplyOutcome in
            let storeSnapshots = Self.wallpaperStoreURLs.map {
                StoreSnapshot(url: $0, data: try? Data(contentsOf: $0))
            }
            do {
                try Self.stage(entry: entry, videoURL: videoURL, thumbnailURL: thumbnailURL)
                try Self.writePreferences()
                try await Self.registerExtension(at: extensionURL)

                // WallpaperAgent restarts asynchronously and rewrites the store
                // from its own state, so a single write followed by a fixed
                // sleep was a coin toss: that race is what made this fail on
                // some machines and not others. Write, kick the agent, then
                // watch for the selection to appear; if the agent clobbered it,
                // write again. Three passes, about ten seconds in the worst
                // case, and almost always settled on the first.
                let applyStart = Date()
                var acknowledged = false
                var storeHolds = false
                for _ in 1...3 {
                    try await Self.updateWallpaperStores(
                        wallpaperID: entry.id,
                        videoURL: Self.stagedVideoURL(id: entry.id),
                        targetKey: targetKey,
                        root: root
                    )
                    Self.notifyLibraryChanged()
                    Self.restartWallpaperAgent()
                    if await Self.awaitAcknowledgement(
                        wallpaperID: entry.id, since: applyStart, timeout: 3
                    ) {
                        acknowledged = true
                        storeHolds = true
                        break
                    }
                    // No receipt. If the stores still hold the choice then
                    // macOS simply has not come looking, and writing it a
                    // fourth time will not make it. Only a choice the agent
                    // overwrote is worth another pass.
                    storeHolds = Self.wallpaperStoresHaveSelection()
                    if storeHolds { break }
                }

                try Self.saveState(nextState, root: root)
                try Self.pruneStagedLibrary(
                    keeping: Set(nextState.selections.values).subtracting([Self.removedSelection])
                )
                let settled = acknowledged || storeHolds
                // The wallpaper this one replaced has just lost its staged
                // file, so every record still naming it is now dead. Sweeping
                // here is what stops the stores growing a layer per wallpaper.
                // The live record is untouched, so the agent only re-reads
                // what it is already showing.
                if (try? Self.purgeDeadMuroSurfaces(root: root)) == true {
                    Self.restartWallpaperAgent()
                }
                // Recorded every time now, not only on failure. An apply that
                // reports success and quietly does nothing is exactly the case
                // that used to leave no trace at all, which is what made the
                // first report of it unanswerable.
                Self.recordDiagnostics(
                    root: root,
                    wallpaperID: entry.id,
                    targetKey: targetKey,
                    registered: true,
                    settled: settled,
                    acknowledged: acknowledged
                )
                if !settled { return .needsSystemSettings }
                return acknowledged ? .applied : .pendingAcknowledgement
            } catch {
                // Only a real failure rolls back: the extension would not
                // register, or a store write threw. A slow agent no longer
                // costs the user their selection.
                for snapshot in storeSnapshots {
                    if let data = snapshot.data {
                        try? data.write(to: snapshot.url, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: snapshot.url)
                    }
                }
                Self.restartWallpaperAgent()
                try? Self.saveState(previousState, root: root)
                try? Self.pruneStagedLibrary(keeping: Set(previousState.selections.values))
                if previousState.selections.isEmpty {
                    Self.unregisterExtension(at: extensionURL)
                    try? FileManager.default.removeItem(at: Self.backupDirectoryURL(root: root))
                    try? FileManager.default.removeItem(at: Self.legacyBackupURL(root: root))
                }
                Self.recordDiagnostics(
                    root: root,
                    wallpaperID: entry.id,
                    targetKey: targetKey,
                    registered: Self.extensionIsRegistered(),
                    settled: false,
                    error: error
                )
                throw error
            }
        }.value
        state = nextState
        return outcome
    }

    func remove(target: ApplyTarget) async throws {
        let targetKey = Self.targetKey(target)
        var nextState = state
        if targetKey == "all" {
            nextState.selections.removeAll()
        } else if nextState.selections["all"] != nil {
            // An explicit empty override lets one display opt out while the
            // all-displays fallback remains active everywhere else.
            nextState.selections[targetKey] = Self.removedSelection
        } else {
            nextState.selections[targetKey] = nil
        }
        let root = root
        let extensionURL = extensionBundleURL
        try await Task.detached(priority: .userInitiated) {
            try await Self.restoreWallpaperStores(targetKey: targetKey, root: root)
            try Self.saveState(nextState, root: root)
            Self.restartWallpaperAgent()
            try Self.pruneStagedLibrary(
                keeping: Set(nextState.selections.values).subtracting([Self.removedSelection])
            )
            // `restoreWallpaperStores` only rewrites surfaces matching this
            // target. Records for the same wallpaper under a display that is
            // no longer connected, or under another Space, are not matched and
            // used to survive a removal forever.
            if (try? Self.purgeDeadMuroSurfaces(root: root)) == true {
                Self.restartWallpaperAgent()
            }
            if nextState.selections.values.allSatisfy({ $0 == Self.removedSelection }) {
                Self.unregisterExtension(at: extensionURL)
                try? FileManager.default.removeItem(at: Self.backupDirectoryURL(root: root))
                try? FileManager.default.removeItem(at: Self.legacyBackupURL(root: root))
            }
        }.value
        state = nextState
    }

    /// Cache clearing is deliberately stronger than ordinary selection removal:
    /// no Apple record, extension library entry, preference, or copied video is
    /// allowed to survive it.
    func clearAll() async {
        let root = root
        let extensionURL = extensionBundleURL
        await Task.detached(priority: .userInitiated) {
            try? await Self.restoreWallpaperStores(targetKey: "all", root: root)
            Self.restartWallpaperAgent()
            Self.unregisterExtension(at: extensionURL)
            try? FileManager.default.removeItem(at: Self.extensionDocumentsURL)
            try? FileManager.default.removeItem(at: Self.stateURL(root: root))
            try? FileManager.default.removeItem(at: Self.acquireReceiptURL)
            try? FileManager.default.removeItem(at: Self.backupDirectoryURL(root: root))
            try? FileManager.default.removeItem(at: Self.legacyBackupURL(root: root))
        }.value
        state = SelectionState()
    }

    private func validateAvailability() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            throw LockScreenServiceError.requiresTahoe
        }
        guard !Self.isTranslocated else {
            throw LockScreenServiceError.translocated
        }
        guard FileManager.default.fileExists(atPath: extensionBundleURL.path) else {
            throw LockScreenServiceError.extensionMissing
        }
    }

    /// Gatekeeper path randomisation: macOS runs a quarantined app from a
    /// read-only copy under `/private/var/.../AppTranslocation/`, and
    /// `Bundle.main` points at that copy rather than at the install.
    ///
    /// Found while testing the quarantine fix, and it defeats the whole
    /// feature quietly: clearing quarantine writes to a throwaway copy, and
    /// the extension registers from a path that vanishes when the app quits,
    /// so WallpaperAgent is left holding a provider that no longer exists.
    /// There is nothing an app can do about its own translocation from the
    /// inside, so say what the user has to do instead of failing vaguely.
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    private var extensionBundleURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Extensions", isDirectory: true)
            .appendingPathComponent("MuroWallpaperExtension.appex", isDirectory: true)
    }

    private static var extensionDocumentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(extensionBundleID, isDirectory: true)
            .appendingPathComponent("Data/Documents", isDirectory: true)
    }

    private static var wallpaperStoreDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store", isDirectory: true)
    }

    private static let wallpaperStoreFileNames = ["Index.plist", "Index2.plist"]

    private static var wallpaperStoreURLs: [URL] {
        wallpaperStoreFileNames.map { wallpaperStoreDirectoryURL.appendingPathComponent($0) }
    }

    private static func stateURL(root: URL) -> URL {
        root.appendingPathComponent("lockscreen.json")
    }

    private static func backupDirectoryURL(root: URL) -> URL {
        root.appendingPathComponent("LockScreenStoreBackups", isDirectory: true)
    }

    private static func legacyBackupURL(root: URL) -> URL {
        root.appendingPathComponent("lockscreen-apple-backup.plist")
    }

    private static func backupURL(root: URL, storeName: String) -> URL {
        backupDirectoryURL(root: root).appendingPathComponent(storeName)
    }

    private static func missingStoreMarkerURL(root: URL, storeName: String) -> URL {
        backupDirectoryURL(root: root).appendingPathComponent("\(storeName).missing")
    }

    private static func targetKey(_ target: ApplyTarget) -> String {
        switch target {
        case .all: return "all"
        case .display(let uuid): return uuid
        }
    }

    private static func loadState(root: URL) -> SelectionState {
        guard let data = try? Data(contentsOf: stateURL(root: root)),
              let state = try? JSONDecoder().decode(SelectionState.self, from: data)
        else { return SelectionState() }
        return state
    }

    private static func loadWallpaperStore(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    /// One store holding the selection is enough.
    ///
    /// This used to demand both. `Index.plist` and `Index2.plist` are plainly
    /// not maintained together: on the owner's own Mac `Index2.plist` had not
    /// been touched in a month while `Index.plist` was live. Requiring both
    /// meant a correct apply reported itself as a failure.
    private static func wallpaperStoresHaveSelection() -> Bool {
        wallpaperStoreURLs.contains {
            containsMuroSurface(named: "Desktop", in: loadWallpaperStore(at: $0))
        }
    }

    private static func containsMuroSurface(named name: String, in value: Any?) -> Bool {
        guard let value else { return false }
        if let dictionary = value as? [String: Any] {
            if let surface = dictionary[name] as? [String: Any], isMuroSurface(surface) {
                return true
            }
            return dictionary.values.contains { containsMuroSurface(named: name, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsMuroSurface(named: name, in: $0) }
        }
        return false
    }

    private static func saveState(_ state: SelectionState, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL(root: root), options: .atomic)
    }

    // MARK: - Extension deployment

    private static func stagedVideoURL(id: String) -> URL {
        extensionDocumentsURL
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("wallpaper.mov")
    }

    private static func stage(
        entry: WallpaperEntry,
        videoURL: URL,
        thumbnailURL: URL
    ) throws {
        let manager = FileManager.default
        let videos = extensionDocumentsURL.appendingPathComponent("videos", isDirectory: true)
        try manager.createDirectory(at: videos, withIntermediateDirectories: true)

        let destination = videos.appendingPathComponent(entry.id, isDirectory: true)
        let staging = videos.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try manager.copyItem(at: videoURL, to: staging.appendingPathComponent("wallpaper.mov"))
            try manager.copyItem(at: thumbnailURL, to: staging.appendingPathComponent("thumbnail.jpg"))
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }

        let libraryURL = extensionDocumentsURL.appendingPathComponent("library.json")
        var library = loadExtensionLibrary()
        library.wallpapers.removeAll { $0.id == entry.id }
        library.wallpapers.append(ExtensionEntry(
            id: entry.id,
            title: entry.title,
            videoFilename: "wallpaper.mov",
            thumbnailFilename: "thumbnail.jpg"
        ))
        let data = try JSONEncoder().encode(library)
        try data.write(to: libraryURL, options: .atomic)
    }

    private static func loadExtensionLibrary() -> ExtensionLibrary {
        let url = extensionDocumentsURL.appendingPathComponent("library.json")
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(ExtensionLibrary.self, from: data)
        else { return ExtensionLibrary(wallpapers: []) }
        return library
    }

    private static func pruneStagedLibrary(keeping ids: Set<String>) throws {
        let manager = FileManager.default
        var library = loadExtensionLibrary()
        let removed = library.wallpapers.filter { !ids.contains($0.id) }
        library.wallpapers.removeAll { !ids.contains($0.id) }
        for entry in removed {
            let directory = extensionDocumentsURL
                .appendingPathComponent("videos", isDirectory: true)
                .appendingPathComponent(entry.id, isDirectory: true)
            try? manager.removeItem(at: directory)
        }
        try manager.createDirectory(at: extensionDocumentsURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(library)
        try data.write(
            to: extensionDocumentsURL.appendingPathComponent("library.json"),
            options: .atomic
        )
        notifyLibraryChanged()
    }

    private static func writePreferences() throws {
        try FileManager.default.createDirectory(
            at: extensionDocumentsURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(ExtensionPrefs(alwaysPauseDesktop: true))
        try data.write(
            to: extensionDocumentsURL.appendingPathComponent("muro-prefs.json"),
            options: .atomic
        )
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            .init("com.mrrockysl.muro.wallpaper.preferences-changed" as CFString),
            nil,
            nil,
            true
        )
    }

    private static func notifyLibraryChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            .init("com.mrrockysl.muro.wallpaper.library-changed" as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - Apple wallpaper store

    private static func updateWallpaperStores(
        wallpaperID: String,
        videoURL: URL,
        targetKey: String,
        root: URL
    ) async throws {
        let manager = FileManager.default
        guard let primaryURL = wallpaperStoreURLs.first,
              manager.fileExists(atPath: primaryURL.path)
        else {
            throw LockScreenServiceError.wallpaperStoreMissing
        }
        try manager.createDirectory(
            at: backupDirectoryURL(root: root),
            withIntermediateDirectories: true
        )
        let seedData = try Data(contentsOf: primaryURL)

        let choice: [String: Any] = [
            "Provider": extensionBundleID,
            "Files": [["relative": videoURL.absoluteString]],
            "Configuration": Data(wallpaperID.utf8),
        ]

        for storeURL in wallpaperStoreURLs {
            let storeName = storeURL.lastPathComponent
            let backup = backupURL(root: root, storeName: storeName)
            let missingMarker = missingStoreMarkerURL(root: root, storeName: storeName)
            let existed = manager.fileExists(atPath: storeURL.path)
            if !manager.fileExists(atPath: backup.path),
               !manager.fileExists(atPath: missingMarker.path) {
                if existed {
                    try manager.copyItem(at: storeURL, to: backup)
                } else {
                    try Data().write(to: missingMarker, options: .atomic)
                }
            }

            let data = existed ? try Data(contentsOf: storeURL) : seedData
            var store = try PropertyListSerialization.propertyList(from: data, format: nil)
            var changed = 0
            // The lock screen renders the Desktop surface on macOS 26/27, so
            // that is what we replace. Muro's own window keeps the visible
            // desktop; the extension stays paused there (alwaysPauseDesktop).
            mutateSurfaces(named: "Desktop", in: &store, path: []) { surfacePath, surface in
                guard targetKey == "all" || surfacePath.contains(targetKey) else { return surface }
                changed += 1
                return surfaceApplying(choice: choice, to: surface)
            }

            if targetKey != "all", changed == 0 {
                ensureDisplaySurface(
                    named: "Desktop",
                    displayUUID: targetKey,
                    choice: choice,
                    fallback: firstSurface(named: "Desktop", in: store) ?? defaultSurface(),
                    root: &store
                )
            } else if targetKey == "all", changed == 0 {
                // A real store can carry no `Desktop` key at all: on this Mac
                // the top-level `AllSpacesAndDisplays` node held only `Idle`,
                // so an all-displays apply matched nothing and wrote nothing.
                // Create the node that means "everywhere" rather than
                // succeeding silently against an empty tree.
                ensureAllSpacesSurface(
                    named: "Desktop",
                    choice: choice,
                    fallback: firstSurface(named: "Desktop", in: store) ?? defaultSurface(),
                    root: &store
                )
            }

            try writePropertyList(store, to: storeURL)
            // Written twice with a pause, because WallpaperAgent may rewrite
            // the file from its own state in between. Task.sleep yields the
            // thread; Thread.sleep parked one in the cooperative pool.
            try? await Task.sleep(nanoseconds: 250_000_000)
            try writePropertyList(store, to: storeURL)
        }
    }

    private static func restoreWallpaperStores(
        targetKey: String,
        root: URL
    ) async throws {
        let manager = FileManager.default
        for storeURL in wallpaperStoreURLs where manager.fileExists(atPath: storeURL.path) {
            let currentData = try Data(contentsOf: storeURL)
            var current = try PropertyListSerialization.propertyList(from: currentData, format: nil)
            let backupURL = backupURL(root: root, storeName: storeURL.lastPathComponent)
            let backup = (try? Data(contentsOf: backupURL)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil)
            }

            // Desktop is what we now own; Idle/Linked are cleaned too so any
            // records left by older builds (or a manual System Settings click)
            // are also stripped and the user's own wallpaper comes back.
            for surfaceName in ["Desktop", "Idle", "Linked"] {
                let fallback = backup.flatMap { firstNonMuroSurface(named: surfaceName, in: $0) }
                    ?? firstNonMuroSurface(named: surfaceName, in: current)
                    ?? crossStoreNonMuroSurface(named: surfaceName)
                    ?? defaultSurface()
                replaceMuroSurfaces(
                    named: surfaceName,
                    in: &current,
                    path: [],
                    targetKey: targetKey
                ) { path, _ in
                    backup.flatMap { surface(named: surfaceName, at: path, in: $0) }
                        .flatMap { isMuroSurface($0) ? nil : $0 }
                        ?? fallback
                }
            }

            try writePropertyList(current, to: storeURL)
            try? await Task.sleep(nanoseconds: 250_000_000)
            try writePropertyList(current, to: storeURL)
        }
    }

    /// Takes every dead Muro record out of Apple's stores and gives the
    /// surface back to whatever the user had.
    ///
    /// Needed because a wallpaper apply fans out. Apple keeps one `Desktop`
    /// surface per Space per display and the write walks all of them, so a Mac
    /// that has used the feature for a while accumulates a record per Space
    /// for every wallpaper it has ever shown. Removing one wallpaper only ever
    /// rewrote the surfaces matching that target, so the rest sat there
    /// pointing at videos that had since been deleted: measured at 139 of 356
    /// records on the developer's own Mac, with the two stores disagreeing
    /// about which wallpaper was current.
    ///
    /// Returns whether anything changed, so the caller only restarts
    /// WallpaperAgent when there is a reason to.
    @discardableResult
    private static func purgeDeadMuroSurfaces(root: URL) throws -> Bool {
        let manager = FileManager.default
        var changedAnyStore = false
        for storeURL in wallpaperStoreURLs where manager.fileExists(atPath: storeURL.path) {
            let data = try Data(contentsOf: storeURL)
            var current = try PropertyListSerialization.propertyList(from: data, format: nil)
            let backup = (try? Data(contentsOf: backupURL(root: root, storeName: storeURL.lastPathComponent)))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            var changed = false

            for surfaceName in ["Desktop", "Idle", "Linked"] {
                let fallback = backup.flatMap { firstNonMuroSurface(named: surfaceName, in: $0) }
                    ?? firstNonMuroSurface(named: surfaceName, in: current)
                    ?? crossStoreNonMuroSurface(named: surfaceName)
                    ?? defaultSurface()
                mutateSurfaces(named: surfaceName, in: &current, path: []) { path, surface in
                    guard isDeadMuroSurface(surface) else { return surface }
                    changed = true
                    return backup.flatMap { self.surface(named: surfaceName, at: path, in: $0) }
                        .flatMap { isMuroSurface($0) ? nil : $0 }
                        ?? fallback
                }
            }

            guard changed else { continue }
            try writePropertyList(current, to: storeURL)
            changedAnyStore = true
        }
        return changedAnyStore
    }

    private static func writePropertyList(_ value: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private static func mutateSurfaces(
        named name: String,
        in value: inout Any,
        path: [String],
        transform: ([String], [String: Any]) -> [String: Any]
    ) {
        guard var dictionary = value as? [String: Any] else { return }
        if let surface = dictionary[name] as? [String: Any] {
            dictionary[name] = transform(path + [name], surface)
        }
        for key in Array(dictionary.keys) where key != name {
            guard var child = dictionary[key] else { continue }
            mutateSurfaces(named: name, in: &child, path: path + [key], transform: transform)
            dictionary[key] = child
        }
        value = dictionary
    }

    private static func replaceMuroSurfaces(
        named name: String,
        in value: inout Any,
        path: [String],
        targetKey: String,
        replacement: ([String], [String: Any]) -> [String: Any]
    ) {
        mutateSurfaces(named: name, in: &value, path: path) { surfacePath, surface in
            guard isMuroSurface(surface),
                  targetKey == "all" || surfacePath.contains(targetKey)
            else { return surface }
            return replacement(surfacePath, surface)
        }
    }

    private static func isMuroSurface(_ surface: [String: Any]) -> Bool {
        guard let content = surface["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]]
        else { return false }
        return choices.contains { ($0["Provider"] as? String) == extensionBundleID }
    }

    /// The wallpaper this Muro record asks the extension to play. macOS hands
    /// the same bytes back on `acquire`, so it is what the extension looks up.
    private static func muroWallpaperID(of surface: [String: Any]) -> String? {
        guard let content = surface["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]]
        else { return nil }
        for choice in choices where (choice["Provider"] as? String) == extensionBundleID {
            guard let data = choice["Configuration"] as? Data else { continue }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// A Muro record is dead when the video it names is no longer staged.
    ///
    /// Dead records are the whole failure: macOS still believes Muro owns the
    /// surface, asks the extension for that wallpaper, and the extension has
    /// nothing to hand back, so the lock screen falls back to Apple's default
    /// and the extension log fills with `no staged lock-screen library`.
    ///
    /// Deliberately keyed on the staged file rather than on Muro's own
    /// selection list. A wallpaper picked straight from System Settings never
    /// reaches `lockscreen.json`, so judging by the selection list would tear
    /// out a choice the user made by hand. A record naming a file that does
    /// not exist cannot be anybody's working choice.
    private static func isDeadMuroSurface(_ surface: [String: Any]) -> Bool {
        guard isMuroSurface(surface) else { return false }
        guard let id = muroWallpaperID(of: surface), !id.isEmpty else { return true }
        return !FileManager.default.fileExists(atPath: stagedVideoURL(id: id).path)
    }

    private static func firstSurface(named name: String, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let surface = dictionary[name] as? [String: Any] { return surface }
            for child in dictionary.values {
                if let found = firstSurface(named: name, in: child) { return found }
            }
        }
        return nil
    }

    private static func firstNonMuroSurface(named name: String, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let surface = dictionary[name] as? [String: Any], !isMuroSurface(surface) {
                return surface
            }
            for child in dictionary.values {
                if let found = firstNonMuroSurface(named: name, in: child) { return found }
            }
        }
        return nil
    }

    /// When one store's surfaces are all Muro (e.g. after a manual System
    /// Settings click populated only `Index.plist`), the untouched sibling
    /// store still holds the user's real wallpaper. Pull it from there so
    /// removal restores the original instead of a blank default.
    private static func crossStoreNonMuroSurface(named name: String) -> [String: Any]? {
        for url in wallpaperStoreURLs {
            if let store = loadWallpaperStore(at: url),
               let surface = firstNonMuroSurface(named: name, in: store) {
                return surface
            }
        }
        return nil
    }

    private static func surface(named name: String, at path: [String], in root: Any) -> [String: Any]? {
        var current = root
        for component in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[component] else {
                return nil
            }
            current = next
        }
        return current as? [String: Any]
    }

    private static func surfaceApplying(
        choice: [String: Any],
        to surface: [String: Any]
    ) -> [String: Any] {
        var updated = surface
        var content = updated["Content"] as? [String: Any] ?? [:]
        content["Choices"] = [choice]
        if content["Shuffle"] == nil { content["Shuffle"] = "$null" }
        updated["Content"] = content
        updated["LastSet"] = Date()
        updated["LastUse"] = Date()
        return updated
    }

    private static func ensureDisplaySurface(
        named name: String,
        displayUUID: String,
        choice: [String: Any],
        fallback: [String: Any],
        root: inout Any
    ) {
        guard var rootDictionary = root as? [String: Any] else { return }
        var displays = rootDictionary["Displays"] as? [String: Any] ?? [:]
        var display = displays[displayUUID] as? [String: Any] ?? ["Type": "individual"]
        display[name] = surfaceApplying(choice: choice, to: fallback)
        displays[displayUUID] = display
        rootDictionary["Displays"] = displays
        root = rootDictionary
    }

    private static func ensureAllSpacesSurface(
        named name: String,
        choice: [String: Any],
        fallback: [String: Any],
        root: inout Any
    ) {
        guard var rootDictionary = root as? [String: Any] else { return }
        var node = rootDictionary["AllSpacesAndDisplays"] as? [String: Any] ?? [:]
        node[name] = surfaceApplying(choice: choice, to: fallback)
        rootDictionary["AllSpacesAndDisplays"] = node
        root = rootDictionary
    }

    private static func defaultSurface() -> [String: Any] {
        [
            "Content": [
                "Choices": [[
                    "Provider": "default",
                    "Files": [],
                    "Configuration": Data(),
                ]],
                "Shuffle": "$null",
            ],
            "LastSet": Date(),
            "LastUse": Date(),
        ]
    }

    // MARK: - Process lifecycle

    /// `pluginkit -a` exits 0 even when it rejects the bundle, so its status
    /// says nothing. The registry is the only honest answer: register, then
    /// wait for the extension to actually appear in it.
    private static func registerExtension(at url: URL) async throws {
        clearQuarantine()
        _ = run("/usr/bin/pluginkit", ["-a", url.path])
        for _ in 0..<12 {
            if extensionIsRegistered() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw LockScreenServiceError.extensionNotRegistered
    }

    static func extensionIsRegistered() -> Bool {
        runCapturing("/usr/bin/pluginkit", ["-m", "-i", extensionBundleID])
            .contains(extensionBundleID)
    }

    /// Strip `com.apple.quarantine` from Muro and its embedded extension.
    ///
    /// This is the fix for the failure people reported. A DMG downloaded in a
    /// browser is quarantined, the flag is inherited by everything copied out
    /// of it, and "Open Anyway" clears just enough to launch the app while the
    /// embedded appex stays flagged. macOS then refuses to load the extension,
    /// so WallpaperAgent has no provider to acquire and the lock-screen choice
    /// never sticks. It works when the owner builds locally because a local
    /// build is never quarantined, which is exactly why this went unnoticed.
    ///
    /// Muro is not sandboxed, so it can clear its own bundle. `removexattr`
    /// directly rather than shelling out to `xattr`: one syscall per file, no
    /// process spawn, and nothing to quote.
    static func clearQuarantine() {
        let bundle = Bundle.main.bundleURL
        guard isQuarantined(bundle)
            || isQuarantined(bundle.appendingPathComponent("Contents/Extensions/MuroWallpaperExtension.appex"))
        else { return }

        var urls = [bundle]
        if let walker = FileManager.default.enumerator(
            at: bundle,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for case let child as URL in walker { urls.append(child) }
        }
        for url in urls {
            _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return 0 }
                return removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
            }
        }
    }

    private static func isQuarantined(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// A line per failed apply, so the next bug report is answerable instead of
    /// being one screenshot of an alert. Capped, because a log nobody rotates
    /// is a disk leak.
    private static func recordDiagnostics(
        root: URL,
        wallpaperID: String,
        targetKey: String,
        registered: Bool,
        settled: Bool,
        acknowledged: Bool = false,
        error: Error? = nil
    ) {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let stores = wallpaperStoreURLs.map { url -> String in
            let has = containsMuroSurface(named: "Desktop", in: loadWallpaperStore(at: url))
            return "\(url.lastPathComponent)=\(has ? "ok" : "no")"
        }.joined(separator: " ")
        let line = [
            ISO8601DateFormatter().string(from: Date()),
            "macOS \(version)",
            "wallpaper=\(wallpaperID)",
            "target=\(targetKey)",
            "registered=\(registered)",
            "settled=\(settled)",
            // The honest half. `settled` only says the stores kept what Muro
            // wrote; `acknowledged` says macOS came and collected it.
            "acknowledged=\(acknowledged)",
            latestReceipt().map {
                "receipt=\($0.detail)/\($0.ok ? "ok" : "failed")"
                    + ($0.preview ? "/preview" : "")
            } ?? "receipt=none",
            stores,
            error.map { "error=\($0.localizedDescription)" } ?? "",
        ].filter { !$0.isEmpty }.joined(separator: " | ")

        EngineLog.log("[lockscreen] \(line)")

        let url = root.appendingPathComponent("lockscreen-diagnostics.log")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += line + "\n"
        if text.utf8.count > 32_768 {
            text = String(text.suffix(400))
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func unregisterExtension(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = run("/usr/bin/pluginkit", ["-r", url.path])
    }

    private static func restartWallpaperAgent() {
        _ = run("/usr/bin/killall", ["WallpaperAgent"])
    }

    private static func runCapturing(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

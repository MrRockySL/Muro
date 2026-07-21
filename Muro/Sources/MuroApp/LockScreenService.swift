import Foundation
import MuroKit

enum LockScreenServiceError: LocalizedError {
    case requiresTahoe
    case extensionMissing
    case wallpaperStoreMissing
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresTahoe:
            return "Lock-screen live wallpapers require macOS 26 or later."
        case .extensionMissing:
            return "Muro’s lock-screen extension is missing. Reinstall this build of Muro."
        case .wallpaperStoreMissing:
            return "The macOS wallpaper store could not be found."
        case .operationFailed(let message):
            return message
        }
    }
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

    init(root: URL) {
        self.root = root
        state = Self.loadState(root: root)
        // WallpaperAgent may reject or remove a provider (for example after a
        // test bundle is replaced). Never keep showing "Applied" when Apple no
        // longer has a matching Idle record.
        if !activeWallpaperIDs.isEmpty, !Self.wallpaperStoresHaveSelection() {
            try? Self.restoreWallpaperStores(targetKey: "all", root: root)
            state = SelectionState()
            try? FileManager.default.removeItem(at: Self.stateURL(root: root))
            try? Self.pruneStagedLibrary(keeping: [])
            Self.unregisterExtension(at: extensionBundleURL)
            try? FileManager.default.removeItem(at: Self.backupDirectoryURL(root: root))
            try? FileManager.default.removeItem(at: Self.legacyBackupURL(root: root))
            Self.restartWallpaperAgent()
        }
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

    func apply(
        entry: WallpaperEntry,
        videoURL: URL,
        thumbnailURL: URL,
        target: ApplyTarget
    ) async throws {
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
        try await Task.detached(priority: .userInitiated) {
            let storeSnapshots = Self.wallpaperStoreURLs.map {
                StoreSnapshot(url: $0, data: try? Data(contentsOf: $0))
            }
            do {
                try Self.stage(entry: entry, videoURL: videoURL, thumbnailURL: thumbnailURL)
                try Self.writePreferences()
                try Self.registerExtension(at: extensionURL)
                try Self.updateWallpaperStores(
                    wallpaperID: entry.id,
                    videoURL: Self.stagedVideoURL(id: entry.id),
                    targetKey: targetKey,
                    root: root
                )
                try Self.saveState(nextState, root: root)
                Self.notifyLibraryChanged()
                Self.restartWallpaperAgent()
                try await Task.sleep(nanoseconds: 1_250_000_000)
                guard Self.wallpaperStoresHaveSelection() else {
                    throw LockScreenServiceError.operationFailed(
                        "macOS did not retain Muro’s lock-screen selection."
                    )
                }
                try Self.pruneStagedLibrary(
                    keeping: Set(nextState.selections.values).subtracting([Self.removedSelection])
                )
            } catch {
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
                throw error
            }
        }.value
        state = nextState
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
            try Self.restoreWallpaperStores(targetKey: targetKey, root: root)
            try Self.saveState(nextState, root: root)
            Self.restartWallpaperAgent()
            try Self.pruneStagedLibrary(
                keeping: Set(nextState.selections.values).subtracting([Self.removedSelection])
            )
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
            try? Self.restoreWallpaperStores(targetKey: "all", root: root)
            Self.restartWallpaperAgent()
            Self.unregisterExtension(at: extensionURL)
            try? FileManager.default.removeItem(at: Self.extensionDocumentsURL)
            try? FileManager.default.removeItem(at: Self.stateURL(root: root))
            try? FileManager.default.removeItem(at: Self.backupDirectoryURL(root: root))
            try? FileManager.default.removeItem(at: Self.legacyBackupURL(root: root))
        }.value
        state = SelectionState()
    }

    private func validateAvailability() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            throw LockScreenServiceError.requiresTahoe
        }
        guard FileManager.default.fileExists(atPath: extensionBundleURL.path) else {
            throw LockScreenServiceError.extensionMissing
        }
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

    private static func wallpaperStoresHaveSelection() -> Bool {
        wallpaperStoreURLs.allSatisfy {
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
    ) throws {
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
            }

            try writePropertyList(store, to: storeURL)
            Thread.sleep(forTimeInterval: 0.25)
            try writePropertyList(store, to: storeURL)
        }
    }

    private static func restoreWallpaperStores(
        targetKey: String,
        root: URL
    ) throws {
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
            Thread.sleep(forTimeInterval: 0.25)
            try writePropertyList(current, to: storeURL)
        }
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

    private static func registerExtension(at url: URL) throws {
        let status = run("/usr/bin/pluginkit", ["-a", url.path])
        guard status == 0 else {
            throw LockScreenServiceError.operationFailed("Muro’s lock-screen extension could not be registered.")
        }
    }

    private static func unregisterExtension(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = run("/usr/bin/pluginkit", ["-r", url.path])
    }

    private static func restartWallpaperAgent() {
        _ = run("/usr/bin/killall", ["WallpaperAgent"])
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

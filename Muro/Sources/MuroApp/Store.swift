import SwiftUI
import AppKit
import MuroKit

/// One wallpaper as the UI sees it: local library entry, remote catalog
/// entry, or both (downloaded catalog wallpaper).
struct WallpaperItem: Identifiable, Equatable {
    var local: WallpaperEntry?
    var remote: CatalogEntry?

    var id: String { local?.id ?? remote?.id ?? "" }
    var title: String { local?.title ?? remote?.title ?? "" }
    var category: String { local?.category ?? remote?.category ?? "" }
    var width: Int { local?.width ?? remote?.width ?? 0 }
    var height: Int { local?.height ?? remote?.height ?? 0 }
    var fps: Double { local?.fps ?? remote?.fps ?? 30 }
    var duration: Double { local?.duration ?? remote?.duration ?? 0 }
    var sizeBytes: Int64 { local?.sizeBytes ?? remote?.sizeBytes ?? 0 }
    var liked: Bool { local?.liked ?? false }
    var isDownloaded: Bool { local != nil }
    var resolutionLabel: String {
        width >= 3200 ? "4K" : (width >= 2200 ? "1440p" : "1080p")
    }
    var metaLine: String {
        "\(category) · \(width)×\(height) · \(formatDuration(duration)) · \(formatSize(sizeBytes))"
    }
}

enum ApplyTarget: Equatable {
    case all
    case display(String)
}

enum ApplySurface: String, CaseIterable {
    case both = "Both", desktop = "Desktop", lockscreen = "Lockscreen"
}

struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let pixelsW: Int
    let pixelsH: Int
    let isMain: Bool

    var chipLabel: String {
        name.localizedCaseInsensitiveContains("built-in") ? "MACBOOK" : name.uppercased()
    }
}

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    let root = LibraryManifest.defaultRoot()
    let statsSampler = StatsSampler()

    enum Tab: String, CaseIterable, Identifiable {
        case home = "Home", explore = "Explore", library = "Library"
        var id: String { rawValue }
    }

    @Published var tab: Tab = .home
    /// +1 when moving right in the tab order, -1 when moving left — drives
    /// the direction of the small slide transition between pages.
    @Published var tabShift: CGFloat = 1
    @Published var manifest = LibraryManifest()
    @Published var catalog: [CatalogEntry] = []
    @Published var config = EngineConfig()
    @Published var playlists: [Playlist] = []
    @Published var downloads: [String: Double] = [:]        // id → 0…1
    @Published var generating: Set<String> = []             // efficient variants in flight
    @Published var importStatus: String?
    @Published var searchText = ""
    @Published var searchActive = false
    @Published var previewItem: WallpaperItem?
    @Published var previewMode = "smooth"
    @Published var applySurface: ApplySurface = .both
    @Published var heroID: String?
    @Published var libraryBytes: Int64 = 0
    @Published var recentIDs: [String] = []
    @Published var activePlaylistID: String?

    private var watcher: DispatchSourceFileSystemObject?
    private var playlistTimer: Timer?
    private let defaults = UserDefaults.standard

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reloadFromDisk()
        recentIDs = defaults.stringArray(forKey: "recents") ?? []
        activePlaylistID = defaults.string(forKey: "activePlaylist")
        if activePlaylistID != nil { schedulePlaylistTimer() }
        watchRoot()
        recomputeSize()
        // Seed the default so the Settings field shows the real URL instead
        // of an empty placeholder (getter also falls back when cleared).
        // Existing installs have an older default *stored*, which would keep
        // winning over the new one and silently leave Explore empty, so retire
        // superseded defaults on launch.
        let storedCatalogURL = defaults.string(forKey: "catalogURL") ?? ""
        if storedCatalogURL.isEmpty || AppStore.retiredCatalogURLs.contains(storedCatalogURL) {
            defaults.set(AppStore.defaultCatalogURL, forKey: "catalogURL")
        }
        // The power toggles used to be @AppStorage-only (and did nothing).
        // They now live in config.json where the engine reads them — migrate
        // a value the user had set, once.
        if config.autoPauseLowPower == nil, defaults.object(forKey: "autoPauseLowPower") != nil {
            config.autoPauseLowPower = defaults.bool(forKey: "autoPauseLowPower")
            try? config.save(root: root)
        }
        if config.autoPauseBattery == nil, defaults.object(forKey: "autoPauseBattery") != nil {
            config.autoPauseBattery = defaults.bool(forKey: "autoPauseBattery")
            try? config.save(root: root)
        }
        Task { await refreshCatalog() }
        Task { await checkForUpdates() }
        // Newly published wallpapers should show up without quitting the app,
        // so re-check whenever Muro is brought back to the front.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshCatalog() }
        }
    }

    // MARK: - Navigation

    func switchTab(_ new: Tab) {
        guard new != tab else { return }
        let order = Tab.allCases
        if let from = order.firstIndex(of: tab), let to = order.firstIndex(of: new) {
            tabShift = to >= from ? 1 : -1
        }
        tab = new
    }

    // MARK: - Items

    var items: [WallpaperItem] {
        let remoteByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var seen = Set<String>()
        var out: [WallpaperItem] = []
        for entry in manifest.wallpapers {
            out.append(WallpaperItem(local: entry, remote: remoteByID[entry.id]))
            seen.insert(entry.id)
        }
        for remote in catalog where !seen.contains(remote.id) {
            out.append(WallpaperItem(local: nil, remote: remote))
        }
        return out
    }

    var localItems: [WallpaperItem] { items.filter(\.isDownloaded) }
    var likedItems: [WallpaperItem] { items.filter(\.liked) }

    var categories: [String] {
        var seen = Set<String>()
        return items.map(\.category).filter { seen.insert($0).inserted }
    }

    func item(id: String) -> WallpaperItem? {
        items.first { $0.id == id }
    }

    /// The hero only ever plays LOCAL files (owner, 2026-07-19): a fresh
    /// install always shows exactly one wallpaper — the bundled 4K — and once
    /// the user has downloads, the hero moves among those. It never streams.
    var heroItem: WallpaperItem? {
        if let heroID, let item = item(id: heroID), heroPlayable(item) { return item }
        if let applied = currentAppliedID, let item = item(id: applied), item.isDownloaded {
            return item
        }
        if let firstLocal = localItems.first { return firstLocal }
        if let bundled = item(id: BundledWallpaper.id) { return bundled }
        return BundledWallpaper.fallbackEntry.map { WallpaperItem(local: nil, remote: $0) }
    }

    func heroPlayable(_ item: WallpaperItem) -> Bool {
        item.isDownloaded
            || (item.id == BundledWallpaper.id && BundledWallpaper.videoURL != nil)
    }

    /// Selector strip under the hero: everything the hero can actually play.
    var heroSelectorItems: [WallpaperItem] {
        var out = localItems
        if BundledWallpaper.videoURL != nil,
           !out.contains(where: { $0.id == BundledWallpaper.id }) {
            if let bundled = item(id: BundledWallpaper.id) {
                out.insert(bundled, at: 0)
            } else if let entry = BundledWallpaper.fallbackEntry {
                out.insert(WallpaperItem(local: nil, remote: entry), at: 0)
            }
        }
        return out
    }

    /// Local file for the hero: a downloaded master, or the bundled 4K.
    func heroVideoURL(for item: WallpaperItem) -> URL? {
        videoURL(for: item, mode: "smooth")
            ?? (item.id == BundledWallpaper.id ? BundledWallpaper.videoURL : nil)
    }

    var recentItems: [WallpaperItem] {
        recentIDs.compactMap { item(id: $0) }
    }

    // MARK: - Disk state

    func reloadFromDisk() {
        manifest = LibraryManifest.load(root: root)
        config = EngineConfig.load(root: root)
        playlists = PlaylistStore.load(root: root)
    }

    private func watchRoot() {
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reloadFromDisk()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func recomputeSize() {
        let root = self.root
        Task.detached(priority: .utility) {
            let sum = directorySize(root)
            await MainActor.run { AppStore.shared.libraryBytes = sum }
        }
    }

    // MARK: - Remote catalog

    /// Baked-in default (PLAN §2.7): catalog.json on Cloudflare R2, served
    /// from the bucket's public URL. The app fetches it anonymously — it
    /// carries no credentials; only muro-publish (owner's machine) can write.
    /// Overridable via `defaults write com.mrrockysl.muro catalogURL …`;
    /// empty falls back here.
    ///
    /// This is the free r2.dev development URL (rate-limited by Cloudflare).
    /// When the app gets real user volume, attach a custom domain to the
    /// bucket and add THIS url to `retiredCatalogURLs`.
    static let defaultCatalogURL =
        "https://pub-e910bedfcb17480a8067dba142403816.r2.dev/catalog.json"

    /// Former defaults. An install that still has one of these stored gets
    /// migrated to `defaultCatalogURL`; anything else is treated as a
    /// deliberate user override and left alone.
    static let retiredCatalogURLs = [
        "https://raw.githubusercontent.com/MrRockySL/Muro/main/catalog.json",
        "https://raw.githubusercontent.com/MrRockySL/Muro-Wallpapers/main/catalog.json",
    ]

    var catalogURLString: String {
        get {
            let stored = defaults.string(forKey: "catalogURL") ?? ""
            return stored.isEmpty ? AppStore.defaultCatalogURL : stored
        }
        set { defaults.set(newValue, forKey: "catalogURL"); Task { await refreshCatalog() } }
    }

    func refreshCatalog() async {
        // Silent no-op on any failure — the repo may not exist yet and the
        // app must work fully offline.
        guard let url = URL(string: catalogURLString) else { return }
        if let fetched = try? await RemoteCatalog.fetch(from: url) {
            catalog = fetched.wallpapers
            noteCatalogArrivals()
        }
    }

    // MARK: - "NEW" badges

    /// Catalog ids this install has already displayed at least once.
    /// Persisted, because the whole point is to survive relaunches.
    private var seenCatalogIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "seenCatalogIDs") ?? []) }
        set { defaults.set(Array(newValue), forKey: "seenCatalogIDs") }
    }

    /// Ids that showed up in the catalog during *this* launch. Deliberately
    /// not persisted: a badge marks "this arrived since you last looked", so
    /// it lasts the session and is gone next time the app opens.
    @Published private(set) var newlyArrivedIDs: Set<String> = []

    /// A wallpaper is NEW when it has appeared in the catalog since this
    /// install last saw it. The old rule — "not downloaded means new" — badged
    /// the entire catalog on every fresh install, and for downloaded ones it
    /// measured the local `dateAdded`, i.e. when *this user* downloaded it
    /// rather than when it was published.
    ///
    /// A first run seeds the seen-set instead of badging: everything is new to
    /// a new user, so badging all of it says nothing.
    private func noteCatalogArrivals() {
        let ids = Set(catalog.map(\.id))
        guard defaults.object(forKey: "seenCatalogIDs") != nil else {
            seenCatalogIDs = ids
            return
        }
        let arrivals = ids.subtracting(seenCatalogIDs)
        // A long-absent user shouldn't return to a wall of badges, so only
        // recent publishes count. Entries with no publishedAt (catalogs from
        // before the field existed) are treated as not recent.
        let cutoff = Date().addingTimeInterval(-AppStore.newBadgeWindow)
        let recent = arrivals.filter { id in
            guard let at = catalog.first(where: { $0.id == id })?.publishedAt else { return false }
            return at > cutoff
        }
        newlyArrivedIDs.formUnion(recent)
        seenCatalogIDs = seenCatalogIDs.union(ids)
    }

    static let newBadgeWindow: TimeInterval = 30 * 86_400

    func isNew(_ item: WallpaperItem) -> Bool { newlyArrivedIDs.contains(item.id) }

    // MARK: - App update check

    /// Release page URL when GitHub has a newer version than this build.
    @Published var updateAvailable: URL?

    static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    /// What the Settings "Check for Updates" button is showing right now.
    /// The launch check stays silent (`.idle`) so nothing flashes on startup;
    /// only a check the user asked for reports "up to date" or a failure.
    enum UpdateCheck: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed
    }

    @Published var updateCheck: UpdateCheck = .idle

    func checkForUpdates(userInitiated: Bool = false) async {
        // GitHub API latest release vs our version. `/releases/latest` ignores
        // prereleases, so a wallpaper-storage release is never mistaken for an
        // app update. The automatic launch check stays silent on every failure
        // (offline, rate-limited, no release yet); only a user-initiated check
        // surfaces the outcome, because someone who pressed a button deserves
        // an answer rather than a button that does nothing.
        if userInitiated { updateCheck = .checking }
        guard let url = URL(string: "https://api.github.com/repos/MrRockySL/Muro/releases/latest"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init)
        else {
            if userInitiated { updateCheck = .failed }
            return
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if AppStore.isVersion(latest, newerThan: AppStore.appVersion) {
            updateAvailable = page
            if userInitiated { updateCheck = .available(version: latest, page: page) }
        } else {
            updateAvailable = nil
            if userInitiated { updateCheck = .upToDate }
        }
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Apply

    /// What's actually showing, main display first. Per-display assignments
    /// override the all-displays fallback, so resolve through the connected
    /// displays instead of trusting a possibly-stale `allDisplays` entry
    /// (that stale read made the menu bar header show the wrong wallpaper).
    var currentAppliedID: String? {
        for display in displays {
            if let assignment = config.assignment(forDisplayUUID: display.id) {
                return assignment.wallpaperID
            }
        }
        return config.allDisplays?.wallpaperID ?? config.perDisplay.first?.value.wallpaperID
    }

    var isPaused: Bool { config.paused ?? false }

    func openPreview(_ item: WallpaperItem) {
        previewItem = item
        let def = defaults.string(forKey: "defaultMode") ?? "smooth"
        previewMode = (def == "efficient" && item.fps > 40) ? "efficient" : "smooth"
    }

    func defaultMode(for item: WallpaperItem) -> String {
        let def = defaults.string(forKey: "defaultMode") ?? "smooth"
        return (def == "efficient" && item.fps > 40) ? "efficient" : "smooth"
    }

    func setWallpaper(_ item: WallpaperItem, mode: String, target: ApplyTarget = .all) {
        guard let entry = item.local else { return }
        if mode == "efficient", entry.fps > 40, entry.efficientFile == nil {
            Task {
                if await ensureEfficientVariant(entry) {
                    applyAssignment(id: entry.id, mode: "efficient", target: target)
                }
            }
        } else {
            applyAssignment(id: entry.id, mode: entry.fps > 40 ? mode : "smooth", target: target)
        }
    }

    private func applyAssignment(id: String, mode: String, target: ApplyTarget) {
        let assignment = EngineConfig.Assignment(wallpaperID: id, mode: mode)
        switch target {
        case .all:
            config.allDisplays = assignment
            config.perDisplay = [:]
        case .display(let uuid):
            config.perDisplay[uuid] = assignment
        }
        config.paused = false
        saveConfig()
        pushRecent(id)
    }

    /// Applied on every connected display (drives the "✓ Applied" state).
    func isFullyApplied(_ item: WallpaperItem) -> Bool {
        let connected = displays
        guard !connected.isEmpty else { return false }
        return appliedDisplays(for: item.id).count == connected.count
    }

    /// Removes the wallpaper from one display only. If the assignment came
    /// from the all-displays fallback, that fallback is first materialized
    /// into explicit per-display entries so the other displays keep playing.
    func removeWallpaper(fromDisplay uuid: String) {
        if let fallback = config.allDisplays {
            for display in displays where display.id != uuid && config.perDisplay[display.id] == nil {
                config.perDisplay[display.id] = fallback
            }
            config.allDisplays = nil
        }
        config.perDisplay[uuid] = nil
        saveConfig()
    }

    func setPaused(_ paused: Bool) {
        config.paused = paused
        saveConfig()
    }

    var playbackSpeed: Double { config.playbackSpeed ?? 1.0 }

    func setPlaybackSpeed(_ speed: Double) {
        config.playbackSpeed = speed
        saveConfig()
    }

    // Power auto-pause lives in config.json (not @AppStorage) because the
    // ENGINE is what acts on it — the same config hot-reload path as pause
    // and playback speed, and the muro-engine CLI honors it too.
    var autoPauseLowPower: Bool { config.autoPauseLowPower ?? false }
    var autoPauseBattery: Bool { config.autoPauseBattery ?? false }

    func setAutoPauseLowPower(_ on: Bool) {
        config.autoPauseLowPower = on
        saveConfig()
    }

    func setAutoPauseBattery(_ on: Bool) {
        config.autoPauseBattery = on
        saveConfig()
    }

    func reapply() {
        config.paused = false
        saveConfig()
    }

    private func saveConfig() {
        try? config.save(root: root)
    }

    private func pushRecent(_ id: String) {
        var ids = recentIDs.filter { $0 != id }
        ids.insert(id, at: 0)
        recentIDs = Array(ids.prefix(10))
        defaults.set(recentIDs, forKey: "recents")
    }

    // MARK: - Displays

    var displays: [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let uuid = displayUUID(for: screen) else { return nil }
            return DisplayInfo(
                id: uuid,
                name: screen.localizedName,
                pixelsW: Int(screen.frame.width * screen.backingScaleFactor),
                pixelsH: Int(screen.frame.height * screen.backingScaleFactor),
                isMain: screen == NSScreen.screens.first
            )
        }
    }

    func appliedDisplays(for id: String) -> [DisplayInfo] {
        displays.filter { config.assignment(forDisplayUUID: $0.id)?.wallpaperID == id }
    }

    // MARK: - Likes

    func toggleLike(_ item: WallpaperItem) {
        guard let index = manifest.wallpapers.firstIndex(where: { $0.id == item.id }) else { return }
        manifest.wallpapers[index].liked.toggle()
        try? manifest.save(root: root)
    }

    // MARK: - Download (remote catalog → local library)

    func download(_ item: WallpaperItem) {
        var remoteEntry = item.remote
        // The bundled wallpaper's master is already inside the app — "download"
        // it from there (file:// URL) instead of pulling 40 MB it already has.
        if item.id == BundledWallpaper.id, let fallback = BundledWallpaper.fallbackEntry {
            remoteEntry = fallback
        }
        guard let remote = remoteEntry, item.local == nil, downloads[item.id] == nil else { return }
        downloads[item.id] = 0
        let root = self.root
        let id = item.id
        Task.detached(priority: .utility) {
            do {
                try await downloadRemoteWallpaper(remote, root: root) { progress in
                    Task { @MainActor in AppStore.shared.downloads[id] = progress }
                }
                await MainActor.run {
                    AppStore.shared.downloads[id] = nil
                    AppStore.shared.reloadFromDisk()
                    AppStore.shared.recomputeSize()
                }
            } catch {
                await MainActor.run { AppStore.shared.downloads[id] = nil }
            }
        }
    }

    // MARK: - Import (user's own videos)

    func importFiles(_ urls: [URL]) {
        let videos = urls.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { return }
        let root = self.root
        Task.detached(priority: .userInitiated) {
            for (index, url) in videos.enumerated() {
                await MainActor.run {
                    AppStore.shared.importStatus =
                        "Importing \(url.lastPathComponent) (\(index + 1)/\(videos.count)), transcoding to HEVC…"
                }
                _ = try? importVideo(source: url, root: root)
                await MainActor.run { AppStore.shared.reloadFromDisk() }
            }
            await MainActor.run {
                AppStore.shared.importStatus = nil
                AppStore.shared.recomputeSize()
            }
        }
    }

    // MARK: - Efficient variant

    func ensureEfficientVariant(_ entry: WallpaperEntry) async -> Bool {
        guard entry.fps > 40, entry.efficientFile == nil else { return true }
        generating.insert(entry.id)
        defer { generating.remove(entry.id) }
        let root = self.root
        let relative = "Masters/\(entry.id)-eff.mov"
        let source = root.appendingPathComponent(entry.file)
        let destination = root.appendingPathComponent(relative)
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try transcodeToHEVC(source: source, destination: destination, halveFrameRate: true)
            }.value
            var fresh = LibraryManifest.load(root: root)
            if let index = fresh.wallpapers.firstIndex(where: { $0.id == entry.id }) {
                fresh.wallpapers[index].efficientFile = relative
                try fresh.save(root: root)
                manifest = fresh
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Playlists

    var activePlaylist: Playlist? {
        playlists.first { $0.id == activePlaylistID }
    }

    func addPlaylist(_ playlist: Playlist) {
        playlists.append(playlist)
        savePlaylists()
    }

    func deletePlaylist(_ playlist: Playlist) {
        if activePlaylistID == playlist.id { stopPlaylist() }
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }

    func updatePlaylist(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist
        savePlaylists()
        if activePlaylistID == playlist.id { schedulePlaylistTimer() }
    }

    func startPlaylist(_ playlist: Playlist) {
        activePlaylistID = playlist.id
        defaults.set(playlist.id, forKey: "activePlaylist")
        advancePlaylist(forward: true, initial: true)
        schedulePlaylistTimer()
    }

    func stopPlaylist() {
        activePlaylistID = nil
        defaults.removeObject(forKey: "activePlaylist")
        playlistTimer?.invalidate()
        playlistTimer = nil
    }

    func advancePlaylist(forward: Bool, initial: Bool = false) {
        guard let playlist = activePlaylist else { return }
        let ids = playlist.wallpaperIDs.filter { id in localItems.contains { $0.id == id } }
        guard !ids.isEmpty else { return }
        let nextID: String
        if playlist.shuffle {
            nextID = ids.filter { $0 != currentAppliedID }.randomElement() ?? ids[0]
        } else if let current = currentAppliedID, let index = ids.firstIndex(of: current) {
            let step = initial ? 0 : (forward ? 1 : ids.count - 1)
            nextID = ids[(index + step) % ids.count]
        } else {
            nextID = ids[0]
        }
        if let item = item(id: nextID) {
            setWallpaper(item, mode: defaultMode(for: item))
        }
    }

    private func schedulePlaylistTimer() {
        playlistTimer?.invalidate()
        guard let playlist = activePlaylist else { return }
        let interval = max(1, playlist.intervalMinutes) * 60
        playlistTimer = Timer.scheduledTimer(withTimeInterval: Double(interval), repeats: true) { _ in
            Task { @MainActor in AppStore.shared.advancePlaylist(forward: true) }
        }
    }

    private func savePlaylists() {
        try? PlaylistStore.save(playlists, root: root)
    }

    // MARK: - Storage

    /// Removes catalog wallpapers from disk (they can be re-downloaded).
    /// User-imported videos are never touched.
    /// Wallpapers whose local files must never be cache-cleaned: everything
    /// applied (any display or the all-displays fallback) and everything a
    /// playlist references — deleting those would break playback mid-loop.
    var protectedWallpaperIDs: Set<String> {
        var ids = Set<String>()
        if let all = config.allDisplays?.wallpaperID { ids.insert(all) }
        for assignment in config.perDisplay.values { ids.insert(assignment.wallpaperID) }
        for playlist in playlists { ids.formUnion(playlist.wallpaperIDs) }
        return ids
    }

    func clearDownloadedCache() {
        let remoteIDs = Set(catalog.map(\.id))
        let keep = protectedWallpaperIDs
        let removable: (WallpaperEntry) -> Bool = {
            remoteIDs.contains($0.id) && !keep.contains($0.id)
        }
        for entry in manifest.wallpapers where removable(entry) {
            for relative in [entry.file, entry.efficientFile, entry.previewFile, entry.thumbnail].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(relative))
            }
        }
        manifest.wallpapers.removeAll(where: removable)
        try? manifest.save(root: root)
        recomputeSize()
    }

    /// Manual per-wallpaper space control: delete the local copy of one
    /// catalog wallpaper (it stays in Explore, re-downloadable anytime).
    /// The UI hides the action for protected items; the guard is a backstop.
    func removeDownload(_ item: WallpaperItem) {
        guard item.remote != nil, let entry = item.local,
              !protectedWallpaperIDs.contains(entry.id) else { return }
        for relative in [entry.file, entry.efficientFile, entry.previewFile, entry.thumbnail].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(relative))
        }
        manifest.wallpapers.removeAll { $0.id == entry.id }
        try? manifest.save(root: root)
        recomputeSize()
    }

    // MARK: - Files

    func videoURL(for item: WallpaperItem, mode: String) -> URL? {
        guard let entry = item.local else { return nil }
        let url = resolveVideoURL(entry: entry, mode: mode, root: root)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnailPath(for item: WallpaperItem) -> String? {
        if let entry = item.local {
            let path = root.appendingPathComponent(entry.thumbnail).path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        // Not downloaded, but the bundled wallpaper's thumb ships in the app —
        // no reason to fetch it over the network.
        if item.id == BundledWallpaper.id, let url = BundledWallpaper.thumbnailURL {
            return url.path
        }
        return nil
    }
}

func directorySize(_ root: URL) -> Int64 {
    var total: Int64 = 0
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    return total
}

// MARK: - Download worker (off the main actor)

func downloadRemoteWallpaper(
    _ remote: CatalogEntry,
    root: URL,
    progress: @escaping (Double) -> Void
) async throws {
    let masters = root.appendingPathComponent("Masters", isDirectory: true)
    let thumbs = root.appendingPathComponent("Thumbnails", isDirectory: true)
    for dir in [masters, thumbs] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let destination = masters.appendingPathComponent("\(remote.id).mov")
    let thumbDestination = thumbs.appendingPathComponent("\(remote.id).jpg")

    let (bytes, response) = try await URLSession.shared.bytes(from: remote.video)
    let total = max(response.expectedContentLength, 1)
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destination)
    var buffer = Data()
    buffer.reserveCapacity(1 << 17)
    var written: Int64 = 0
    do {
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 17 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(min(Double(written) / Double(total), 0.99))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try handle.close()
    } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: destination)
        throw error
    }

    // Thumbnail: prefer the hosted JPEG, fall back to extracting a frame.
    if let (data, _) = try? await URLSession.shared.data(from: remote.thumbnail) {
        try? data.write(to: thumbDestination, options: .atomic)
    }
    if !FileManager.default.fileExists(atPath: thumbDestination.path) {
        try? generateThumbnail(video: destination, destination: thumbDestination)
    }

    let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? remote.sizeBytes

    var manifest = LibraryManifest.load(root: root)
    manifest.wallpapers.append(WallpaperEntry(
        id: remote.id,
        title: remote.title,
        category: remote.category,
        file: "Masters/\(remote.id).mov",
        thumbnail: "Thumbnails/\(remote.id).jpg",
        width: remote.width,
        height: remote.height,
        fps: remote.fps,
        duration: remote.duration,
        sizeBytes: sizeBytes ?? remote.sizeBytes
    ))
    try manifest.save(root: root)
    progress(1)
}

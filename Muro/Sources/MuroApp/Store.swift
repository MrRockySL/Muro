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

    /// When this wallpaper became available to look at, which is what Explore
    /// orders by.
    ///
    /// For anything in the catalog that is its publish date, downloaded or
    /// not. A local `dateAdded` would be the day *this user* downloaded it,
    /// so using it would float a wallpaper published a year ago to the top of
    /// Explore the moment someone downloaded it. Only a video the user
    /// imported themselves has no publish date to speak of, and for that one
    /// the day they added it is exactly right.
    ///
    /// Catalogs published before `publishedAt` existed have none, and those
    /// entries are genuinely the oldest, so sorting them last is correct.
    var availableAt: Date {
        if let remote { return remote.publishedAt ?? .distantPast }
        return local?.dateAdded ?? .distantPast
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
    /// The Mac's own panel rather than something plugged into it. Separate
    /// from `isMain`, because an external monitor can be the main display.
    let isBuiltIn: Bool

    /// What this display is, for the line under its name. "Main" wins when it
    /// applies, since that is the more useful thing to know about a display
    /// you are choosing between; otherwise say what it actually is.
    var kindLabel: String {
        isMain ? "Main" : (isBuiltIn ? "Built-in" : "External")
    }

    var symbolName: String { isBuiltIn ? "laptopcomputer" : "display" }

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
    // The merged wallpaper list is derived from exactly these two, so any
    // change to either is the one and only thing that can stale the cache
    // built from them (see `items`).
    @Published var manifest = LibraryManifest() { didSet { invalidateItemCache() } }
    @Published var catalog: [CatalogEntry] = [] { didSet { invalidateItemCache() } }
    @Published var config = EngineConfig()
    @Published var playlists: [Playlist] = []
    @Published var downloads: [String: Double] = [:]        // id → 0…1
    @Published var generating: Set<String> = []             // efficient variants in flight
    @Published var importStatus: String?
    @Published var searchText = ""
    @Published var searchActive = false
    /// The What's New sheet. On the store rather than in the top bar so
    /// anything else that should open it later (the menu bar, a first run
    /// after an update) has one switch to flip.
    @Published var whatsNewOpen = false
    @Published var previewItem: WallpaperItem?
    @Published var previewMode = "smooth"
    @Published var applySurface: ApplySurface = .both
    @Published var heroID: String?
    @Published var libraryBytes: Int64 = 0
    /// What the last Clear actually did. Shown in Settings, because a Clear
    /// that frees nothing otherwise looks identical to one that never ran.
    @Published var clearStatus: String?
    @Published var recentIDs: [String] = []
    @Published var automations: [Automation] = []
    @Published var activePlaylistID: String?
    @Published var activeAutomationID: String?
    @Published var applyingLockScreen = false
    @Published var applyError: String?
    /// Kept separate from `applyError` so each alert can say what actually
    /// went wrong instead of sharing one misleading title.
    @Published var importError: String?
    /// Set when a delete had a consequence the user did not ask for and
    /// cannot see, such as a running playlist losing its last wallpaper.
    @Published var deleteNotice: String?
    /// The lock screen is applied and every file is in place, but macOS has
    /// not picked it up yet. Its own alert, with the one step that finishes
    /// the job, rather than the old dead-end error.
    @Published var lockScreenNeedsSystemSettings = false
    /// A delete waiting on the confirmation sheet.
    @Published var pendingDelete: DeleteRequest?
    /// `library.json` is on disk and could not be read. Muro refuses to write
    /// over it, so every edit stops until it is repaired or removed, and the
    /// user has to be told that rather than left with an app that quietly
    /// ignores them.
    @Published var libraryUnreadable = false
    /// Why the last catalog fetch failed, or nil when it worked.
    ///
    /// Every failure used to be swallowed by a `try?` and Explore answered all
    /// of them with "Nothing matches that", so a blocked connection was
    /// indistinguishable from filters set too narrow. A user reported it as
    /// "how can I view the explore section", which is exactly the confusion
    /// that wording creates.
    @Published var catalogError: CatalogError?
    /// False until the first fetch has finished, either way. Explore must not
    /// accuse anyone of over-filtering an empty page while the first fetch is
    /// still in the air.
    @Published private(set) var catalogLoaded = false
    /// A retry the user asked for is in flight, so the button can say so
    /// instead of looking dead.
    @Published private(set) var catalogRefreshing = false

    private var watcher: DispatchSourceFileSystemObject?
    private let scheduler = AutomationScheduler()
    private let defaults = UserDefaults.standard
    private lazy var lockScreen = LockScreenService(root: root)

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reloadFromDisk()
        recentIDs = defaults.stringArray(forKey: "recents") ?? []
        scheduler.apply = { [weak self] id in
            guard let self, let item = self.item(id: id) else { return }
            self.setWallpaper(item, mode: self.defaultMode(for: item))
        }
        scheduler.currentIDForOrdering = { [weak self] in self?.currentAppliedID }
        syncScheduler()
        watchRoot()
        recomputeSize()
        if !lockScreen.isAvailable { applySurface = .desktop }
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
        // Same story for the full screen toggle: it was @AppStorage-only and
        // the engine never read it, so switching it off did nothing at all.
        if config.autoPauseFullScreen == nil, defaults.object(forKey: "autoPauseFullScreen") != nil {
            config.autoPauseFullScreen = defaults.bool(forKey: "autoPauseFullScreen")
            try? config.save(root: root)
        }
        Task { await refreshCatalog() }
        Task { await checkForUpdatesIfDue() }
        // Reads Apple's wallpaper plists and may run pluginkit and restart
        // WallpaperAgent, so it must never sit on the launch path.
        Task { await lockScreen.healIfNeeded() }
        // Newly published wallpapers should show up without quitting the app,
        // so re-check whenever Muro is brought back to the front.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshCatalog()
                await self?.checkForUpdatesIfDue()
            }
        }
    }

    // MARK: - Navigation

    /// There is no direction to record here any more. The three top level
    /// tabs crossfade rather than slide, because moving a whole window moves
    /// its background with it (see `.muroTab`). The panels inside a page still
    /// track direction; they keep it in their own view state.
    func switchTab(_ new: Tab) {
        guard new != tab else { return }
        tab = new
    }

    // MARK: - Items

    // Everything below is derived from `manifest` + `catalog` and was being
    // rebuilt on every single access. `items` allocated an array and a
    // dictionary of the whole catalog, and `item(id:)` did that and then
    // linear-scanned the result, from inside view bodies, once per card and
    // once per playlist thumbnail. At 99 wallpapers that is wasteful; at the
    // 1000 this library is aimed at it is quadratic, and the automations
    // feature calls `item(id:)` once per step on every tick.
    private var cachedItems: [WallpaperItem]?
    private var cachedItemsByID: [String: WallpaperItem]?
    private var cachedLocalItems: [WallpaperItem]?
    private var cachedLikedItems: [WallpaperItem]?
    private var cachedNewestFirstItems: [WallpaperItem]?
    private var cachedCategories: [String]?

    private func invalidateItemCache() {
        cachedItems = nil
        cachedItemsByID = nil
        cachedLocalItems = nil
        cachedLikedItems = nil
        cachedNewestFirstItems = nil
        cachedCategories = nil
    }

    var items: [WallpaperItem] {
        if let cachedItems { return cachedItems }
        // `Dictionary(uniqueKeysWithValues:)` traps on a repeated key, and the
        // catalog is a file fetched from the network. One duplicate id in a
        // published catalog.json would therefore crash every installed copy of
        // Muro at launch, with no way for the user to recover. Keep the first
        // entry and carry on instead.
        let remoteByID = Dictionary(
            catalog.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var out: [WallpaperItem] = []
        out.reserveCapacity(manifest.wallpapers.count + catalog.count)
        for entry in manifest.wallpapers where seen.insert(entry.id).inserted {
            out.append(WallpaperItem(local: entry, remote: remoteByID[entry.id]))
        }
        for remote in catalog where !seen.contains(remote.id) {
            out.append(WallpaperItem(local: nil, remote: remote))
        }
        cachedItems = out
        return out
    }

    /// Everything, newest publish first. This is the order Explore browses in.
    ///
    /// `items` lists the library before the catalog, which is right for the
    /// places that care about what you own, and wrong for the one place that
    /// is about what has just arrived: it pushed a fresh drop below every
    /// wallpaper the user had ever downloaded, so with nine downloads the
    /// newest batch started on the fourth row, and with fifty it started on
    /// the seventeenth. The app promises new wallpapers appear at the top of
    /// Explore, and for anyone actually using it they did not.
    ///
    /// A whole batch shares one publish timestamp, so the date alone cannot
    /// decide the order inside a drop. Catalog position breaks the tie, which
    /// keeps a batch in the order it was published in, and `id` backstops the
    /// rest. That total ordering is what stops the grid reshuffling itself
    /// between launches.
    var newestFirstItems: [WallpaperItem] {
        if let cachedNewestFirstItems { return cachedNewestFirstItems }
        var position: [String: Int] = [:]
        for (index, entry) in catalog.enumerated() where position[entry.id] == nil {
            position[entry.id] = index
        }
        let out = items.sorted { a, b in
            if a.availableAt != b.availableAt { return a.availableAt > b.availableAt }
            switch (position[a.id], position[b.id]) {
            case let (x?, y?): return x < y
            // A video the user imported has no catalog position. It only ties
            // with a catalog entry when both dates are missing, and then the
            // catalog entry goes first.
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.id < b.id
            }
        }
        cachedNewestFirstItems = out
        return out
    }

    /// The most recent drop: every wallpaper sharing the newest publish date
    /// in the catalog.
    ///
    /// Membership is by publish date and nothing else, so downloading one does
    /// not remove it, and the set only changes when a newer batch is
    /// published. That is what lets Home keep showing the latest drop long
    /// after the NEW badges on it have faded.
    var latestDropItems: [WallpaperItem] {
        guard let newest = catalog.compactMap(\.publishedAt).max() else { return [] }
        return newestFirstItems.filter { $0.remote?.publishedAt == newest }
    }

    /// How many wallpapers Muro's Pick draws. Three to a page, four pages.
    static let pickCount = 12

    /// Muro's Pick: twelve wallpapers at random, drawn once a day.
    ///
    /// The row used to be every wallpaper in the catalog split into pages,
    /// which is a list, not a pick. Twelve drawn at random is small enough to
    /// feel chosen, and a new twelve each morning is a reason to open Home
    /// that a fixed list never gave anyone.
    ///
    /// A day, not a launch. The draw is written to defaults with the day it
    /// was made, so quitting and reopening five times before lunch shows the
    /// same twelve, and tomorrow shows a different twelve. It also means the
    /// row does not depend on how long the app happens to have been running,
    /// which matters here because Muro stays alive in the menu bar after its
    /// window closes.
    ///
    /// It re-draws only when today's draw came up short of what the pool can
    /// now supply, which happens when it ran at launch before the catalog had
    /// arrived. Comparing what was *drawn* rather than what still resolves is
    /// deliberate: deleting a wallpaper leaves an id that no longer resolves,
    /// and re-drawing on that would re-shuffle the row on every redraw for
    /// the rest of the day.
    ///
    /// The latest drop is excluded because it has its own row directly above.
    var pickItems: [WallpaperItem] {
        let drop = Set(latestDropItems.map(\.id))
        let pool = items.filter { !drop.contains($0.id) }
        let today = Calendar.current.startOfDay(for: Date())
        let drawnIDs = defaults.stringArray(forKey: "pickIDs") ?? []
        if let drawnDay = defaults.object(forKey: "pickDrawDay") as? Date,
           drawnDay == today,
           drawnIDs.count >= min(AppStore.pickCount, pool.count) {
            return drawnIDs.compactMap { item(id: $0) }
        }
        let drawn = Array(pool.shuffled().prefix(AppStore.pickCount))
        defaults.set(today, forKey: "pickDrawDay")
        defaults.set(drawn.map(\.id), forKey: "pickIDs")
        return drawn
    }

    var localItems: [WallpaperItem] {
        if let cachedLocalItems { return cachedLocalItems }
        let out = items.filter(\.isDownloaded)
        cachedLocalItems = out
        return out
    }

    var likedItems: [WallpaperItem] {
        if let cachedLikedItems { return cachedLikedItems }
        let out = items.filter(\.liked)
        cachedLikedItems = out
        return out
    }

    var categories: [String] {
        if let cachedCategories { return cachedCategories }
        var seen = Set<String>()
        let out = items.map(\.category).filter { seen.insert($0).inserted }
        cachedCategories = out
        return out
    }

    /// A dictionary lookup. This is called from view bodies far more often
    /// than anything else here, so it must not walk the library.
    func item(id: String) -> WallpaperItem? {
        if let cachedItemsByID { return cachedItemsByID[id] }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedItemsByID = byID
        return byID[id]
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
        switch LibraryManifest.state(root: root) {
        case .loaded(let fresh):
            manifest = fresh
            libraryUnreadable = false
        case .missing:
            manifest = LibraryManifest()
            libraryUnreadable = false
        case .damaged:
            // Keep showing whatever was last read successfully. Replacing it
            // with an empty manifest would say the library is empty, which is
            // both untrue and the exact impression the old bug left behind
            // right before it made it true.
            libraryUnreadable = true
        }
        config = EngineConfig.load(root: root)
        playlists = PlaylistStore.load(root: root)
        automations = AutomationStore.load(root: root)
        syncScheduler()
    }

    /// The scheduler owns the running schedule; the store owns what is on
    /// disk. This is the one place the two meet.
    private func syncScheduler() {
        scheduler.update(automations: automations, playlists: playlists)
        activePlaylistID = scheduler.activePlaylistID
        activeAutomationID = scheduler.activeAutomationID
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
    /// Served from the bucket's own domain. This replaced the free r2.dev
    /// development URL, which some networks block outright: `r2.dev` is one
    /// shared hostname for every Cloudflare R2 bucket, so filtering it takes
    /// out every bucket at once, and Explore arrived empty for anyone behind
    /// such a filter (issue #7, Turkey). A hostname nobody else is on cannot
    /// be caught by somebody else's block. The r2.dev endpoint stays enabled
    /// on the bucket permanently for installs that never update.
    static let defaultCatalogURL =
        "https://cdn.murowallpaper.com/catalog.json"

    /// Former defaults. An install that still has one of these stored gets
    /// migrated to `defaultCatalogURL`; anything else is treated as a
    /// deliberate user override and left alone. A stored value always beats a
    /// new default, so a URL retired without being listed here would keep
    /// every existing install on the old host for good.
    static let retiredCatalogURLs = [
        "https://raw.githubusercontent.com/MrRockySL/Muro/main/catalog.json",
        "https://raw.githubusercontent.com/MrRockySL/Muro-Wallpapers/main/catalog.json",
        "https://pub-e910bedfcb17480a8067dba142403816.r2.dev/catalog.json",
    ]

    var catalogURLString: String {
        get {
            let stored = defaults.string(forKey: "catalogURL") ?? ""
            return stored.isEmpty ? AppStore.defaultCatalogURL : stored
        }
        set { defaults.set(newValue, forKey: "catalogURL"); Task { await refreshCatalog() } }
    }

    /// Fetches the catalog and remembers what happened.
    ///
    /// It used to be a silent no-op on every failure, which is right for the
    /// app still working offline and wrong for the user, who was left with an
    /// empty Explore and no way to know the network was the reason. The last
    /// good catalog still stays in memory, so one failed refresh never empties
    /// an Explore that was working a moment ago.
    func refreshCatalog() async {
        defer { catalogLoaded = true }
        guard let url = URL(string: catalogURLString) else {
            catalogError = .unreachable
            return
        }
        do {
            let fetched = try await RemoteCatalog.fetch(from: url)
            catalog = fetched.wallpapers
            catalogError = nil
            noteCatalogArrivals()
        } catch {
            catalogError = CatalogError.classify(error)
        }
    }

    /// The Try Again button in Explore.
    func retryCatalog() {
        guard !catalogRefreshing else { return }
        Task {
            catalogRefreshing = true
            await refreshCatalog()
            catalogRefreshing = false
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

    /// Where the "Support Muro" row in Settings goes.
    static let sponsorURL = URL(string: "https://github.com/sponsors/MrRockySL")!

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

    /// The newer release GitHub is offering, with its notes and its DMG.
    /// Nil whenever this build is current. What's New reads it directly.
    @Published var latestRelease: ReleaseInfo?

    /// The small "New update available" bubble beside the What's New button.
    /// Shown once per version, not on every launch, because a callout that
    /// reappears forever stops being news and becomes a nag.
    @Published var updateCalloutVisible = false

    private static let seenUpdateKey = "seenUpdateVersion"

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
              let release = ReleaseInfo.from(json: json)
        else {
            if userInitiated { updateCheck = .failed }
            return
        }
        if AppVersion.isNewer(release.version, than: AppStore.appVersion) {
            latestRelease = release
            updateAvailable = release.page
            if userInitiated {
                updateCheck = .available(version: release.version, page: release.page)
            }
            let seen = UserDefaults.standard.string(forKey: Self.seenUpdateKey)
            if seen != release.version, !whatsNewOpen { updateCalloutVisible = true }
        } else {
            latestRelease = nil
            updateAvailable = nil
            updateCalloutVisible = false
            if userInitiated { updateCheck = .upToDate }
        }
    }

    /// Muro is a background app people leave running for weeks, so a check
    /// that only happens at launch is a check that never happens again. Six
    /// hours is often enough to hear about a release the day it lands and
    /// rare enough to stay well inside GitHub's unauthenticated rate limit.
    private var lastUpdateCheck = Date.distantPast

    func checkForUpdatesIfDue() async {
        guard Date().timeIntervalSince(lastUpdateCheck) > 6 * 3600 else { return }
        lastUpdateCheck = Date()
        await checkForUpdates()
    }

    /// Opening What's New is how someone acknowledges an update, so the
    /// callout retires there rather than needing its own dismiss.
    func markUpdateSeen() {
        updateCalloutVisible = false
        guard let version = latestRelease?.version else { return }
        UserDefaults.standard.set(version, forKey: Self.seenUpdateKey)
    }

    /// Download the new Muro: the release's DMG when it has one, its release
    /// page otherwise. Never a dead end.
    func downloadUpdate() {
        guard let release = latestRelease else { return }
        NSWorkspace.shared.open(release.downloadURL ?? release.page)
        markUpdateSeen()
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

    var lockScreenAvailable: Bool { lockScreen.isAvailable }
    var lockScreenWallpaperID: String? { lockScreen.activeWallpaperID }

    /// `surface == nil` is a legacy/menu-bar desktop action: it preserves any
    /// existing lock-screen selection. The preview picker passes an explicit
    /// surface, where Desktop means desktop-only and therefore removes Muro
    /// from the matching Apple Idle target.
    func setWallpaper(
        _ item: WallpaperItem,
        mode: String,
        target: ApplyTarget = .all,
        surface: ApplySurface? = nil
    ) {
        guard item.local != nil else { return }
        Task { await applyWallpaper(item, mode: mode, target: target, surface: surface) }
    }

    private func applyWallpaper(
        _ item: WallpaperItem,
        mode: String,
        target: ApplyTarget,
        surface explicitSurface: ApplySurface?
    ) async {
        guard var entry = item.local else { return }
        let surface = explicitSurface ?? .desktop
        let resolvedMode = entry.fps > 40 ? mode : "smooth"

        if resolvedMode == "efficient", entry.efficientFile == nil {
            guard await ensureEfficientVariant(entry),
                  let refreshed = manifest.wallpapers.first(where: { $0.id == entry.id })
            else { return }
            entry = refreshed
        }

        // A Both apply is committed to the desktop engine only after the
        // lock-screen transaction succeeds, so a failed extension/store write
        // cannot leave the UI in a silently half-applied state.
        if surface == .desktop {
            applyAssignment(id: entry.id, mode: resolvedMode, target: target)
        }

        if surface == .lockscreen || surface == .both {
            guard lockScreenAvailable else {
                applyError = LockScreenServiceError.requiresTahoe.localizedDescription
                return
            }
            let videoURL = resolveVideoURL(entry: entry, mode: resolvedMode, root: root)
            let thumbnailURL = root.appendingPathComponent(entry.thumbnail)
            guard FileManager.default.fileExists(atPath: videoURL.path),
                  FileManager.default.fileExists(atPath: thumbnailURL.path)
            else {
                applyError = "The downloaded wallpaper files could not be found."
                return
            }

            applyingLockScreen = true
            defer { applyingLockScreen = false }
            do {
                let outcome = try await lockScreen.apply(
                    entry: entry,
                    videoURL: videoURL,
                    thumbnailURL: thumbnailURL,
                    target: target
                )
                if outcome == .needsSystemSettings { lockScreenNeedsSystemSettings = true }
                if surface == .both {
                    applyAssignment(id: entry.id, mode: resolvedMode, target: target)
                } else {
                    pushRecent(entry.id)
                }
                objectWillChange.send()
                recomputeSize()
            } catch {
                applyError = error.localizedDescription
            }
        } else if explicitSurface == .desktop, !lockScreen.activeWallpaperIDs.isEmpty {
            do {
                try await lockScreen.remove(target: target)
                objectWillChange.send()
                recomputeSize()
            } catch {
                applyError = error.localizedDescription
            }
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

    func isApplied(_ item: WallpaperItem, surface: ApplySurface, target: ApplyTarget) -> Bool {
        let desktopApplied: Bool
        switch target {
        case .all:
            desktopApplied = isFullyApplied(item)
        case .display(let uuid):
            desktopApplied = config.assignment(forDisplayUUID: uuid)?.wallpaperID == item.id
        }
        let lockApplied = lockScreen.isApplied(wallpaperID: item.id, target: target)
        switch surface {
        case .desktop: return desktopApplied
        case .lockscreen: return lockApplied
        case .both: return desktopApplied && lockApplied
        }
    }

    /// Removes the selected wallpaper from one target. If a per-display
    /// desktop removal came from the all-displays fallback, that fallback is
    /// first materialized so the other displays keep playing.
    func removeWallpaper(
        _ item: WallpaperItem,
        target: ApplyTarget,
        surface: ApplySurface = .desktop
    ) {
        if surface == .desktop || surface == .both {
            switch target {
            case .all:
                if config.allDisplays?.wallpaperID == item.id { config.allDisplays = nil }
                config.perDisplay = config.perDisplay.filter { $0.value.wallpaperID != item.id }
            case .display(let uuid):
                if let fallback = config.allDisplays, fallback.wallpaperID == item.id {
                    for display in displays
                    where display.id != uuid && config.perDisplay[display.id] == nil {
                        config.perDisplay[display.id] = fallback
                    }
                    config.allDisplays = nil
                }
                if config.perDisplay[uuid]?.wallpaperID == item.id {
                    config.perDisplay[uuid] = nil
                }
            }
            saveConfig()
        }
        if surface == .lockscreen || surface == .both {
            Task {
                do {
                    try await lockScreen.remove(target: target)
                    objectWillChange.send()
                    recomputeSize()
                } catch {
                    applyError = error.localizedDescription
                }
            }
        }
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
    /// On by default: a covered wallpaper that keeps decoding is pure waste.
    var autoPauseFullScreen: Bool { config.autoPauseFullScreen ?? true }

    /// "Pause after": seconds of motion before a wallpaper freezes on a
    /// frame. 0 is off, which is how every existing install behaves.
    var pauseAfterSeconds: Int { config.pauseAfterSeconds ?? 0 }

    func setPauseAfter(_ seconds: Int) {
        config.pauseAfterSeconds = seconds > 0 ? seconds : nil
        saveConfig()
    }

    /// The value actually in force for one wallpaper: its own override, or
    /// the global setting when it has none.
    func effectivePauseAfter(for item: WallpaperItem) -> Int {
        guard let override = item.local?.pauseAfterSeconds else { return pauseAfterSeconds }
        return max(0, override)
    }

    func hasPauseAfterOverride(_ item: WallpaperItem) -> Bool {
        item.local?.pauseAfterSeconds != nil
    }

    /// `nil` clears the override and puts the wallpaper back on the setting.
    /// A negative value is how "never pause this one" is stored, so a
    /// wallpaper can opt out while the global setting stays on.
    func setPauseAfter(_ seconds: Int?, for item: WallpaperItem) {
        write { manifest in
            guard let index = manifest.wallpapers.firstIndex(where: { $0.id == item.id })
            else { return }
            manifest.wallpapers[index].pauseAfterSeconds = seconds
        }
    }

    func setAutoPauseFullScreen(_ on: Bool) {
        config.autoPauseFullScreen = on
        saveConfig()
    }

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
                isMain: screen == NSScreen.screens.first,
                // Ask the window server. If it cannot say, fall back to the
                // old assumption that the main display is the built-in one,
                // which is true for most people most of the time.
                isBuiltIn: displayIsBuiltIn(screen) ?? (screen == NSScreen.screens.first)
            )
        }
    }

    func appliedDisplays(for id: String) -> [DisplayInfo] {
        displays.filter { config.assignment(forDisplayUUID: $0.id)?.wallpaperID == id }
    }

    // MARK: - Likes

    /// Saving the in-memory manifest would write back whatever this copy was
    /// last loaded with, so a download that finished in the meantime would be
    /// erased by a heart tap. Every manifest edit goes through LibraryWriter,
    /// which works from what is actually on disk.
    func toggleLike(_ item: WallpaperItem) {
        write { manifest in
            guard let index = manifest.wallpapers.firstIndex(where: { $0.id == item.id })
            else { return }
            manifest.wallpapers[index].liked.toggle()
        }
    }

    /// Every small manifest edit the interface makes, in one place.
    ///
    /// These used to be `try?`, which turned the one error worth reporting
    /// into nothing at all: with a damaged `library.json` the heart simply
    /// would not fill and Muro said nothing about why.
    private func write(_ change: @escaping (inout LibraryManifest) -> Void) {
        do {
            manifest = try LibraryWriter.update(root: root, change)
        } catch LibraryWriter.WriteError.manifestUnreadable {
            libraryUnreadable = true
        } catch {
            applyError = error.localizedDescription
        }
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
        guard !videos.isEmpty else {
            // Dropping a folder, an image or an unsupported video used to do
            // nothing whatsoever, with no hint as to why.
            if !urls.isEmpty {
                importError = "Muro imports MP4, MOV and M4V videos. Nothing was added."
            }
            return
        }
        let skipped = urls.count - videos.count
        let root = self.root
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for (index, url) in videos.enumerated() {
                await MainActor.run {
                    // The file name and the codec are not news to the person
                    // who just dropped the file. One word plus a count is the
                    // whole of what they need while they wait.
                    AppStore.shared.importStatus = videos.count == 1
                        ? "Importing…"
                        : "Importing \(index + 1) of \(videos.count)…"
                }
                do {
                    _ = try importVideo(source: url, root: root)
                } catch {
                    failures.append("\(url.lastPathComponent): \(importFailureReason(error))")
                }
                await MainActor.run { AppStore.shared.reloadFromDisk() }
            }
            let report = failures
            await MainActor.run {
                AppStore.shared.importStatus = nil
                AppStore.shared.recomputeSize()
                // Silence here is what made a failed import look like a
                // no-op: the spinner stopped, nothing appeared, and the user
                // was told nothing at all.
                if !report.isEmpty {
                    let heading = report.count == 1
                        ? "This video could not be imported."
                        : "\(report.count) of \(videos.count) videos could not be imported."
                    AppStore.shared.importError =
                        ([heading] + report).joined(separator: "\n\n")
                } else if skipped > 0 {
                    AppStore.shared.importError =
                        "\(skipped) file\(skipped == 1 ? " was" : "s were") skipped. "
                        + "Muro imports MP4, MOV and M4V videos."
                }
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
            manifest = try LibraryWriter.update(root: root) { fresh in
                guard let index = fresh.wallpapers.firstIndex(where: { $0.id == entry.id })
                else { return }
                fresh.wallpapers[index].efficientFile = relative
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
    }

    func startPlaylist(_ playlist: Playlist) {
        scheduler.startPlaylist(playlist)
        syncScheduler()
    }

    func stopPlaylist() {
        scheduler.stopPlaylist()
        syncScheduler()
    }

    func advancePlaylist(forward: Bool) {
        scheduler.advancePlaylist(forward: forward)
    }

    private func savePlaylists() {
        try? PlaylistStore.save(playlists, root: root)
        syncScheduler()
    }

    // MARK: - Automations

    var activeAutomation: Automation? {
        automations.first { $0.id == activeAutomationID }
    }

    /// Whatever schedule is driving the wallpaper right now, for the status
    /// line in the menu bar.
    var runningScheduleName: String? { scheduler.runningName }

    func addAutomation(_ automation: Automation) {
        automations.append(automation)
        saveAutomations()
    }

    func updateAutomation(_ automation: Automation) {
        guard let index = automations.firstIndex(where: { $0.id == automation.id }) else { return }
        automations[index] = automation
        saveAutomations()
    }

    func deleteAutomation(_ automation: Automation) {
        if activeAutomationID == automation.id { stopAutomation() }
        automations.removeAll { $0.id == automation.id }
        saveAutomations()
    }

    func startAutomation(_ automation: Automation) {
        scheduler.startAutomation(automation)
        syncScheduler()
    }

    func stopAutomation() {
        scheduler.stopAutomation()
        syncScheduler()
    }

    private func saveAutomations() {
        try? AutomationStore.save(automations, root: root)
        syncScheduler()
    }

    // MARK: - Delete

    /// The one delete path in the app.
    ///
    /// A wallpaper is referenced from seven places: its files on disk, the
    /// library manifest, the display assignments, the lock screen selection,
    /// the playlists, the recents strip and the hero. Every removal written
    /// before this one touched two of them, which is how a playlist could end
    /// up rotating through wallpapers that were no longer on the Mac.
    ///
    /// Order matters. The wallpaper is taken off the screen first, so the
    /// engine drops its layer while the file it is decoding still exists, and
    /// only then does the file go. That is also why an applied wallpaper no
    /// longer has to be protected from deletion: this un-applies it first.
    func deleteWallpapers(_ items: [WallpaperItem]) {
        let entries = items.compactMap(\.local)
        guard !entries.isEmpty else { return }
        Task { await performDelete(entries) }
    }

    /// What the interface calls. Nothing deletes without an answer, so the
    /// button, the menu item and the batch bar all end up in the same sheet.
    func requestDelete(_ items: [WallpaperItem]) {
        let deletable = items.filter { $0.local != nil }
        guard !deletable.isEmpty else { return }
        pendingDelete = DeleteRequest(items: deletable)
    }

    func deleteWallpaper(_ item: WallpaperItem) {
        deleteWallpapers([item])
    }

    private func performDelete(_ entries: [WallpaperEntry]) async {
        let ids = Set(entries.map(\.id))

        // 1. Off the desktop. A deleted all-displays wallpaper clears every
        //    display, which is what deleting the thing on screen means.
        var configChanged = false
        if let all = config.allDisplays?.wallpaperID, ids.contains(all) {
            config.allDisplays = nil
            configChanged = true
        }
        let keptPerDisplay = config.perDisplay.filter { !ids.contains($0.value.wallpaperID) }
        if keptPerDisplay.count != config.perDisplay.count {
            config.perDisplay = keptPerDisplay
            configChanged = true
        }
        if configChanged { saveConfig() }

        // 2. Off the lock screen. That surface keeps its own staged copy of
        //    the video inside the extension container and a record in Apple's
        //    wallpaper store, so removing the selection is what puts the
        //    user's real wallpaper back and releases the copy.
        for target in lockScreen.targets(showing: ids) {
            do {
                try await lockScreen.remove(target: target)
            } catch {
                applyError = error.localizedDescription
            }
        }

        // 3. The manifest and the files, through the writer so a download
        //    finishing in the same moment cannot lose its own entry. Off the
        //    main actor: a batch delete can be dozens of large files.
        let root = self.root
        if let updated = try? await Task.detached(priority: .utility, operation: {
            try LibraryWriter.delete(ids: ids, root: root)
        }).value {
            manifest = updated
        }

        // 4. Every list that points at it by id. Left alone, these are the
        //    dead references the old removal paths kept leaving behind.
        let (prunedPlaylists, emptied) = PlaylistStore.pruned(playlists, removing: ids)
        if prunedPlaylists != playlists {
            playlists = prunedPlaylists
            savePlaylists()
        }
        if let running = activePlaylistID, emptied.contains(running) {
            let name = playlists.first { $0.id == running }?.name ?? "The playlist"
            stopPlaylist()
            deleteNotice = "\(name) has no wallpapers left, so it stopped."
        }
        let (prunedAutomations, emptiedAutomations) =
            AutomationStore.pruned(automations, removing: ids)
        if prunedAutomations != automations {
            automations = prunedAutomations
            saveAutomations()
        }
        if let running = activeAutomationID, emptiedAutomations.contains(running) {
            let name = automations.first { $0.id == running }?.name ?? "The automation"
            stopAutomation()
            deleteNotice = "\(name) has no wallpapers left, so it stopped."
        }

        if recentIDs.contains(where: { ids.contains($0) }) {
            recentIDs.removeAll { ids.contains($0) }
            defaults.set(recentIDs, forKey: "recents")
        }
        if let heroID, ids.contains(heroID) { self.heroID = nil }
        // A catalog wallpaper still has a card to show after its download is
        // deleted. A personal import does not, so its open preview would sit
        // there as an empty layer.
        if let previewItem, ids.contains(previewItem.id), item(id: previewItem.id) == nil {
            self.previewItem = nil
        }

        recomputeSize()
    }

    // MARK: - Storage

    /// The only wallpapers Clear keeps: whatever is on screen right now, on
    /// any display or on the lock screen.
    ///
    /// Playlist members used to be protected too, which quietly defeated the
    /// point: a user with everything in one playlist pressed Clear and freed
    /// nothing. A playlist that shrinks still works, and F1d strips the dead
    /// ids out of it.
    var protectedWallpaperIDs: Set<String> {
        var ids = Set<String>()
        if let all = config.allDisplays?.wallpaperID { ids.insert(all) }
        for assignment in config.perDisplay.values { ids.insert(assignment.wallpaperID) }
        ids.formUnion(lockScreen.activeWallpaperIDs)
        return ids
    }

    /// What Clear is about to do, so the confirmation can say it out loud
    /// instead of describing the rules and leaving the user to do the sums.
    struct ClearPlan {
        var removed: [WallpaperEntry]
        var kept: Int
        var personal: Int
        var bytes: Int64

        var isEmpty: Bool { removed.isEmpty }
    }

    var clearPlan: ClearPlan {
        let keep = protectedWallpaperIDs
        let remote = Set(catalog.map(\.id))
        let removed = manifest.wallpapers.filter { !keep.contains($0.id) }
        return ClearPlan(
            removed: removed,
            kept: manifest.wallpapers.count - removed.count,
            personal: removed.filter { !remote.contains($0.id) }.count,
            bytes: removed.reduce(0) { $0 + $1.sizeBytes } + PreviewCache.sizeOnDisk()
        )
    }

    func clearDownloadedCache() {
        let plan = clearPlan
        let doomed = plan.removed.map(\.id)
        Task {
            // Clear keeps whatever is playing, and the lock-screen wallpaper
            // is in that set. Tearing the lock screen down here contradicted
            // that: the file was spared and the wallpaper disappeared anyway,
            // because clearAll restores Apple's stores and unregisters the
            // extension. So it only runs when there is no selection to lose,
            // where its job is sweeping leftovers rather than undoing a
            // wallpaper the user is still using.
            if lockScreen.activeWallpaperIDs.isEmpty {
                await lockScreen.clearAll()
            }
            // Re-downloadable and never counted in the library size, so it is
            // never mentioned anywhere: 20 MB of streamed previews that only
            // Clear can reach.
            PreviewCache.clear()
            if let updated = try? await Task.detached(priority: .utility, operation: {
                [root] in try LibraryWriter.delete(ids: Set(doomed), root: root)
            }).value {
                manifest = updated
            }
            let (pruned, _) = PlaylistStore.pruned(playlists, removing: Set(doomed))
            if pruned != playlists {
                playlists = pruned
                savePlaylists()
            }
            let (prunedAutomations, _) = AutomationStore.pruned(automations, removing: Set(doomed))
            if prunedAutomations != automations {
                automations = prunedAutomations
                saveAutomations()
            }
            recentIDs.removeAll { doomed.contains($0) }
            defaults.set(recentIDs, forKey: "recents")
            if let heroID, doomed.contains(heroID) { self.heroID = nil }
            // After the delete, so files it has just released are seen as
            // unreferenced in the same pass.
            let swept = (try? await Task.detached(priority: .utility, operation: {
                [root] in try LibraryWriter.sweepOrphans(root: root)
            }).value) ?? 0
            clearStatus = Self.clearSummary(plan: plan, swept: swept)
            recomputeSize()
            objectWillChange.send()
        }
    }

    /// Clear says what it is about to do, but the confirmation cannot predict
    /// the swept leftovers: those files are not in the manifest, so nothing
    /// knows their size until they are found. Saying what actually happened is
    /// the only way that part is ever visible.
    private static func clearSummary(plan: ClearPlan, swept: Int64) -> String {
        var parts: [String] = []
        if !plan.removed.isEmpty {
            let count = plan.removed.count
            parts.append("\(count) \(count == 1 ? "wallpaper" : "wallpapers") removed")
            parts.append("about \(formatSize(plan.bytes + swept)) freed")
        } else if swept > 0 {
            parts.append("\(formatSize(swept)) of leftovers swept")
        }
        return parts.isEmpty ? "Nothing to clear" : parts.joined(separator: " · ")
    }

    /// Manual per-wallpaper space control: delete the local copy of one
    /// catalog wallpaper (it stays in Explore, re-downloadable anytime).
    /// It only removes the download, so it is the same job as a delete and
    /// goes through the same path rather than keeping a second, thinner one.
    /// That includes the confirmation: this was the last way to destroy a
    /// wallpaper without being asked first.
    func removeDownload(_ item: WallpaperItem) {
        guard item.remote != nil, item.local != nil else { return }
        requestDelete([item])
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

/// Readable reason for a failed import. The engine's own descriptions carry a
/// whole `NSError` dump inside them, which is right for a terminal and wrong
/// for an alert, so each case gets a plain sentence instead.
func importFailureReason(_ error: Error) -> String {
    if let transcode = error as? TranscodeError {
        switch transcode {
        case .noVideoTrack:
            return "It has no video track."
        case .readerFailed:
            return "It could not be read. The file may be damaged, or in a format macOS cannot open."
        case .writerFailed:
            return "It could not be converted to HEVC."
        }
    }
    if error is ThumbnailError { return "A picture could not be taken from it." }
    return error.localizedDescription
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

/// Runs one master download and reports how far along it is.
///
/// Two things about `URLSession` shape this class. Iterating
/// `URLSession.bytes` yields one `UInt8` at a time, which turned a 60 MB
/// master into 60 million async iterations and held the transfer far below
/// what the connection could do, so the byte counts have to come from a
/// delegate. And a delegate handed to `download(from:delegate:)` is never
/// asked for them: `URLSession.shared` ignores per-task delegates entirely,
/// and even a session of our own only routes `didWriteData` to the delegate
/// it was **created** with. That is why the ring on the card sat at zero for
/// a whole download and then vanished. So this owns its session, is the
/// session's delegate, and bridges the classic callbacks back to `async`.
private final class MasterDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Double) -> Void

    /// Guards `continuation`, `settled` and `failure`, which the delegate
    /// queue and the awaiting task both touch.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    private var failure: Error?

    /// Progress is published to the main actor, and a 60 MB file produces
    /// roughly a thousand callbacks. Publishing every one would redraw the
    /// grid a hundred times a second for a bar a hundred pixels wide, so a
    /// step of 1% is the most anyone can see anyway.
    private var lastReported = -1.0

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Downloads `url` and leaves the file at `destination`.
    func run(url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        // The session holds its delegate strongly until it is invalidated,
        // so without this every download leaks a session and a delegate.
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    private func settle(_ result: Result<Void, Error>) {
        lock.lock()
        guard !settled, let waiting = continuation else { lock.unlock(); return }
        settled = true
        continuation = nil
        lock.unlock()
        waiting.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        // Capped below 1 so the bar never reads finished while the file is
        // still being moved into place and the thumbnail fetched.
        let value = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.99)
        guard value - lastReported >= 0.01 || lastReported < 0 else { return }
        lastReported = value
        onProgress(value)
    }

    /// The temporary file is deleted the moment this returns, so the move has
    /// to happen here rather than after the download is awaited.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let manager = FileManager.default
        // Without this an error page would be written straight into Masters
        // as a .mov and only fail later, when something tried to play it.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            failure = URLError(.badServerResponse)
            return
        }
        do {
            try? manager.removeItem(at: destination)
            try manager.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            settle(.failure(error))
        } else if let failure {
            settle(.failure(failure))
        } else {
            settle(.success(()))
        }
    }
}

/// Puts the master at `destination`: a copy for the bundled wallpaper's
/// `file://` URL, a real download with progress for anything else.
private func fetchMaster(
    from source: URL,
    to destination: URL,
    progress: @escaping (Double) -> Void
) async throws {
    let manager = FileManager.default
    try? manager.removeItem(at: destination)

    // The bundled 4K wallpaper is already inside the app, so its "download"
    // is a local copy and finishes immediately.
    if source.isFileURL {
        try manager.copyItem(at: source, to: destination)
        progress(0.99)
        return
    }

    try await MasterDownload(destination: destination, onProgress: progress).run(url: source)
}

/// Small reader that also works for the bundled wallpaper's `file://` URLs.
private func loadData(from url: URL) async throws -> Data {
    if url.isFileURL { return try Data(contentsOf: url) }
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw URLError(.badServerResponse)
    }
    return data
}

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

    do {
        try await fetchMaster(from: remote.video, to: destination, progress: progress)
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }

    // Thumbnail: prefer the hosted JPEG, fall back to extracting a frame.
    if let data = try? await loadData(from: remote.thumbnail) {
        try? data.write(to: thumbDestination, options: .atomic)
    }
    if !FileManager.default.fileExists(atPath: thumbDestination.path) {
        try? generateThumbnail(video: destination, destination: thumbDestination)
    }

    let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? remote.sizeBytes

    let entry = WallpaperEntry(
        id: remote.id,
        title: remote.title,
        category: remote.category,
        file: "Masters/\(remote.id).mov",
        thumbnail: "Thumbnails/\(remote.id).jpg",
        width: remote.width,
        height: remote.height,
        fps: remote.fps,
        duration: remote.duration,
        sizeBytes: sizeBytes
    )
    try LibraryWriter.update(root: root) { manifest in
        // Re-downloading something already listed replaces its entry rather
        // than adding a second one with the same id.
        manifest.wallpapers.removeAll { $0.id == entry.id }
        manifest.wallpapers.append(entry)
    }
    progress(1)
}

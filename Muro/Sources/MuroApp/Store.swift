import SwiftUI
import AppKit
import MuroKit
import IOKit
import IOKit.ps

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
    /// Set from `AppStore.likedIDs` when the item is built, not read out of
    /// the library entry. A like has to work on a wallpaper that has never
    /// been downloaded, and an undownloaded one has no library entry to
    /// carry the flag. See `AppStore.likedIDs`.
    var liked: Bool = false
    var isDownloaded: Bool { local != nil }
    /// A video the person imported themselves. It has no catalog entry, and
    /// the importer files it under its own category, which is what tells it
    /// apart from a download while the catalog cannot be reached (then no
    /// download has a catalog entry either).
    var isPersonalImport: Bool { remote == nil && local?.category == importedVideoCategory }
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

/// Where a wallpaper is being put.
///
/// `all` was called "Both" while there were two of them. The screen saver is
/// the third, and it is a separate key in Apple's own store from the one the
/// lock screen renders, so it is set separately here too.
enum ApplySurface: String, CaseIterable {
    case all = "All", desktop = "Desktop", lockscreen = "Lockscreen"
    case screensaver = "Screensaver"

    /// Whether this choice covers Muro's own desktop engine.
    var coversDesktop: Bool { self == .desktop || self == .all }
    /// Whether it covers the Apple-managed surface the lock screen renders.
    var coversLockScreen: Bool { self == .lockscreen || self == .all }
    /// Whether it covers the screen saver.
    var coversScreenSaver: Bool { self == .screensaver || self == .all }

    /// The Apple store roles this choice writes, in the order they are applied.
    var appleSurfaces: [AppleWallpaperStore.Surface] {
        var out: [AppleWallpaperStore.Surface] = []
        if coversLockScreen { out.append(.desktop) }
        if coversScreenSaver { out.append(.screenSaver) }
        return out
    }

    /// Whether macOS 26 is needed for this choice.
    var needsAppleExtension: Bool { self != .desktop }
}

/// What to call the screen built into this Mac.
///
/// macOS calls it "Built-in Retina Display", which is accurate and is not how
/// anyone thinks about it. People call it their MacBook. It cannot simply be
/// hardcoded to that either: Muro runs on an iMac too, where the built-in
/// screen is not a MacBook, and the label has to be right on a machine nobody
/// working on Muro owns.
///
/// Two sources, because neither covers every Mac on its own. Apple Silicon
/// publishes a marketing name like "MacBook Pro (14-inch, M3, 2023)" in the
/// device tree, while its `hw.model` is only "Mac15,3" and names no product.
/// Intel Macs have no such device-tree entry but do have a readable
/// `hw.model`, "MacBookPro16,1". A battery settles it either way as a last
/// resort, since only a portable has one. Muro ships for both architectures,
/// so both paths are live.
enum MacHardware {
    /// Resolved once. None of this can change while the app is running.
    static let builtInName: String = {
        let model = (deviceTreeProductName() ?? modelIdentifier() ?? "").lowercased()
        if model.hasPrefix("macbook") { return "MacBook" }
        if model.hasPrefix("imac") { return "iMac" }
        if hasInternalBattery() { return "MacBook" }
        // A Mac mini, Studio or Pro has no built-in screen, so this is only
        // reached when the built-in test itself guessed. Say the honest thing
        // rather than name a machine this might not be.
        return "Built-in"
    }()

    private static func deviceTreeProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "product-name" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        // The device tree stores it as a null-terminated C string in a data
        // blob, not as a CFString.
        if let data = raw as? Data {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return raw as? String
    }

    private static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &chars, &size, nil, 0) == 0 else { return nil }
        return String(cString: chars)
    }

    private static func hasInternalBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return sources.contains { source in
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { return false }
            return desc[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType
        }
    }
}

/// One place a wallpaper can be showing.
///
/// A Mac with two monitors has five of these: a desktop and a lock screen on
/// each, and one screen saver for the whole machine. Muro can hold a different
/// wallpaper in every one, so a label that only ever named the display could
/// not tell them apart.
struct AppliedPlace: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case desktop
        case lockScreen
        /// One setting for the whole Mac, so it has no display of its own.
        /// See LockScreenService.storeTargetKey.
        case screenSaver
    }

    /// Nil for the screen saver, which is not a per-display place.
    let display: DisplayInfo?
    let kind: Kind

    var id: String { (display?.id ?? "all") + "#" + kind.rawValue }

    /// For the small chip on a card. Upper case, and short, because it has a
    /// card corner to fit into.
    var chipLabel: String {
        switch kind {
        case .desktop: return display?.chipLabel ?? "ALL DISPLAYS"
        case .lockScreen: return (display?.chipLabel ?? "ALL DISPLAYS") + " LOCK"
        case .screenSaver: return "SCREEN SAVER"
        }
    }

    /// For anywhere there is room to read a sentence.
    var fullLabel: String {
        switch kind {
        case .desktop: return display?.displayName ?? "all displays"
        case .lockScreen: return "\(display?.displayName ?? "all displays") lock screen"
        case .screenSaver: return "the screen saver"
        }
    }
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

    /// What to call this display anywhere it is named.
    ///
    /// The built-in screen is named after the machine; every other display is
    /// named by the display itself, which is what makes this work for any
    /// monitor of any brand without Muro knowing a single brand name.
    var displayName: String {
        isBuiltIn || name.localizedCaseInsensitiveContains("built-in")
            ? MacHardware.builtInName
            : name
    }

    var chipLabel: String { displayName.uppercased() }
}

/// A running playlist or automation that lost its last wallpaper to a delete.
///
/// The title travels with the message because both stop the same way, and the
/// alert used to hardcode "Playlist stopped" over both of them, so deleting the
/// last wallpaper out of a running automation announced a playlist that had not
/// stopped and might not exist.
struct StopNotice: Equatable {
    let title: String
    let message: String
}

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()
    let root = LibraryManifest.defaultRoot()
    let statsSampler = StatsSampler()

    enum Tab: String, CaseIterable, Identifiable {
        case home = "Home", explore = "Explore", apple = "Apple", library = "Library"
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
    /// How far through the file being imported now, 0 to 1, or nil when no
    /// import is running. The top bar's import button draws it as a ring, so
    /// an import started from Home is seen on Home.
    @Published private(set) var importProgress: Double?
    /// A short line for the import bar after an import, such as a video that
    /// was already there. It clears itself.
    @Published private(set) var importNote: String?
    @Published var searchText = ""
    @Published var searchActive = false
    /// The What's New sheet. On the store rather than in the top bar so
    /// anything else that should open it later (the menu bar, a first run
    /// after an update) has one switch to flip.
    @Published var whatsNewOpen = false
    /// The Apple section's notice card (`AppleNoticeCard`). Raised each time
    /// the section opens, until the person ticks "Do not show this message
    /// again".
    @Published var appleNoticeOpen = false
    @Published var previewItem: WallpaperItem?
    @Published var previewMode = "smooth"
    @Published var applySurface: ApplySurface = .all
    @Published var heroID: String?
    @Published var libraryBytes: Int64 = 0
    /// The part of the library that came from the Apple section: aerials and
    /// Apple's still pictures. Shown on its own line in Settings.
    @Published var appleDownloadBytes: Int64 = 0
    /// What was downloaded in the Apple section, by id: Muro's own copies of
    /// aerials and the sides of Apple's still pictures. Read off the disk with
    /// the size, so the Library can list them without looking at every file
    /// each time it draws.
    @Published private(set) var appleDownloadedIDs: Set<String> = []
    /// Screen savers the person added, like XScreenSaver, for the Library.
    /// They live in macOS's own folders, so `refreshImportedScreenSavers()`
    /// reads them again when the Library opens and after an import or a
    /// delete.
    @Published var importedScreenSavers: [AppleAerial] = []
    /// What the last Clear actually did. Shown in Settings, because a Clear
    /// that frees nothing otherwise looks identical to one that never ran.
    @Published var clearStatus: String?
    @Published var recentIDs: [String] = []
    @Published var automations: [Automation] = []
    @Published var activePlaylistID: String?
    @Published var activeAutomationID: String?
    /// What each place is playing. The two above are the desktop's alone,
    /// which is what the menu bar's back, next and shuffle buttons move.
    @Published private(set) var nowPlaying: [SchedulePlace: ScheduleRef] = [:]
    @Published var applyingLockScreen = false
    @Published var applyError: String?
    /// Kept separate from `applyError` so each alert can say what actually
    /// went wrong instead of sharing one misleading title.
    @Published var importError: String?
    /// Set when a delete had a consequence the user did not ask for and
    /// cannot see, such as a running playlist losing its last wallpaper.
    @Published var deleteNotice: StopNotice?
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
    /// A playlist or automation played on the lock screen or the screen saver
    /// runs in one of these, beside the desktop's, so each place can play its
    /// own at the same time. Their state is saved under names of their own,
    /// and the desktop's stays where it always was.
    private let lockScheduler = AutomationScheduler(keyPrefix: "lockScreen.")
    private let saverScheduler = AutomationScheduler(keyPrefix: "screenSaver.")
    /// The last lock screen or screen saver step asked for. Every step waits
    /// for the one before it, on either place: the first step of each is a
    /// full apply to Apple's store, and two of those at once would each save
    /// the record the other had not finished writing.
    private var placeSteps: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private lazy var lockScreen = LockScreenService(root: root)
    /// The still frame behind the video, so the desktop still shows the right
    /// wallpaper when Muro is not running. See DesktopStillService.
    private lazy var desktopStill = DesktopStillService(root: root)
    /// Apple's pictures and drawn wallpapers, which only macOS can show.
    /// See MacOSWallpaperService.
    lazy var macOSWallpapers = MacOSWallpaperService(root: root)

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reloadFromDisk()
        recentIDs = defaults.stringArray(forKey: "recents") ?? []
        scheduler.apply = { [weak self] id in
            guard let self, let item = self.item(id: id) else { return }
            self.setWallpaper(item, mode: self.defaultMode(for: item), fromSchedule: true)
        }
        scheduler.currentIDForOrdering = { [weak self] in self?.currentAppliedID }
        for (placeScheduler, role) in [
            (lockScheduler, AppleWallpaperStore.Surface.desktop),
            (saverScheduler, AppleWallpaperStore.Surface.screenSaver),
        ] {
            placeScheduler.apply = { [weak self] id in self?.showScheduledStep(id, on: role) }
            placeScheduler.currentIDForOrdering = { [weak self] in
                self?.lockScreen.rotationWallpaperID(role)
            }
        }
        syncScheduler()
        watchRoot()
        recomputeSize()
        ShareFile.clear()
        rememberDisplays()
        // Installs that applied a wallpaper before this shipped have never had
        // a still written, and a display plugged in while Muro was closed has
        // no still either.
        desktopStill.reconcile(
            config: config, manifest: stillManifest, lockScreenDisplays: lockScreenOwnedDisplays
        )
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
        let heal = Task { await lockScreen.healIfNeeded() }
        // A lock screen or screen saver step due at launch writes the same
        // store, so the first one waits for this. See `placeSteps`.
        placeSteps = Task { await heal.value }
        // A monitor plugged in after Muro started has no desktop picture of
        // its own yet, and one unplugged leaves a record to give back.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rememberDisplays()
                self.desktopStill.reconcile(
                    config: self.config,
                    manifest: self.stillManifest,
                    lockScreenDisplays: self.lockScreenOwnedDisplays
                )
            }
        }
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
        let liked = likedIDs
        for entry in manifest.wallpapers where seen.insert(entry.id).inserted {
            out.append(WallpaperItem(
                local: entry, remote: remoteByID[entry.id], liked: liked.contains(entry.id)
            ))
        }
        for remote in catalog where !seen.contains(remote.id) {
            out.append(WallpaperItem(
                local: nil, remote: remote, liked: liked.contains(remote.id)
            ))
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

    /// What Explore browses: `newestFirstItems` without the videos the person
    /// imported. Those show in the Library only (owner, 2026-09-30); Explore
    /// is the catalog, and an import there added a "My Videos" pill and
    /// counted itself into the total (full check, 2026-10-01).
    var exploreItems: [WallpaperItem] {
        newestFirstItems.filter { !$0.isPersonalImport }
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
    /// A draw made before the catalog arrived is provisional, and this is the
    /// one case that has to force a re-draw. A cold launch renders Home before
    /// the fetch lands, so the pool is only what is downloaded, and with
    /// twelve or more of those the draw still comes out full size. Counting
    /// the drawn ids could not tell that apart from a real draw, so the local
    /// twelve stuck for the whole day and the catalog never reached the row.
    /// The draw now records whether it saw a catalog, and one that did not is
    /// re-drawn as soon as one arrives.
    ///
    /// Everything else keeps today's draw. Deleting a wallpaper leaves an id
    /// that no longer resolves, and re-drawing on that would re-shuffle the
    /// row on every redraw for the rest of the day, which is why what was
    /// *drawn* is compared rather than what still resolves. Staying offline
    /// keeps the local twelve rather than re-shuffling them forever, because
    /// an empty catalog is not a better pool to draw from.
    ///
    /// The latest drop is excluded because it has its own row directly above.
    var pickItems: [WallpaperItem] {
        let drop = Set(latestDropItems.map(\.id))
        // The person's own videos are not Muro's to pick; they stay in the
        // Library like everywhere else outside it.
        let pool = items.filter { !drop.contains($0.id) && !$0.isPersonalImport }
        let today = Calendar.current.startOfDay(for: Date())
        let drawnIDs = defaults.stringArray(forKey: "pickIDs") ?? []
        let sawCatalog = !catalog.isEmpty
        let provisional = sawCatalog && !defaults.bool(forKey: "pickDrewFromCatalog")
        if let drawnDay = defaults.object(forKey: "pickDrawDay") as? Date,
           drawnDay == today,
           !provisional,
           drawnIDs.count >= min(AppStore.pickCount, pool.count) {
            return drawnIDs.compactMap { item(id: $0) }
        }
        let drawn = Array(pool.shuffled().prefix(AppStore.pickCount))
        defaults.set(today, forKey: "pickDrawDay")
        defaults.set(drawn.map(\.id), forKey: "pickIDs")
        defaults.set(sawCatalog, forKey: "pickDrewFromCatalog")
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

    /// Explore's category buttons, in the catalog's order.
    ///
    /// The order used to be first appearance in `items`, which lists what is
    /// downloaded first, so downloading an Abstract wallpaper moved Abstract
    /// to second place and deleting it moved it back: the buttons jumped
    /// under the pointer (full check, 2026-10-01). The catalog decides now,
    /// and a category only downloads still have (one the catalog dropped, or
    /// any while offline) follows it.
    var categories: [String] {
        if let cachedCategories { return cachedCategories }
        var seen = Set<String>()
        let local = items.filter { !$0.isPersonalImport }.map(\.category)
        let out = (catalog.map(\.category) + local).filter { seen.insert($0).inserted }
        cachedCategories = out
        return out
    }

    /// A dictionary lookup. This is called from view bodies far more often
    /// than anything else here, so it must not walk the library.
    func item(id: String) -> WallpaperItem? {
        // Apple's aerials are not in `items`, and must not be: Explore and the
        // Library list what Muro publishes and what the user owns, and Apple's
        // library has a page of its own. Everything that resolves an id rather
        // than browsing a list still has to find them, though, or the menu bar
        // and the Home header go blank the moment one is applied.
        if AppleAerials.isAppleID(id) { return appleItem(id: id) }
        if let cachedItemsByID { return cachedItemsByID[id] }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedItemsByID = byID
        return byID[id]
    }

    /// One of Apple's aerials, read straight from Apple's manifest.
    ///
    /// Cheap: `AppleAerials.cachedAerials` re-reads only when Apple's manifest
    /// itself changes, and this is a lookup in the result.
    func appleItem(id: String) -> WallpaperItem? {
        if id.hasPrefix(AppleScreenSavers.idPrefix) {
            return AppleScreenSavers.cached().first { $0.id == id }.map(appleWallpaperItem)
        }
        return AppleAerials.cachedAerials(libraryRoot: root)?
            .first { $0.id == id }
            .map(appleWallpaperItem)
    }

    /// The hero only ever plays LOCAL files (owner, 2026-07-19): a fresh
    /// install always shows exactly one wallpaper — the bundled 4K — and once
    /// the user has downloads, the hero moves among those. It never streams.
    ///
    /// The person's own imported videos are never featured here: whatever is
    /// imported shows only in the Library (owner, 2026-09-30). The full check
    /// found them in the hero strip as well as in Explore (2026-10-01).
    var heroItem: WallpaperItem? {
        if let heroID, let item = item(id: heroID), heroPlayable(item), !item.isPersonalImport {
            return item
        }
        if let applied = currentAppliedID, let item = item(id: applied), item.isDownloaded,
           !item.isPersonalImport {
            return item
        }
        if let firstLocal = localItems.first(where: { !$0.isPersonalImport }) { return firstLocal }
        if let bundled = item(id: BundledWallpaper.id) { return bundled }
        return BundledWallpaper.fallbackEntry.map {
            WallpaperItem(local: nil, remote: $0, liked: likedIDs.contains($0.id))
        }
    }

    func heroPlayable(_ item: WallpaperItem) -> Bool {
        item.isDownloaded
            || (item.id == BundledWallpaper.id && BundledWallpaper.videoURL != nil)
    }

    /// Selector strip under the hero: everything the hero can actually play.
    var heroSelectorItems: [WallpaperItem] {
        var out = localItems.filter { !$0.isPersonalImport }
        if BundledWallpaper.videoURL != nil,
           !out.contains(where: { $0.id == BundledWallpaper.id }) {
            if let bundled = item(id: BundledWallpaper.id) {
                out.insert(bundled, at: 0)
            } else if let entry = BundledWallpaper.fallbackEntry {
                out.insert(
                    WallpaperItem(local: nil, remote: entry, liked: likedIDs.contains(entry.id)),
                    at: 0
                )
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
        loadLikes()
        config = EngineConfig.load(root: root)
        playlists = PlaylistStore.load(root: root)
        automations = AutomationStore.load(root: root)
        syncScheduler()
        // A wallpaper set from the command line, or by the engine, has to move
        // the desktop picture too. Cheap when nothing changed: a still that is
        // already on disk is set in this same turn, and a screen already
        // showing it is left alone.
        desktopStill.reconcile(
            config: config, manifest: stillManifest, lockScreenDisplays: lockScreenOwnedDisplays
        )
    }

    /// The scheduler owns the running schedule; the store owns what is on
    /// disk. This is the one place the two meet.
    private func syncScheduler() {
        scheduler.update(automations: automations, playlists: playlists)
        activePlaylistID = scheduler.activePlaylistID
        activeAutomationID = scheduler.activeAutomationID
        lockScheduler.update(automations: automations, playlists: playlists)
        saverScheduler.update(automations: automations, playlists: playlists)
        var playing: [SchedulePlace: ScheduleRef] = [:]
        for place in SchedulePlace.allCases {
            let runner = placeScheduler(for: place)
            if let id = runner.activePlaylistID {
                playing[place] = .playlist(id)
            } else if let id = runner.activeAutomationID {
                playing[place] = .automation(id)
            }
        }
        // Only on a change: this runs on every write to the library folder.
        if playing != nowPlaying { nowPlaying = playing }
    }

    /// The desktop's is the scheduler Muro always had. The lock screen and the
    /// screen saver have one each beside it.
    private func placeScheduler(for place: SchedulePlace) -> AutomationScheduler {
        switch place {
        case .desktop: return scheduler
        case .lockScreen: return lockScheduler
        case .screenSaver: return saverScheduler
        }
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
            // Videos kept in another folder sit behind a link, which counting
            // the library does not follow. See `DownloadFolder`.
            var folders = [root]
            if case .custom(let folder) = DownloadFolder.location(root: root) {
                folders.append(folder)
            }
            // The copies staged for the lock screen and the screen saver are
            // Muro's disk use too, and they were in no number anywhere: a
            // deleted wallpaper could sit there at 135 MB a copy with the
            // Storage row none the wiser. A playlist's step there is a hard
            // link to the library's own file, which is why every file is
            // counted once however many folders link it.
            folders.append(LockScreenService.stagedVideosURL)
            let sum = uniqueFileBytes(folders)
            let apple = AppleAerials.cacheSize(libraryRoot: root)
            let appleIDs = Set(AppleAerials.downloadedFiles(libraryRoot: root)
                .map { $0.deletingPathExtension().lastPathComponent })
            await MainActor.run {
                AppStore.shared.libraryBytes = sum
                AppStore.shared.appleDownloadBytes = apple
                if AppStore.shared.appleDownloadedIDs != appleIDs {
                    AppStore.shared.appleDownloadedIDs = appleIDs
                }
            }
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

    /// The other way to give, added 2026-09-21. Ko-fi takes a card without an
    /// account, which GitHub Sponsors cannot do, so both sit in the row.
    static let kofiURL = URL(string: "https://ko-fi.com/mrrockysl")!

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

    /// Forget the outcome of a finished check, so the next place that shows it
    /// starts by offering the check rather than reporting an old answer.
    ///
    /// "Muro is up to date" and "Could not check" answer a question that was
    /// asked at some point in the past, and a panel that reopens still showing
    /// one of them looks like it is reporting something current. "5.0 is
    /// available" is cleared too: the fact survives in `latestRelease`, which
    /// is what draws the badge, so the row goes back to offering the check
    /// with a flag on it rather than skipping the step.
    func clearUpdateCheckResult() {
        guard updateCheck != .idle, updateCheck != .checking else { return }
        updateCheck = .idle
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
        previewMode = defaultMode(for: item)
    }

    /// The 59 / 30 switch in the detail bar.
    ///
    /// It only chose what the next Set Wallpaper would use, so flipping it on
    /// a wallpaper already on screen changed nothing: the switch said 30, the
    /// bar said Applied, and the desktop went on playing 59 until the
    /// wallpaper was set again (full check, 2026-10-01). Where this wallpaper
    /// is on a desktop now, the switch takes effect there at once, making the
    /// 30 fps copy first if it is not made yet. The lock screen and the
    /// screen saver keep the copy they were given; they play for seconds at a
    /// time.
    func setPreviewMode(_ mode: String, for item: WallpaperItem) {
        previewMode = mode
        guard let entry = item.local, !AppleAerials.isAppleID(entry.id), entry.fps > 40 else { return }
        let onScreen = (config.allDisplays.map { $0.wallpaperID == entry.id && $0.mode != mode } ?? false)
            || config.perDisplay.values.contains { $0.wallpaperID == entry.id && $0.mode != mode }
        guard onScreen else { return }
        Task {
            if mode == "efficient", entry.efficientFile == nil {
                guard await ensureEfficientVariant(entry) else { return }
            }
            // Read again after the copy is made: the desktop may have moved on.
            if config.allDisplays?.wallpaperID == entry.id { config.allDisplays?.mode = mode }
            for (key, assignment) in config.perDisplay where assignment.wallpaperID == entry.id {
                config.perDisplay[key]?.mode = mode
            }
            saveConfig()
        }
    }

    func defaultMode(for item: WallpaperItem) -> String {
        // See `applyWallpaper`: an Apple aerial has no Efficient variant and
        // must never be offered one.
        if AppleAerials.isAppleID(item.id) { return "smooth" }
        let def = defaults.string(forKey: "defaultMode") ?? "smooth"
        return (def == "efficient" && item.fps > 40) ? "efficient" : "smooth"
    }

    /// Lock screens need macOS 26 and the embedded extension.
    var lockScreenAvailable: Bool { lockScreen.isAvailable }
    var lockScreenWallpaperID: String? { lockScreen.activeWallpaperID }
    var screenSaverWallpaperID: String? { lockScreen.screenSaverWallpaperID }

    /// Applying to one surface leaves the other alone.
    ///
    /// Desktop used to mean "desktop and not the lock screen", so setting a new
    /// desktop wallpaper silently tore the lock screen wallpaper out. Nobody
    /// asked for that: choosing where a wallpaper goes is not the same as
    /// asking for the wallpaper already somewhere else to be removed. Removing
    /// one is its own action, the Remove button on that surface.
    ///
    /// `fromSchedule` is set only by a playlist or automation step. Anything
    /// else is somebody choosing a wallpaper for a place, and that stops
    /// whatever schedule was playing there: left running, it put its own
    /// wallpaper back at its next step, so the choice lasted a minute and
    /// vanished with "Applied" still showing (full check, 2026-10-01).
    func setWallpaper(
        _ item: WallpaperItem,
        mode: String,
        target: ApplyTarget = .all,
        surface: ApplySurface? = nil,
        fromSchedule: Bool = false
    ) {
        // A wallpaper whose video was moved or deleted outside Muro keeps its
        // entry and its picture, and setting it used to say "Applied" while
        // nothing played and the desktop fell back to an old still (full
        // check, 2026-10-01). Checked before anything changes, so a failed
        // pick does not stop a playlist either. A playlist step just skips.
        if let missing = missingVideo(item) {
            if !fromSchedule {
                applyError = "Muro can't find the video for “\(missing)”. "
                    + "It was moved or deleted outside Muro. "
                    + "Delete it in the Library, then download or import it again."
            }
            return
        }
        if !fromSchedule {
            stopSchedules(on: placesCovered(by: item, surface: surface ?? .desktop))
        }
        // Apple's pictures and the ones macOS draws are handed to macOS.
        if AppleAerials.isMacOSOnly(item.id) {
            showThroughMacOS(item, target: target, surface: surface ?? .desktop)
            return
        }
        guard item.local != nil else { return }
        Task {
            await applyWallpaper(
                item, mode: mode, target: target, surface: surface, fromSchedule: fromSchedule
            )
        }
    }

    /// The title of a wallpaper Muro has an entry for but no video file, or
    /// nil when its video is there (or it is one macOS shows itself).
    func missingVideo(_ item: WallpaperItem) -> String? {
        guard !AppleAerials.isMacOSOnly(item.id), let entry = item.local else { return nil }
        let master = resolveLibraryFile(entry.file, root: root)
        return FileManager.default.fileExists(atPath: master.path) ? nil : entry.title
    }

    private func applyWallpaper(
        _ item: WallpaperItem,
        mode: String,
        target: ApplyTarget,
        surface explicitSurface: ApplySurface?,
        fromSchedule: Bool = false
    ) async {
        guard var entry = item.local else { return }
        let surface = explicitSurface ?? .desktop
        // Apple ships these at 240 fps, so the Efficient rule below would fire
        // on every one of them, transcode 170 MB of somebody else's video and
        // write the result into `library.json`. Smooth only.
        let resolvedMode = AppleAerials.isAppleID(entry.id)
            ? "smooth"
            : (entry.fps > 40 ? mode : "smooth")

        if resolvedMode == "efficient", entry.efficientFile == nil {
            guard await ensureEfficientVariant(entry),
                  let refreshed = manifest.wallpapers.first(where: { $0.id == entry.id })
            else { return }
            entry = refreshed
        }

        // An All apply is committed to the desktop engine only after the
        // Apple-side transaction succeeds, so a failed extension/store write
        // cannot leave the UI in a silently half-applied state.
        if surface == .desktop {
            applyAssignment(
                id: entry.id, mode: resolvedMode, target: target, resume: !fromSchedule
            )
        }

        let appleSurfaces = surface.appleSurfaces
        if !appleSurfaces.isEmpty {
            guard lockScreenAvailable else {
                applyError = LockScreenServiceError.requiresTahoe.localizedDescription
                return
            }
            ensureAerialThumbnail(entry)
            let videoURL = resolveVideoURL(entry: entry, mode: resolvedMode, root: root)
            let thumbnailURL = resolveLibraryFile(entry.thumbnail, root: root)
            guard FileManager.default.fileExists(atPath: videoURL.path),
                  FileManager.default.fileExists(atPath: thumbnailURL.path)
            else {
                applyError = "The downloaded wallpaper files could not be found."
                return
            }

            applyingLockScreen = true
            defer { applyingLockScreen = false }
            do {
                // One pass per role. They write different keys in Apple's
                // store, so the screen saver does not displace the lock screen
                // and neither has to be given up for the other.
                for appleSurface in appleSurfaces {
                    let outcome = try await lockScreen.apply(
                        entry: entry,
                        videoURL: videoURL,
                        thumbnailURL: thumbnailURL,
                        target: target,
                        surface: appleSurface,
                        connectedDisplays: knownDisplayIDs
                    )
                    if outcome == .needsSystemSettings { lockScreenNeedsSystemSettings = true }
                }
                if surface == .all {
                    applyAssignment(
                        id: entry.id, mode: resolvedMode, target: target, resume: !fromSchedule
                    )
                } else {
                    pushRecent(entry.id)
                }
                objectWillChange.send()
                recomputeSize()
            } catch {
                applyError = error.localizedDescription
            }
        }
    }

    /// `resume` is false for a playlist or automation step. A wallpaper chosen
    /// by hand is meant to be seen moving, so it lifts a pause; a step is the
    /// schedule moving on by itself, and it used to lift the pause too, so a
    /// paused desktop started playing again at the next step (full check,
    /// 2026-10-01). A step taken while paused shows the new wallpaper's first
    /// frame and stays paused.
    private func applyAssignment(id: String, mode: String, target: ApplyTarget, resume: Bool = true) {
        let assignment = EngineConfig.Assignment(wallpaperID: id, mode: mode)
        switch target {
        case .all:
            config.allDisplays = assignment
            config.perDisplay = [:]
        case .display(let uuid):
            config.perDisplay[uuid] = assignment
        }
        if resume { config.paused = false }
        saveConfig()
        pushRecent(id)
    }

    /// One step of a playlist or automation on the lock screen (`.desktop`,
    /// the role the lock screen renders) or the screen saver. Queued behind
    /// the step before it. See `placeSteps`.
    private func showScheduledStep(_ id: String, on role: AppleWallpaperStore.Surface) {
        guard let item = item(id: id), let entry = item.local else { return }
        let mode = defaultMode(for: item)
        let previous = placeSteps
        placeSteps = Task { [weak self] in
            await previous?.value
            await self?.performScheduledStep(entry: entry, mode: mode, on: role)
        }
    }

    private func performScheduledStep(
        entry original: WallpaperEntry,
        mode: String,
        on role: AppleWallpaperStore.Surface
    ) async {
        guard lockScreenAvailable else { return }
        var entry = original
        let resolvedMode = entry.fps > 40 ? mode : "smooth"
        if resolvedMode == "efficient", entry.efficientFile == nil {
            guard await ensureEfficientVariant(entry),
                  let refreshed = manifest.wallpapers.first(where: { $0.id == entry.id })
            else { return }
            entry = refreshed
        }
        ensureAerialThumbnail(entry)
        let videoURL = resolveVideoURL(entry: entry, mode: resolvedMode, root: root)
        let thumbnailURL = resolveLibraryFile(entry.thumbnail, root: root)
        guard FileManager.default.fileExists(atPath: videoURL.path),
              FileManager.default.fileExists(atPath: thumbnailURL.path)
        else { return }
        do {
            let outcome = try await lockScreen.showInRotation(
                entry: entry,
                videoURL: videoURL,
                thumbnailURL: thumbnailURL,
                role: role,
                connectedDisplays: knownDisplayIDs
            )
            if outcome == .needsSystemSettings { lockScreenNeedsSystemSettings = true }
            objectWillChange.send()
        } catch {
            // What failed here fails the same way at the next step, so the
            // schedule stops rather than raising the same alert every time.
            (role == .screenSaver ? saverScheduler : lockScheduler).stopEverything()
            syncScheduler()
            applyError = error.localizedDescription
        }
    }

    /// Applied on every connected display (drives the "✓ Applied" state).
    func isFullyApplied(_ item: WallpaperItem) -> Bool {
        let connected = displays
        guard !connected.isEmpty else { return false }
        return appliedDisplays(for: item.id).count == connected.count
    }

    func isApplied(_ item: WallpaperItem, surface: ApplySurface, target: ApplyTarget) -> Bool {
        if AppleAerials.isMacOSOnly(item.id) {
            return isAppliedThroughMacOS(item, surface: surface, target: target)
        }
        let desktopApplied: Bool
        switch target {
        case .all:
            desktopApplied = isFullyApplied(item)
        case .display(let uuid):
            desktopApplied = config.assignment(forDisplayUUID: uuid)?.wallpaperID == item.id
        }
        let lockApplied = lockScreen.isApplied(wallpaperID: item.id, target: target)
        let saverApplied = lockScreen.isApplied(
            wallpaperID: item.id, target: target, surface: .screenSaver
        )
        switch surface {
        case .desktop: return desktopApplied
        case .lockscreen: return lockApplied
        case .screensaver: return saverApplied
        case .all: return desktopApplied && lockApplied && saverApplied
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
        // Emptying a place by hand is a choice for that place too; a schedule
        // left running would fill it again at its next step.
        stopSchedules(on: placesCovered(by: item, surface: surface))
        if AppleAerials.isMacOSOnly(item.id) {
            removeFromMacOS(item, target: target, surface: surface)
            return
        }
        if surface.coversDesktop {
            switch target {
            case .all:
                if config.allDisplays?.wallpaperID == item.id { config.allDisplays = nil }
                config.perDisplay = config.perDisplay.filter { $0.value.wallpaperID != item.id }
            case .display(let uuid):
                if config.allDisplays?.wallpaperID == item.id {
                    splitAllDisplays(except: uuid)
                }
                if config.perDisplay[uuid]?.wallpaperID == item.id {
                    config.perDisplay[uuid] = nil
                }
            }
            saveConfig()
        }
        let appleSurfaces = surface.appleSurfaces
        guard !appleSurfaces.isEmpty else { return }
        Task {
            do {
                for appleSurface in appleSurfaces {
                    try await lockScreen.remove(target: target, surface: appleSurface)
                }
                objectWillChange.send()
                recomputeSize()
            } catch {
                applyError = error.localizedDescription
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

    /// Issue #22. Both off by default, so no install behaves differently until
    /// someone turns one on.
    var playOnlyOnDesktop: Bool { config.playOnlyOnDesktop ?? false }
    var replayOnClearDesktop: Bool { config.replayOnClearDesktop ?? false }

    func setPlayOnlyOnDesktop(_ on: Bool) {
        config.playOnlyOnDesktop = on
        saveConfig()
    }

    func setReplayOnClearDesktop(_ on: Bool) {
        config.replayOnClearDesktop = on
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

    /// Internal rather than private so removing an Apple aerial can take it
    /// off the screen the same way a delete does, through the one path that
    /// also keeps the desktop picture in step.
    func saveConfig() {
        try? config.save(root: root)
        // Every apply, remove and clear lands here, including every playlist
        // and automation step, so this is the one place the desktop picture
        // has to be kept in step with.
        desktopStill.reconcile(
            config: config, manifest: stillManifest, lockScreenDisplays: lockScreenOwnedDisplays
        )
    }

    /// The library as the desktop picture sees it: Muro's own wallpapers and
    /// every aerial on this Mac. Apple's aerials are never written into
    /// `library.json`, so without them an aerial on the desktop had no picture
    /// to leave behind when Muro quits, and its still was swept as unknown.
    private var stillManifest: LibraryManifest {
        var combined = manifest
        combined.wallpapers += AppleAerials.libraryEntries(libraryRoot: root)
        return combined
    }

    /// Displays whose macOS wallpaper slot Muro's lock screen is sitting on.
    /// There is only one slot per display, so the desktop still has to leave
    /// those alone or it would throw the lock screen away.
    private var lockScreenOwnedDisplays: Set<String> {
        guard lockScreenAvailable else { return [] }
        return Set(displays.map(\.id).filter {
            lockScreen.ownsWallpaperSurface(displayUUID: $0)
                // An Apple picture set through macOS sits in the same slot.
                || macOSWallpapers.holdsDesktop(displayUUID: $0)
        })
    }

    /// Whether Muro's own lock screen sits on this display's slot. For the
    /// wallpapers macOS shows, which take that slot over.
    func lockScreenOwnsDisplay(_ uuid: String) -> Bool {
        lockScreen.ownsWallpaperSurface(displayUUID: uuid)
    }

    /// Takes Muro's own lock screen or screen saver off before macOS is given
    /// one of Apple's wallpapers for the same place.
    func removeLockScreenForMacOS(
        target: ApplyTarget, surfaces: [AppleWallpaperStore.Surface]
    ) async throws {
        try await lockScreen.remove(target: target, surfaces: surfaces)
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

    /// Every display Muro has seen, by UUID, whether it is plugged in now
    /// or not.
    var knownDisplayIDs: Set<String> {
        Set(defaults.stringArray(forKey: "knownDisplayIDs") ?? []).union(displays.map(\.id))
    }

    private func rememberDisplays() {
        let stored = defaults.stringArray(forKey: "knownDisplayIDs") ?? []
        let known = knownDisplayIDs
        if known.count != Set(stored).count { defaults.set(known.sorted(), forKey: "knownDisplayIDs") }
    }

    /// Takes one display out of an all-displays wallpaper: every other display
    /// keeps it as a wallpaper of its own, and `allDisplays` goes.
    ///
    /// Every display Muro has seen keeps it, not only the ones plugged in.
    /// Only the plugged-in ones used to, so changing the MacBook's wallpaper
    /// while the DELL was unplugged left the DELL with nothing; plugged back
    /// in, it showed a frozen still until it was set again (full check,
    /// 2026-10-01).
    func splitAllDisplays(except uuid: String) {
        guard let fallback = config.allDisplays else { return }
        for id in knownDisplayIDs where id != uuid && config.perDisplay[id] == nil {
            config.perDisplay[id] = fallback
        }
        config.allDisplays = nil
    }

    func appliedDisplays(for id: String) -> [DisplayInfo] {
        displays.filter { config.assignment(forDisplayUUID: $0.id)?.wallpaperID == id }
    }

    /// Everywhere this wallpaper is showing, desktops and lock screens both.
    ///
    /// The two are kept in different places, the desktop in `config` and the
    /// lock screen inside `LockScreenService`, which is why the chip used to
    /// know nothing about the lock screen and a wallpaper applied only there
    /// looked unapplied.
    func appliedPlaces(for id: String) -> [AppliedPlace] {
        if AppleAerials.isMacOSOnly(id) { return placesThroughMacOS(for: id) }
        var out: [AppliedPlace] = []
        for display in displays {
            if config.assignment(forDisplayUUID: display.id)?.wallpaperID == id {
                out.append(AppliedPlace(display: display, kind: .desktop))
            }
            if lockScreenAvailable,
               lockScreen.isApplied(wallpaperID: id, target: .display(display.id)) {
                out.append(AppliedPlace(display: display, kind: .lockScreen))
            }
        }
        // One place however many displays there are, because the screen saver
        // is one setting for the whole Mac. It was missing here entirely, so a
        // wallpaper that was only the screen saver wore no chip at all and
        // there was nowhere in the library to see what the screen saver was
        // (owner, 2026-09-10).
        if lockScreenAvailable,
           lockScreen.isApplied(wallpaperID: id, target: .all, surface: .screenSaver) {
            out.append(AppliedPlace(display: nil, kind: .screenSaver))
        }
        return out
    }

    /// How much ground a wallpaper covers, once it is in more than one place.
    ///
    /// Both labels below read this rather than working it out for themselves,
    /// so the chip on a card and the sentence in the preview bar can never
    /// disagree about the same wallpaper.
    private enum AppliedSpread {
        case everywhere
        case allDisplays
        case allLockScreens
        case some(Int)
    }

    private func appliedSpread(_ places: [AppliedPlace]) -> AppliedSpread {
        let screens = displays.count
        let desktops = places.filter { $0.kind == .desktop }.count
        let locks = places.filter { $0.kind == .lockScreen }.count
        let saver = places.contains { $0.kind == .screenSaver }
        // A desktop and a lock screen per display, plus the one screen saver.
        let everyPlace = screens * (lockScreenAvailable ? 2 : 1)
            + (lockScreenAvailable ? 1 : 0)

        // "Everywhere" only reads as true when there is a lock screen it could
        // also have gone to. On a Mac that cannot do lock screens, covering
        // every display is covering every display, which is what it used to
        // say and still should.
        if places.count >= everyPlace {
            return lockScreenAvailable ? .everywhere : .allDisplays
        }
        // These two still have to mean what they say, so the screen saver
        // being in the list rules them both out.
        if locks == 0, !saver, desktops == screens { return .allDisplays }
        if desktops == 0, !saver, locks == screens { return .allLockScreens }
        return .some(places.count)
    }

    /// The one short label for the chip, whatever the wallpaper is covering.
    ///
    /// Naming the single place it is in is the useful answer and the common
    /// one. Past that a chip cannot list four names in a card corner, so it
    /// says how much ground is covered instead, and only claims "everywhere"
    /// when there is genuinely nothing left to apply it to.
    func appliedChipLabel(for id: String) -> String? {
        let places = appliedPlaces(for: id)
        guard let only = places.first else { return nil }
        if places.count == 1 { return only.chipLabel }
        switch appliedSpread(places) {
        case .everywhere: return "EVERYWHERE"
        case .allDisplays: return "ALL DISPLAYS"
        case .allLockScreens: return "ALL LOCK SCREENS"
        case .some(let count): return "\(count) PLACES"
        }
    }

    /// The same answer in words, for the preview bar.
    ///
    /// A card corner can only take an abbreviation; the bar under a
    /// full-screen preview has room for the sentence, and where a wallpaper
    /// is showing is the thing someone opening it wants to know.
    func appliedFullLabel(for id: String) -> String? {
        let places = appliedPlaces(for: id)
        guard let only = places.first else { return nil }
        if places.count == 1 { return "Applied on \(only.fullLabel)" }
        switch appliedSpread(places) {
        case .everywhere: return "Applied everywhere"
        case .allDisplays: return "Applied on all displays"
        case .allLockScreens: return "Applied on all lock screens"
        case .some(let count): return "Applied in \(count) places"
        }
    }

    // MARK: - Likes

    /// Every wallpaper this install has liked, downloaded or not.
    ///
    /// Likes used to be a flag inside `library.json`, and that file only holds
    /// wallpapers that have actually been downloaded. So the heart was switched
    /// off on everything else, and the only wallpapers anyone could like were
    /// the ones they already had, which is issue #30. A like says "I want this
    /// one", which is a thing to say before a download rather than after it, so
    /// the ids live in UserDefaults instead, the same way `seenCatalogIDs`
    /// does, and cover the whole catalog.
    private(set) var likedIDs: Set<String> = []

    /// Likes made by an older build sit in the manifest. They are folded in
    /// once so nobody opens this version and finds an empty Liked tab. The
    /// manifest flag is left alone: an older build reading the same library
    /// still works, and folding the same ids in again changes nothing.
    private func loadLikes() {
        var ids = Set(defaults.stringArray(forKey: "likedIDs") ?? [])
        let fromManifest = Set(manifest.wallpapers.filter(\.liked).map(\.id))
        if !fromManifest.isSubset(of: ids) {
            ids.formUnion(fromManifest)
            defaults.set(Array(ids), forKey: "likedIDs")
        }
        guard ids != likedIDs else { return }
        likedIDs = ids
        invalidateItemCache()
    }

    func toggleLike(_ item: WallpaperItem) {
        objectWillChange.send()
        if likedIDs.contains(item.id) {
            likedIDs.remove(item.id)
        } else {
            likedIDs.insert(item.id)
        }
        defaults.set(Array(likedIDs), forKey: "likedIDs")
        invalidateItemCache()
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
        // Apple's aerials are fetched from Apple, into Muro's own cache. The
        // catalog path below would write them into `library.json` and copy
        // them into `Masters/`, which is exactly what this feature promised
        // not to do.
        if AppleAerials.isAppleID(item.id) {
            // A still picture comes as a zip to be cut in two. The ones macOS
            // draws have nothing to download.
            if item.id.hasPrefix(AppleAerials.picturePrefix) {
                downloadApplePictureNow(item)
            } else if !AppleAerials.isMacOSOnly(item.id) {
                downloadAppleAerial(item)
            }
            return
        }
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
                importError = "Muro imports MP4, MOV and M4V videos, and .saver screen savers. Nothing was added."
            }
            return
        }
        let skipped = urls.count - videos.count
        let root = self.root
        let known = manifest.wallpapers
        Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            var already: [String] = []
            var library = known
            for (index, url) in videos.enumerated() {
                // The file name and the codec are not news to the person who
                // just dropped the file. One word, a count and a percentage
                // are the whole of what they need while they wait; a big file
                // used to sit at "Importing 1 of 4..." for most of a minute
                // with nothing moving (full check, 2026-10-01).
                let label = videos.count == 1 ? "Importing" : "Importing \(index + 1) of \(videos.count)"
                await MainActor.run {
                    AppStore.shared.importStatus = label + "…"
                    AppStore.shared.importProgress = 0
                }
                // The same file twice used to make two identical wallpapers.
                // It is turned away like a second `.saver`, including the
                // same file picked twice in one go.
                let fingerprint = videoFingerprint(of: url)
                if let match = alreadyImported(source: url, fingerprint: fingerprint, in: library) {
                    already.append(match.title)
                    continue
                }
                do {
                    library.append(try importVideo(
                        source: url, root: root, sourceFingerprint: fingerprint
                    ) { done in
                        Task { @MainActor in
                            guard AppStore.shared.importProgress != nil else { return }
                            AppStore.shared.importProgress = done
                            AppStore.shared.importStatus = "\(label)… \(Int((done * 100).rounded()))%"
                        }
                    })
                } catch {
                    failures.append("\(url.lastPathComponent): \(importFailureReason(error))")
                }
                await MainActor.run { AppStore.shared.reloadFromDisk() }
            }
            let report = failures
            let duplicates = already
            await MainActor.run {
                AppStore.shared.importStatus = nil
                AppStore.shared.importProgress = nil
                AppStore.shared.recomputeSize()
                if !duplicates.isEmpty {
                    AppStore.shared.showImportNote(duplicates.count == 1
                        ? "\(duplicates[0]) is already in your Library."
                        : "\(duplicates.count) of those videos are already in your Library.")
                }
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

    func showImportNote(_ text: String) {
        importNote = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if importNote == text { importNote = nil }
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
        stopEverywhere(.playlist(playlist.id))
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }

    func updatePlaylist(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist
        savePlaylists()
    }

    /// Stops the desktop's playlist.
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
        stopEverywhere(.automation(automation.id))
        automations.removeAll { $0.id == automation.id }
        saveAutomations()
    }

    /// Stops the desktop's automation.
    func stopAutomation() {
        scheduler.stopAutomation()
        syncScheduler()
    }

    private func saveAutomations() {
        try? AutomationStore.save(automations, root: root)
        syncScheduler()
    }

    // MARK: - Playing on a place

    /// The places this Mac can play a playlist or an automation on. The lock
    /// screen and the screen saver need macOS 26 and the extension.
    var schedulePlaces: [SchedulePlace] {
        lockScreenAvailable ? SchedulePlace.allCases : [.desktop]
    }

    /// Plays a playlist or an automation on one place. Whatever that place was
    /// playing stops; every other place carries on as it was.
    func play(_ schedule: ScheduleRef, on place: SchedulePlace) {
        guard place == .desktop || lockScreenAvailable else {
            applyError = LockScreenServiceError.requiresTahoe.localizedDescription
            return
        }
        let runner = placeScheduler(for: place)
        switch schedule {
        case .playlist(let id):
            guard let playlist = playlists.first(where: { $0.id == id }),
                  !playlist.wallpaperIDs.isEmpty
            else { return }
            makeRoom(for: place)
            resumeForStart(on: place)
            runner.startPlaylist(playlist)
        case .automation(let id):
            guard let automation = automations.first(where: { $0.id == id }),
                  !automation.steps.isEmpty
            else { return }
            makeRoom(for: place)
            resumeForStart(on: place)
            runner.startAutomation(automation)
        }
        syncScheduler()
    }

    /// Starting a playlist or an automation is a choice made by hand, so it
    /// plays, the way it always did. Only the steps after it keep a pause
    /// (see `applyAssignment`).
    private func resumeForStart(on place: SchedulePlace) {
        guard place == .desktop, isPaused else { return }
        config.paused = false
        try? config.save(root: root)
    }

    /// Stops whatever a place is playing. It keeps showing the last wallpaper,
    /// the way the desktop always has when a playlist stops.
    func stopPlaying(on place: SchedulePlace) {
        placeScheduler(for: place).stopEverything()
        syncScheduler()
    }

    /// The places a playlist or an automation is playing on, in order.
    func places(playing schedule: ScheduleRef) -> [SchedulePlace] {
        SchedulePlace.allCases.filter { nowPlaying[$0] == schedule }
    }

    func name(of schedule: ScheduleRef) -> String? {
        switch schedule {
        case .playlist(let id): return playlists.first { $0.id == id }?.name
        case .automation(let id): return automations.first { $0.id == id }?.name
        }
    }

    /// Starts it again on every place it is playing, so an edit to it takes
    /// effect now rather than at its next step.
    func restartWherePlaying(_ schedule: ScheduleRef) {
        for place in places(playing: schedule) { play(schedule, on: place) }
    }

    /// For a delete: nothing may go on playing something that is gone.
    private func stopEverywhere(_ schedule: ScheduleRef) {
        let playing = places(playing: schedule)
        guard !playing.isEmpty else { return }
        for place in playing { placeScheduler(for: place).stopEverything() }
        syncScheduler()
    }

    /// The places a wallpaper chosen by hand takes over. One of the wallpapers
    /// macOS shows itself (a still picture, a drawn one, a screen saver file)
    /// on the desktop is the lock screen too, because macOS keeps the two on
    /// one key; anything Muro plays keeps them apart.
    private func placesCovered(by item: WallpaperItem, surface: ApplySurface) -> [SchedulePlace] {
        var places: [SchedulePlace] = []
        if surface.coversDesktop { places.append(.desktop) }
        if surface.coversLockScreen || (AppleAerials.isMacOSOnly(item.id) && surface.coversDesktop) {
            places.append(.lockScreen)
        }
        if surface.coversScreenSaver { places.append(.screenSaver) }
        return places
    }

    /// Stops what these places are playing. Every other place carries on.
    private func stopSchedules(on places: [SchedulePlace]) {
        let playing = places.filter {
            let runner = placeScheduler(for: $0)
            return runner.activePlaylistID != nil || runner.activeAutomationID != nil
        }
        guard !playing.isEmpty else { return }
        for place in playing { placeScheduler(for: place).stopEverything() }
        syncScheduler()
    }

    /// Where macOS keeps the lock screen and the screen saver on one key, the
    /// two are one place: starting on either stops the other, or each step
    /// would take the key back from the other one, with a flash every time.
    private func makeRoom(for place: SchedulePlace) {
        guard place != .desktop, lockScreen.lockAndSaverAreLinked else { return }
        placeScheduler(for: place == .lockScreen ? .screenSaver : .lockScreen).stopEverything()
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
        let entries = items.filter { !AppleAerials.isAppleID($0.id) }.compactMap(\.local)
        let apple = items.map(\.id).filter { appleDownloadFile(id: $0) != nil }
        // The person's own screen savers go to the Trash (owner, 2026-09-30).
        let savers = items.map(\.id).filter(canDeleteScreenSaver)
        if !savers.isEmpty { Task { await deleteScreenSavers(savers) } }
        guard !entries.isEmpty || !apple.isEmpty else { return }
        Task { await performDelete(entries, apple: apple) }
    }

    /// What the interface calls. Nothing deletes without an answer, so the
    /// button, the menu item and the batch bar all end up in the same sheet.
    func requestDelete(_ items: [WallpaperItem]) {
        // From the Apple section, only what Muro downloaded can go: macOS's
        // own aerials are not Muro's to touch, and the ones macOS draws have
        // no file at all.
        let deletable = items.filter { item in
            (AppleAerials.isAppleID(item.id) ? appleDownloadFile(id: item.id) != nil : item.local != nil)
                || canDeleteScreenSaver(item.id)
        }
        guard !deletable.isEmpty else { return }
        pendingDelete = DeleteRequest(items: deletable)
    }

    func deleteWallpaper(_ item: WallpaperItem) {
        deleteWallpapers([item])
    }

    private func performDelete(_ entries: [WallpaperEntry], apple: [String] = []) async {
        // A shared copy is a hard link and would keep a deleted video on disk.
        ShareFile.clear()
        // Downloads from the Apple section go the same way. An aerial macOS
        // keeps a copy of goes on playing from that copy, so it stays where
        // it is and only Muro's file goes.
        let ids = Set(entries.map(\.id)).union(apple.filter { !macOSKeepsAerial($0) })

        // Whether the desktop was showing one of them, for step 5: a playlist
        // or automation playing there has to put something else on.
        let desktopShowedDeleted = (config.allDisplays.map { ids.contains($0.wallpaperID) } ?? false)
            || config.perDisplay.values.contains { ids.contains($0.wallpaperID) }

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

        // 2. Off the lock screen and the screen saver. Those keep their own
        //    staged copy of the video inside the extension container and a
        //    record in Apple's wallpaper store, so removing the selection is
        //    what puts the user's real wallpaper back and releases the copy.
        //    Both roles are swept: a wallpaper deleted while it was only the
        //    screen saver used to leave its record and its staged file behind.
        for role in [AppleWallpaperStore.Surface.desktop, .screenSaver] {
            for target in lockScreen.targets(showing: ids, surface: role) {
                do {
                    try await lockScreen.remove(target: target, surface: role)
                } catch {
                    applyError = error.localizedDescription
                }
            }
        }
        //    Apple's pictures are shown by macOS itself, which reads them from
        //    the very file about to go, so macOS gets its own wallpaper back.
        for id in apple where macOSWallpapers.shownIDs.contains(id) {
            do {
                try await macOSWallpapers.remove(id: id, surface: .desktop, targetKey: "all")
            } catch {
                applyError = error.localizedDescription
            }
        }

        // 3. The manifest and the files, through the writer so a download
        //    finishing in the same moment cannot lose its own entry. Off the
        //    main actor: a batch delete can be dozens of large files.
        let root = self.root
        let muroIDs = Set(entries.map(\.id))
        if !muroIDs.isEmpty,
           let updated = try? await Task.detached(priority: .utility, operation: {
               try LibraryWriter.delete(ids: muroIDs, root: root)
           }).value {
            manifest = updated
        }
        //    Apple's files are not in the manifest. Each is only Muro's own
        //    download, so macOS's copies are never touched.
        let appleFiles = apple.compactMap { appleDownloadFile(id: $0) }
        if !appleFiles.isEmpty {
            await Task.detached(priority: .utility) {
                for file in appleFiles { try? FileManager.default.removeItem(at: file) }
            }.value
            finishedAppleAerialChange()
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
            deleteNotice = StopNotice(
                title: "Playlist stopped",
                message: "\(name) has no wallpapers left, so it stopped."
            )
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
            deleteNotice = StopNotice(
                title: "Automation stopped",
                message: "\(name) has no wallpapers left, so it stopped."
            )
        }

        // 5. A playlist or automation playing on the desktop whose wallpaper
        //    was just taken off it shows its next one now. Waiting for its next
        //    step left the desktop with nothing on it, for up to a whole clock
        //    window, while its card still said Playing (full check, 2026-10-01).
        if desktopShowedDeleted,
           scheduler.activePlaylistID != nil || scheduler.activeAutomationID != nil {
            scheduler.showCurrentAgain()
        }

        //    A playlist or automation on the lock screen or the screen saver
        //    shows its wallpaper behind a fixed id, which step 2 cannot see.
        //    Its video is a hard link, so a deleted file would stay on disk
        //    behind it until the next step. The next step is now. With nothing
        //    running there any more, the place goes back to the user's own.
        for (place, role) in [
            (lockScheduler, AppleWallpaperStore.Surface.desktop),
            (saverScheduler, AppleWallpaperStore.Surface.screenSaver),
        ] {
            guard let shown = lockScreen.rotationWallpaperID(role), ids.contains(shown)
            else { continue }
            if place.activePlaylistID != nil || place.activeAutomationID != nil {
                place.showCurrentAgain()
                // The step is queued behind any other; wait for it and check
                // it really replaced the deleted video. When nothing it has
                // left can play, the deleted wallpaper stayed on the lock
                // screen behind its hard link, kept its file on disk and came
                // back on the desktop after Quit (full check, 2026-10-01).
                await placeSteps?.value
                guard let still = lockScreen.rotationWallpaperID(role), ids.contains(still)
                else { continue }
            }
            do {
                // Only the playlist's own records; a display with a lock
                // screen of its own keeps it. See `removeRotation`.
                try await lockScreen.removeRotation(role)
            } catch {
                applyError = error.localizedDescription
            }
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

    /// The wallpapers Clear keeps: whatever is on screen right now, on any
    /// display, the lock screen or the screen saver, and every wallpaper a
    /// playlist or an automation uses.
    ///
    /// Playlist members were left out for a while, so that a library kept
    /// entirely in one playlist could still be cleared. What that did in
    /// practice was empty playlists and automations behind the user's back:
    /// Clear is about freeing space, and nothing on its sheet said a playlist
    /// would lose half its wallpapers and an automation its steps. They are
    /// kept again (the rule of 2026-07-18), and the sheet now says so.
    var protectedWallpaperIDs: Set<String> {
        playingWallpaperIDs.union(scheduledWallpaperIDs)
    }

    /// Every wallpaper a playlist or an automation uses, playing or not.
    var scheduledWallpaperIDs: Set<String> {
        var ids = Set(playlists.flatMap(\.wallpaperIDs))
        for automation in automations { ids.formUnion(automation.steps.map(\.wallpaperID)) }
        return ids
    }

    /// Whatever is on screen right now, on any display, the lock screen or
    /// the screen saver.
    var playingWallpaperIDs: Set<String> {
        var ids = Set<String>()
        if let all = config.allDisplays?.wallpaperID { ids.insert(all) }
        for assignment in config.perDisplay.values { ids.insert(assignment.wallpaperID) }
        ids.formUnion(lockScreen.activeWallpaperIDs)
        // A playlist or automation on the lock screen or the screen saver is
        // held above by its fixed id, which names no wallpaper. What it is
        // showing is on screen as much as anything else here.
        for role in [AppleWallpaperStore.Surface.desktop, .screenSaver] {
            if let shown = lockScreen.rotationWallpaperID(role) { ids.insert(shown) }
        }
        return ids
    }

    /// What Clear is about to do, so the confirmation can say it out loud
    /// instead of describing the rules and leaving the user to do the sums.
    struct ClearPlan {
        var removed: [WallpaperEntry]
        var kept: Int
        /// Of `kept`, the ones staying only because a playlist or an
        /// automation uses them, so the sheet can say why they stay.
        var keptForSchedules: Int = 0
        var personal: Int
        var bytes: Int64
        /// Downloads from the Apple section that nothing is showing. Apple
        /// keeps every one, so each can be downloaded again.
        var apple: [URL] = []
        var appleBytes: Int64 = 0

        var isEmpty: Bool { removed.isEmpty && apple.isEmpty }
    }

    var clearPlan: ClearPlan {
        let keep = protectedWallpaperIDs
        let playing = playingWallpaperIDs
        let remote = Set(catalog.map(\.id))
        let removed = manifest.wallpapers.filter { !keep.contains($0.id) }
        return ClearPlan(
            removed: removed,
            kept: manifest.wallpapers.count - removed.count,
            keptForSchedules: manifest.wallpapers.filter {
                keep.contains($0.id) && !playing.contains($0.id)
            }.count,
            personal: removed.filter { !remote.contains($0.id) }.count,
            bytes: removed.reduce(0) { $0 + $1.sizeBytes } + PreviewCache.sizeOnDisk()
                + ThumbnailCache.sizeOnDisk(),
            apple: appleClearable,
            appleBytes: appleClearable.reduce(Int64(0)) { $0 + fileSize($1) }
                + ApplePreviews.fullPictures().reduce(Int64(0)) { $0 + fileSize($1) }
        )
    }

    /// Apple downloads nothing is showing: not on a desktop, the lock screen
    /// or the screen saver, whether Muro plays it or macOS does.
    private var appleClearable: [URL] {
        let inUse = protectedWallpaperIDs.union(macOSWallpapers.shownIDs)
        return AppleAerials.downloadedFiles(libraryRoot: root).filter {
            !inUse.contains($0.deletingPathExtension().lastPathComponent)
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .int64Value ?? 0
    }

    func clearDownloadedCache() {
        let plan = clearPlan
        // Apple downloads are named after their card, so a name is an id.
        let doomed = plan.removed.map(\.id)
            + plan.apple.map { $0.deletingPathExtension().lastPathComponent }
        Task {
            // The Apple section's downloads and its full-screen pictures.
            // Apple keeps every one of them, and the cards stay.
            for file in plan.apple + ApplePreviews.fullPictures() {
                try? FileManager.default.removeItem(at: file)
            }
            if !plan.apple.isEmpty { finishedAppleAerialChange() }
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
            ShareFile.clear()
            // The saved Explore thumbnails, re-downloadable the same way.
            ThumbnailCache.clear()
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
        let count = plan.removed.count + plan.apple.count
        if count > 0 {
            parts.append("\(count) \(count == 1 ? "wallpaper" : "wallpapers") removed")
            parts.append("about \(formatSize(plan.bytes + plan.appleBytes + swept)) freed")
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
        // Apple's go through the same sheet and the same delete as the rest.
        if AppleAerials.isAppleID(item.id) { requestDelete([item]); return }
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
        // Apple leaves one still per aerial on the Mac, about 40 KB, whether or
        // not the video was ever downloaded. That is what makes a gallery of
        // 162 aerials free to show, so it is checked before anything else.
        if AppleAerials.isAppleID(item.id) {
            if let path = appleAerialThumbnailPath(id: item.id) { return path }
            return nil
        }
        if let entry = item.local {
            let path = resolveLibraryFile(entry.thumbnail, root: root).path
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

/// Bytes on disk across several folders, each file counted once even when it
/// is hard linked from more than one of them. Links to other files are not
/// followed; a folder kept elsewhere is passed in on its own.
func uniqueFileBytes(_ folders: [URL]) -> Int64 {
    var seen = Set<String>()
    var total: Int64 = 0
    for folder in folders {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        else { continue }
        for case let url as URL in files {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  seen.insert("\(info.st_dev):\(info.st_ino)").inserted
            else { continue }
            total += Int64(info.st_size)
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
/// Internal rather than private so Apple's aerials download the same way
/// Muro's own wallpapers do, with the same progress reporting and the same
/// handling of a half-written file.
func fetchMaster(
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

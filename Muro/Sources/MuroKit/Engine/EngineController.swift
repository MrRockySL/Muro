import AppKit

/// Library mode: reads library.json + config.json, keeps one wallpaper
/// window per assigned display, and reconciles whenever the config changes
/// on disk (hot-reload) or displays are connected/disconnected.
public final class EngineController {
    private let root = LibraryManifest.defaultRoot()
    private var controllers: [String: WallpaperWindowController] = [:]
    /// Split deliberately. The window's geometry is the only thing that needs
    /// a rebuild; the video is swapped in place, because tearing the window
    /// down for a wallpaper change flashed black on every switch.
    private var frames: [String: String] = [:]
    private var videos: [String: String] = [:]
    private var configWatcher: DispatchSourceFileSystemObject?
    private var observers: [NSObjectProtocol] = []
    private let power = PowerMonitor()

    public init() {}

    public func start() {
        power.onChange = { [weak self] in self?.applyPowerState() }
        power.start()
        reconcile()
        watchConfigDirectory()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            EngineLog.log("displays changed — reconciling")
            self?.reconcile()
        })
    }

    /// Watches the library root for writes; config.json is saved atomically
    /// so directory-level write events are the reliable signal.
    private func watchConfigDirectory() {
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else {
            EngineLog.log("warning: cannot watch \(root.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.reconcile() }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    private func reconcile() {
        let manifest = LibraryManifest.load(root: root)
        let config = EngineConfig.load(root: root)

        var desired: [String: (screen: NSScreen, url: URL, frame: String, video: String)] = [:]
        for screen in NSScreen.screens {
            guard let uuid = displayUUID(for: screen) else { continue }
            guard let assignment = config.assignment(forDisplayUUID: uuid),
                  let entry = manifest.wallpapers.first(where: { $0.id == assignment.wallpaperID })
            else { continue }
            let url = resolveVideoURL(entry: entry, mode: assignment.mode, root: root)
            guard FileManager.default.fileExists(atPath: url.path) else {
                EngineLog.log("skipping \(entry.title) — missing file \(url.lastPathComponent)")
                continue
            }
            desired[uuid] = (
                screen,
                url,
                NSStringFromRect(screen.frame),
                "\(entry.id)|\(assignment.mode)"
            )
        }

        // Tear down displays that lost their assignment, or whose geometry
        // changed. A resolution or arrangement change genuinely needs a new
        // window; a different wallpaper does not.
        for (uuid, controller) in controllers where desired[uuid]?.frame != frames[uuid] {
            controller.stop()
            controllers[uuid] = nil
            frames[uuid] = nil
            videos[uuid] = nil
        }

        // Bring up displays that need a (new) wallpaper.
        for (uuid, want) in desired where controllers[uuid] == nil {
            let controller = WallpaperWindowController(screen: want.screen, videoURL: want.url)
            controller.start()
            controllers[uuid] = controller
            frames[uuid] = want.frame
            videos[uuid] = want.video
            EngineLog.log("applied \(want.url.lastPathComponent) → \(want.screen.localizedName)")
        }

        // Same window, different wallpaper: crossfade to it in place.
        for (uuid, want) in desired {
            guard let controller = controllers[uuid], videos[uuid] != want.video else { continue }
            controller.setVideo(url: want.url)
            videos[uuid] = want.video
        }

        // Live-applied state that never needs a window rebuild.
        let paused = config.paused ?? false
        let rate = Float(config.playbackSpeed ?? 1.0)
        let pauseWhenCovered = config.autoPauseFullScreen ?? true
        for controller in controllers.values {
            controller.setUserPaused(paused)
            controller.setPlaybackRate(rate)
            controller.setAutoPauseFullScreen(pauseWhenCovered)
        }
        applyPowerState(config: config)
    }

    /// Combines the Settings toggles (from config.json) with the live power
    /// state. Runs on every reconcile (config edits, display changes) and on
    /// every PowerMonitor flip, so both sides stay in sync.
    private func applyPowerState(config: EngineConfig? = nil) {
        let config = config ?? EngineConfig.load(root: root)
        let lowPower = (config.autoPauseLowPower ?? false) && power.isLowPowerMode
        let lowBattery = (config.autoPauseBattery ?? false) && power.isLowBattery
        for controller in controllers.values {
            controller.setPowerPause(lowPower: lowPower, lowBattery: lowBattery)
        }
    }
}

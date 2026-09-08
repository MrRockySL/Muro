// Lifecycle layout derived from Phosphene (MIT),
// copyright 2026 kageroumado; see THIRD_PARTY_NOTICES.md.
import Foundation
import QuartzCore

struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
}

struct WallpaperRequestInfo {
    var destinationSize = CGSize(width: 2_560, height: 1_440)
    var scaleFactor: CGFloat = 2
    var displayID: UInt32?
    var isPreview = false
    var choiceID: String?
    var files: [URL] = []

    /// What macOS says this surface is for, when it says anything. Nil means
    /// the request carried none, not that the desktop is showing.
    ///
    /// The creation request has carried this all along and it was read only
    /// off `update`, which arrives later or not at all. Taking it here is what
    /// lets the very first wallpaper of a session know whether it is being
    /// put on a lock screen.
    var presentationMode: String?
    var activityState: String?
}

func inspectWallpaperRequest(_ request: Any?) -> WallpaperRequestInfo {
    var result = WallpaperRequestInfo()
    guard let request else { return result }
    if let size = mirrorProperty("size", in: request) as? CGSize { result.destinationSize = size }
    if let scale = mirrorProperty("scaleFactor", in: request) as? CGFloat { result.scaleFactor = scale }
    if let displayID = mirrorProperty("directDisplayID", in: request) as? UInt32 { result.displayID = displayID }
    if let preview = mirrorProperty("isPreview", in: request) as? Bool { result.isPreview = preview }
    if let configuration = mirrorProperty("configuration", in: request) as? Data {
        result.choiceID = String(data: configuration, encoding: .utf8)
    }
    if let files = mirrorProperty("files", in: request) as? [URL] { result.files = files }
    result.presentationMode = mirrorProperty("presentationMode", in: request).map(wallpaperEnumCase)
    result.activityState = mirrorProperty("activityState", in: request).map(wallpaperEnumCase)
    return result
}

func mirrorProperty(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 7 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let result = mirrorProperty(label, in: child.value, depth: depth + 1) { return result }
    }
    return nil
}

func wallpaperEnumCase(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return label }
    return String(describing: value)
}

struct WallpaperSurfaceKey: Hashable {
    let displayID: UInt32
    let identifier: String
}

final class ActiveWallpaper: @unchecked Sendable {
    let context: CAContext
    let rootLayer: CALayer
    let renderer: VideoRenderer
    let choiceID: String?

    /// The frozen picture behind the video. Nil for a System Settings preview,
    /// which is showing the lock wallpaper on purpose and should not be handed
    /// the desktop's.
    let stillLayer: CALayer?

    /// The lock wallpaper's own thumbnail, kept so a desktop still going away
    /// falls back to something rather than to nothing.
    private let fallback: CGImage?

    init(
        context: CAContext,
        rootLayer: CALayer,
        renderer: VideoRenderer,
        choiceID: String?,
        stillLayer: CALayer?,
        fallback: CGImage?
    ) {
        self.context = context
        self.rootLayer = rootLayer
        self.renderer = renderer
        self.choiceID = choiceID
        self.stillLayer = stillLayer
        self.fallback = fallback
    }

    /// Swap in a newly staged desktop still, or go back to the fallback.
    func setStill(_ image: CGImage?) {
        guard let stillLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.contents = image ?? fallback
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Show the still and hide the video, or the other way round.
    ///
    /// The video is hidden rather than left paused underneath, because a
    /// paused video layer that composited a frame would cover the still, and
    /// one that failed to composite is the black desktop this exists to stop.
    func setShowingStill(_ showing: Bool) {
        guard let stillLayer, stillLayer.contents != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.isHidden = !showing
        CATransaction.commit()
        CATransaction.flush()
        renderer.setHidden(showing)
    }
}

final class RendererState: @unchecked Sendable {
    static let shared = RendererState()
    static let lifecycleQueue = DispatchQueue(label: "com.mrrockysl.muro.wallpaper-lifecycle")

    private let lock = NSLock()
    private var active: [WallpaperSurfaceKey: ActiveWallpaper] = [:]
    private var teardown: [WallpaperSurfaceKey: DispatchWorkItem] = [:]

    /// Nil until macOS says. It used to start at `"default"`, which reads as
    /// "the desktop is showing" and is a claim nothing had made yet.
    private var presentationMode: String?
    private var activityState = "active"

    /// The pixel size of the last real surface macOS asked for, so a snapshot
    /// is made at the size of the screen it will be shown on rather than at a
    /// guess. Zero until the first acquire.
    private var lastPixelSize: CGSize = .zero

    func noteDestination(_ request: WallpaperRequestInfo) {
        guard !request.isPreview else { return }
        let size = CGSize(
            width: request.destinationSize.width * request.scaleFactor,
            height: request.destinationSize.height * request.scaleFactor
        )
        lock.lock()
        if size.width > lastPixelSize.width { lastPixelSize = size }
        lock.unlock()
    }

    /// The size to render a snapshot at: the biggest screen this process has
    /// been asked to fill, or a sensible desktop size before it has.
    var snapshotSize: CGSize {
        lock.lock()
        let known = lastPixelSize
        lock.unlock()
        guard known.width >= 1, known.height >= 1 else {
            return CGSize(width: 2_560, height: 1_600)
        }
        return known
    }

    /// The wallpaper a surface id is showing, for a request that names one
    /// surface rather than describing a wallpaper.
    func choiceID(forIdentifier identifier: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let identifier,
           let match = active.first(where: { $0.key.identifier == identifier }) {
            return match.value.choiceID
        }
        return active.values.compactMap(\.choiceID).first
    }

    func surfaceKey(id: Any?, request: WallpaperRequestInfo) -> WallpaperSurfaceKey {
        let identifier = extractWallpaperUUID(from: id)?.uuidString
            ?? "fallback-\(request.isPreview ? "preview" : "live")"
        return WallpaperSurfaceKey(displayID: request.displayID ?? 0, identifier: identifier)
    }

    func install(_ wallpaper: ActiveWallpaper, for key: WallpaperSurfaceKey) {
        lock.lock()
        let previous = active.updateValue(wallpaper, forKey: key)
        teardown.removeValue(forKey: key)?.cancel()
        lock.unlock()
        previous?.renderer.stop()
    }

    func context(for key: WallpaperSurfaceKey) -> ActiveWallpaper? {
        lock.lock()
        defer { lock.unlock() }
        teardown.removeValue(forKey: key)?.cancel()
        return active[key]
    }

    func scheduleRemoval(of key: WallpaperSurfaceKey) {
        lock.lock()
        teardown.removeValue(forKey: key)?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.remove(key) }
        teardown[key] = item
        lock.unlock()
        Self.lifecycleQueue.asyncAfter(deadline: .now() + 15, execute: item)
    }

    func scheduleRemoval(identifier: String) {
        lock.lock()
        let keys = active.keys.filter { $0.identifier == identifier }
        lock.unlock()
        keys.forEach(scheduleRemoval)
    }

    func forEachWallpaper(_ body: (ActiveWallpaper) -> Void) {
        lock.lock()
        let wallpapers = Array(active.values)
        lock.unlock()
        wallpapers.forEach(body)
    }

    func setPresentation(mode: String, activity: String) {
        lock.lock()
        presentationMode = mode
        activityState = activity
        lock.unlock()
        extensionTrace("presentation mode=\(mode) activity=\(activity)")
        applyCurrentPlaybackPolicy()
    }

    /// Adopts what an acquire request said about itself, so the surface being
    /// created decides its own first frame rather than inheriting whatever the
    /// process last heard about some other surface.
    func adopt(mode: String?, activity: String?) {
        lock.lock()
        if let mode { presentationMode = mode }
        if let activity { activityState = activity }
        lock.unlock()
    }

    /// Whether a surface should be playing rather than showing the still.
    ///
    /// `mode` and `activity` are the ones the acquire request carried, when it
    /// carried any; otherwise the last thing macOS said.
    ///
    /// The screen state is consulted whenever the answer would otherwise be
    /// "the desktop is showing". After a restart nothing has told this process
    /// anything: the login window posts no lock notification, so the lock
    /// screen used to come up frozen on the desktop's own picture. Asking the
    /// session settles it without waiting to be told. See `ScreenState`.
    func shouldPlayNow(
        mode requestedMode: String? = nil,
        activity requestedActivity: String? = nil,
        isPreview: Bool = false
    ) -> Bool {
        guard !isPreview else { return false }
        lock.lock()
        let mode = requestedMode ?? presentationMode
        let activity = requestedActivity ?? activityState
        lock.unlock()
        if activity.contains("suspended") { return false }
        if mode == "locked" { return true }
        if ScreenState.isCovered() { return true }
        if mode == "idle" { return false }
        return !ExtensionPreferences.shared.alwaysPauseDesktop
    }

    func applyCurrentPlaybackPolicy() {
        let shouldPlay = shouldPlayNow()
        forEachWallpaper { wallpaper in
            shouldPlay ? wallpaper.renderer.resume() : wallpaper.renderer.pause()
            wallpaper.setShowingStill(!shouldPlay)
        }
    }

    /// The app has staged a different desktop picture: a new wallpaper, a
    /// playlist step, or the last one being removed.
    func refreshDesktopStill() {
        let image = DesktopStill.current()
        forEachWallpaper { $0.setStill(image) }
        applyCurrentPlaybackPolicy()
    }

    private func remove(_ key: WallpaperSurfaceKey) {
        lock.lock()
        teardown[key] = nil
        let removed = active.removeValue(forKey: key)
        lock.unlock()
        removed?.renderer.stop()
        if removed != nil { extensionTrace("released inactive wallpaper surface") }
    }
}

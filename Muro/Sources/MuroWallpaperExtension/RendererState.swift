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
    private var presentationMode = "default"
    private var activityState = "active"

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

    func shouldPlayNow(isPreview: Bool = false) -> Bool {
        guard !isPreview else { return false }
        lock.lock()
        let mode = presentationMode
        let activity = activityState
        lock.unlock()
        if activity.contains("suspended") || mode == "idle" { return false }
        if ExtensionPreferences.shared.alwaysPauseDesktop { return mode == "locked" }
        return true
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

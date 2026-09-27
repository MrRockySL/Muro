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

    /// Whether macOS is asking for the screen saver.
    ///
    /// `WallpaperPresentationMode` has exactly three cases, `default`,
    /// `locked` and `idle`, and `idle` is the screen saver: the same word
    /// Apple's own wallpaper store keeps it under. The creation request
    /// carries no content type of any kind, so this is the only thing that
    /// says it.
    var isScreenSaver: Bool { presentationMode == "idle" }
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

/// Whether a choice is a playlist or an automation on the lock screen or the
/// screen saver rather than one wallpaper. The app stages each of those under
/// a fixed id with this prefix (MuroKit's `LockScreenRotation`, which this
/// target does not link), and only swaps the video behind it from step to
/// step. Everything below that reacts to a swap is gated on this, so a
/// wallpaper applied by hand is handled exactly as it always was.
func isRotationChoice(_ choiceID: String?) -> Bool {
    choiceID?.hasPrefix("muro-rotation-") ?? false
}

/// A staged file's identity. The file behind a fixed id always has the same
/// path, so a path cannot say a step has swapped it, but the inode and the
/// size both change when a different video is linked into place.
struct FileIdentity: Equatable {
    let inode: Int
    let size: Int

    static func of(_ url: URL?) -> FileIdentity? {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? Int,
              let size = attributes[.size] as? Int
        else { return nil }
        return FileIdentity(inode: inode, size: size)
    }
}

final class ActiveWallpaper: @unchecked Sendable {
    let context: CAContext

    /// The layer the remote context itself owns, and the layer that carries
    /// the desktop's frozen picture.
    ///
    /// The picture used to live in a sublayer added underneath the video after
    /// the context had already been handed to macOS. Putting it here means the
    /// surface carries it from the moment it exists, and removes a layer that
    /// could be on screen holding nothing.
    let rootLayer: CALayer

    let renderer: VideoRenderer
    let choiceID: String?

    /// Whether this surface draws the desktop's own picture at all. False for
    /// a System Settings preview, which is showing the lock wallpaper on
    /// purpose and should not be handed the desktop's, and false for the
    /// screen saver, which is not the desktop either.
    let drawsStill: Bool

    /// The display this surface is drawing on, as macOS named it in the
    /// acquire request. Kept so a reassert can fetch this display's own
    /// desktop picture rather than the main display's. Nil when macOS named
    /// no display, which is the whole-Mac fallback.
    let displayID: UInt32?

    /// Whether macOS built this surface to *be* the screen saver.
    ///
    /// Fixed at creation, and the only thing that separates the screen saver
    /// from every other surface. macOS creates one when the screen saver
    /// starts and takes it away when it stops, so a surface that has it is the
    /// screen saver for as long as it exists.
    let isScreenSaverSurface: Bool

    /// A frame of this wallpaper itself, kept so a desktop still going away
    /// falls back to something rather than to nothing.
    private let fallback: CGImage?

    /// The staged file this surface's video was built from, for a playlist
    /// or automation only. When the file behind the fixed id is no longer
    /// this one, the surface is showing the step before.
    var stagedIdentity: FileIdentity?

    /// What was last asked for, which is not always what is on screen: the
    /// still can only win while it has a picture. Kept so that a still
    /// arriving late, or being taken away, lands the right way round.
    private var wantsStill = false

    /// Whether there is a picture to fall back to right now.
    var hasStill: Bool { rootLayer.contents != nil }

    init(
        context: CAContext,
        rootLayer: CALayer,
        renderer: VideoRenderer,
        choiceID: String?,
        drawsStill: Bool,
        isScreenSaverSurface: Bool = false,
        displayID: UInt32? = nil,
        fallback: CGImage?
    ) {
        self.displayID = displayID
        self.context = context
        self.rootLayer = rootLayer
        self.renderer = renderer
        self.choiceID = choiceID
        self.drawsStill = drawsStill
        self.isScreenSaverSurface = isScreenSaverSurface
        self.fallback = fallback
    }

    /// Swap in a newly staged desktop still, or go back to the fallback.
    ///
    /// Re-asserts the visibility afterwards, because a still that has just
    /// become empty must give the screen back to the video rather than sit
    /// there drawing nothing.
    ///
    /// **Always a real repaint, even when the picture has not changed.** This
    /// is also how a desktop that came up showing nothing is put right, and
    /// that only works if something in the layer actually changes: assigning
    /// the image that is already on the layer changes nothing, so nothing is
    /// drawn again, which is why re-asserting a black desktop could not fix
    /// one. `repaintable` hands over a separate object each time. It shares
    /// the decoded bitmap, so it costs a pointer rather than a decode.
    func setStill(_ image: CGImage?) {
        guard drawsStill else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.contents = Self.repaintable(image ?? fallback)
        rootLayer.isOpaque = rootLayer.contents != nil
        CATransaction.commit()
        CATransaction.flush()
        setShowingStill(wantsStill)
    }

    /// The same surface playing the next step of a playlist or automation.
    /// Everything macOS knows it by stays: the context, the layer, the
    /// display. Only the video and the frame behind it are the new step's.
    func carrying(
        _ renderer: VideoRenderer, identity: FileIdentity?, fallback frame: CGImage?
    ) -> ActiveWallpaper {
        let next = ActiveWallpaper(
            context: context,
            rootLayer: rootLayer,
            renderer: renderer,
            choiceID: choiceID,
            drawsStill: drawsStill,
            isScreenSaverSurface: isScreenSaverSurface,
            displayID: displayID,
            fallback: frame ?? fallback
        )
        next.stagedIdentity = identity
        return next
    }

    /// The same picture in a different object, so assigning it counts as a
    /// change. Falls back to the image itself, which is no worse than what
    /// was there before.
    private static func repaintable(_ image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        return image.copy() ?? image
    }

    /// Show the desktop's picture and hide the video, or the other way round.
    ///
    /// The video is hidden rather than left paused on top, because a paused
    /// video layer that composited a frame would cover the picture, and one
    /// that failed to composite is the black desktop this exists to stop.
    ///
    /// The one thing that must never happen is nothing being drawn at all, and
    /// that is the whole of the rule here: the picture only wins while there
    /// actually is one. With no picture the video stays on screen whatever was
    /// asked for, because a frozen frame of the lock wallpaper is still a
    /// wallpaper and a hidden video over an empty surface is black.
    func setShowingStill(_ showing: Bool) {
        wantsStill = showing
        renderer.setHidden(showing && rootLayer.contents != nil)
    }

    /// Whether this surface was last told to show its picture rather than its
    /// video: the lock screen behind the desktop, or a display that is asleep.
    var isHeld: Bool { wantsStill }
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

    /// How many surfaces macOS is holding right now. Logged once per acquire
    /// so a bug report says whether the reassert had anything to draw on.
    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active.count
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
        extensionLog("presentation mode=\(mode) activity=\(activity)")
        // The picture is drawn again, not only re-paused. Unlocking, and
        // logging in, are the moments the desktop comes back into view, and a
        // desktop that came up with nothing on it has to be repainted at the
        // moment somebody can see it.
        refreshDesktopStill()
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

    /// Whether the screen saver surface should be playing.
    ///
    /// Deliberately a rule of its own rather than another branch inside
    /// `shouldPlayNow`. The desktop rule is settled behaviour that the lock
    /// screen depends on, and the screen saver has nothing in common with it:
    /// it exists only while it is the thing on screen, so being asked for it
    /// at all is the answer. `alwaysPauseDesktop` in particular must not
    /// reach it, since Muro's own window is not up there to keep still for.
    ///
    /// The one exception is macOS saying this surface is suspended, which
    /// means it is not being shown after all.
    func shouldScreenSaverPlay() -> Bool {
        lock.lock()
        let activity = activityState
        lock.unlock()
        return !activity.contains("suspended")
    }

    func applyCurrentPlaybackPolicy() {
        let shouldPlay = shouldPlayNow()
        let saverPlays = shouldScreenSaverPlay()
        // The line `7ee55c0` asked for and nobody added. A desktop that comes
        // back wrong is answered by this and nothing else: it says, per
        // surface, what was decided and whether there was a picture to decide
        // it with.
        extensionLog(
            "policy desktop=\(shouldPlay ? "play" : "still") "
                + "saver=\(saverPlays ? "play" : "still") "
                + "covered=\(ScreenState.isCovered()) "
                + surfaceSummary()
        )
        forEachWallpaper { wallpaper in
            // The desktop's answer is not the screen saver's. While the screen
            // saver is up the desktop is behind it and holding still, and
            // giving that answer to both is what froze the screen saver.
            let play = wallpaper.isScreenSaverSurface ? saverPlays : shouldPlay
            // A playlist or automation surface that skipped steps while nobody
            // could see it holds an earlier step. It stays on its picture until
            // the current step has a frame, rather than showing the old video
            // first. Always false for a wallpaper applied by hand, and for a
            // surface that was already on screen.
            let waiting = play && wallpaper.isHeld && hasNewerStagedStep(wallpaper)
            play && !waiting ? wallpaper.renderer.resume() : wallpaper.renderer.pause()
            wallpaper.setShowingStill(!play || waiting)
        }
        Self.lifecycleQueue.async { RendererState.shared.revealHeldSteps() }
    }

    /// The app has staged a different desktop picture: a new wallpaper, a
    /// playlist step, or the last one being removed.
    /// `display=1 still=yes shown=still` for each surface, for the log line
    /// above. Short on purpose: the extension log is capped at 32 KB.
    private func surfaceSummary() -> String {
        forEachWallpaperCollect { wallpaper in
            "[d=\(wallpaper.displayID.map(String.init) ?? "-")"
                + (wallpaper.isScreenSaverSurface ? " saver" : "")
                + " still=\(wallpaper.hasStill ? "yes" : "NO")]"
        }.joined(separator: " ")
    }

    func forEachWallpaperCollect(_ body: (ActiveWallpaper) -> String) -> [String] {
        lock.lock()
        let wallpapers = Array(active.values)
        lock.unlock()
        return wallpapers.map(body)
    }

    func refreshDesktopStill() {
        // Per surface, not one picture for the Mac: two displays have two
        // desktop wallpapers and each surface has to be handed its own.
        DesktopStill.forgetMissingFiles()
        forEachWallpaper { $0.setStill(DesktopStill.current(displayID: $0.displayID)) }
        applyCurrentPlaybackPolicy()
    }

    /// Asserts the desktop picture again, a few times, shortly after a surface
    /// is built.
    ///
    /// **Why a surface is not trusted to come up right.** Measured on the
    /// owner's Mac on 2026-09-08: macOS acquires the wallpaper about two
    /// seconds after logging in, and for roughly the next forty seconds
    /// quitting Muro left a black desktop. Nothing on disk changed in that
    /// time, the staged picture was there and readable throughout, the
    /// lifecycle never invalidated the surface, and no second acquire ever
    /// happened. What cleared it was any later run of this same code: opening
    /// Muro and waiting a few seconds, or locking and unlocking.
    ///
    /// So the picture is asserted again rather than assumed to have landed.
    /// Three cheap file reads, once per acquire, spread across the window in
    /// which the desktop was seen to be wrong.
    func scheduleStillReassert() {
        for delay in [2.0, 8.0, 20.0] {
            Self.lifecycleQueue.asyncAfter(deadline: .now() + delay) {
                let state = RendererState.shared
                state.refreshDesktopStill()
                // One line, on the last pass, so a bug report can say whether
                // this ran at all and what it had to draw. The earlier two are
                // silent on purpose: a playlist would otherwise fill the log.
                guard delay == 20.0 else { return }
                extensionLog(
                    "still reasserted surfaces=\(state.activeCount) "
                        + "still=\(DesktopStill.url != nil ? "yes" : "no")"
                )
            }
        }
    }

    private func remove(_ key: WallpaperSurfaceKey) {
        lock.lock()
        teardown[key] = nil
        let removed = active.removeValue(forKey: key)
        lock.unlock()
        removed?.renderer.stop()
        if removed != nil {
            extensionLog("released surface d=\(key.displayID) left=\(activeCount)")
        }
    }

    // MARK: - Playlist steps

    /// A step started for a surface and not finished yet: the file it is
    /// for, and a number so that only the newest step for a surface lands.
    private var pendingSteps: [WallpaperSurfaceKey: (generation: Int, identity: FileIdentity)] = [:]
    private var stepGeneration = 0

    /// Whether a surface built for a playlist or automation is still showing
    /// an earlier step than the file now staged behind its id. False for
    /// every wallpaper applied by hand.
    func isShowingEarlierStep(_ wallpaper: ActiveWallpaper) -> Bool {
        guard isRotationChoice(wallpaper.choiceID) else { return false }
        return FileIdentity.of(stagedVideoURL(for: wallpaper.choiceID)) != wallpaper.stagedIdentity
    }

    /// The app staged a different video behind a fixed id: the next step of a
    /// playlist or automation on the lock screen or the screen saver. Every
    /// surface showing that id changes to it in place, the context, the layer
    /// and the display all kept, so macOS sees no new wallpaper and nothing
    /// flashes.
    ///
    /// Locked or not. Waiting for the lock would race the app's own step on
    /// the same notification, and a surface behind the desktop is paused, so
    /// changing it early costs one decoded frame.
    func handleLibraryChanged() {
        Self.lifecycleQueue.async { RendererState.shared.swapPlaylistSteps() }
    }

    private func swapPlaylistSteps() {
        lock.lock()
        let showing = active.filter { key, wallpaper in
            isRotationChoice(wallpaper.choiceID) && teardown[key] == nil
        }
        lock.unlock()
        for (key, wallpaper) in showing {
            guard let url = stagedVideoURL(for: wallpaper.choiceID),
                  let identity = FileIdentity.of(url),
                  identity != wallpaper.stagedIdentity
            else { continue }
            // Nobody can see this surface: the lock screen's video while the
            // Mac is in use, or a screen saver whose display is asleep. Building
            // the step here decoded a video and wrote a picture at every step
            // for nothing. It is built when the surface is shown instead, from
            // whatever is staged by then. See `revealHeldSteps`.
            guard isShown(wallpaper) else {
                extensionTrace("playlist step d=\(key.displayID) waits until shown")
                continue
            }
            beginStep(for: key, from: wallpaper, url: url, identity: identity)
        }
    }

    /// A different video is staged behind this surface's fixed id than the one
    /// it is showing. Unlike `isShowingEarlierStep`, false when nothing is
    /// staged at all, so a surface whose files are gone is never left waiting
    /// on its picture for a step that cannot come.
    private func hasNewerStagedStep(_ wallpaper: ActiveWallpaper) -> Bool {
        guard isRotationChoice(wallpaper.choiceID),
              let staged = FileIdentity.of(stagedVideoURL(for: wallpaper.choiceID))
        else { return false }
        return staged != wallpaper.stagedIdentity
    }

    /// Whether macOS is showing this surface right now, by the same rule the
    /// playback policy uses.
    private func isShown(_ wallpaper: ActiveWallpaper) -> Bool {
        wallpaper.isScreenSaverSurface ? shouldScreenSaverPlay() : shouldPlayNow()
    }

    /// Builds the step a surface skipped while it was hidden, now that it is
    /// shown. The surface stays on its picture meanwhile (see
    /// `applyCurrentPlaybackPolicy`), so the first video anyone sees on it is
    /// the current one.
    private func revealHeldSteps() {
        lock.lock()
        let rotation = active.filter { key, wallpaper in
            isRotationChoice(wallpaper.choiceID) && teardown[key] == nil
        }
        lock.unlock()
        for (key, wallpaper) in rotation where wallpaper.isHeld && isShown(wallpaper) {
            guard let url = stagedVideoURL(for: wallpaper.choiceID),
                  let identity = FileIdentity.of(url),
                  identity != wallpaper.stagedIdentity
            else { continue }
            extensionLog("playlist step d=\(key.displayID) built on show")
            beginStep(for: key, from: wallpaper, url: url, identity: identity)
        }
    }

    /// How long one step crossfades into the next. The desktop uses the same,
    /// in `WallpaperWindowController`, so all three places change alike.
    static let stepCrossfade: TimeInterval = 0.6

    /// How long a step waits for macOS to say its first frame is ready before
    /// it changes without a fade. A frame is normally ready in well under a
    /// tenth of a second; this is only there so a step can never hang.
    static let stepReadyTimeout: TimeInterval = 2

    /// Builds the new step's video on the surface's own layer, underneath the
    /// old one, and holds it on its first frame. Once macOS says that frame
    /// is ready, the new video starts and the old one fades out over it, so a
    /// step is a crossfade and never shows a gap.
    ///
    /// Only a surface on screen gets here (see `swapPlaylistSteps`). If it was
    /// hidden again by the time the frame is ready, it changes at once, since
    /// there is nothing to fade.
    private func beginStep(
        for key: WallpaperSurfaceKey,
        from old: ActiveWallpaper,
        url: URL,
        identity: FileIdentity
    ) {
        lock.lock()
        if pendingSteps[key]?.identity == identity {
            lock.unlock()
            return
        }
        stepGeneration += 1
        let generation = stepGeneration
        pendingSteps[key] = (generation, identity)
        lock.unlock()

        // The frame kept behind the video belongs to the new step too, and the
        // one remembered for this id is the last step's.
        WallpaperFrame.forget(old.choiceID)
        let frame = WallpaperFrame.image(for: old.choiceID)
        let renderer: VideoRenderer
        do {
            renderer = try VideoRenderer.create(rootLayer: old.rootLayer, videoURL: url, behind: true)
        } catch {
            extensionLog("playlist step failed d=\(key.displayID): \(error.localizedDescription)")
            lock.lock()
            if pendingSteps[key]?.generation == generation { pendingSteps[key] = nil }
            lock.unlock()
            return
        }
        let fresh = old.carrying(renderer, identity: identity, fallback: frame)
        let play = fresh.isScreenSaverSurface ? shouldScreenSaverPlay() : shouldPlayNow()
        fresh.setShowingStill(!play)
        renderer.start(initiallyPaused: true) { composited in
            renderer.showFirstFrame()
            guard composited, play else {
                Self.lifecycleQueue.async {
                    RendererState.shared.finishStep(
                        for: key, old: old, fresh: fresh,
                        generation: generation, composited: composited, ready: false
                    )
                }
                return
            }
            renderer.whenReadyForDisplay(timeout: Self.stepReadyTimeout) { ready in
                Self.lifecycleQueue.async {
                    RendererState.shared.finishStep(
                        for: key, old: old, fresh: fresh,
                        generation: generation, composited: true, ready: ready
                    )
                }
            }
        }
    }

    /// `ready` is whether macOS said the new video's first frame is ready to
    /// show. Only then does the step fade; without it, it changes at once, as
    /// every step did before the fade.
    private func finishStep(
        for key: WallpaperSurfaceKey,
        old: ActiveWallpaper,
        fresh: ActiveWallpaper,
        generation: Int,
        composited: Bool,
        ready: Bool
    ) {
        lock.lock()
        let newest = pendingSteps[key]?.generation == generation
        if newest { pendingSteps[key] = nil }
        // Only onto the surface it was built for. One that macOS released, or
        // rebuilt, in the meantime has no use for it, and a newer step wins.
        let lands = newest && composited && active[key] === old && teardown[key] == nil
        if lands { active[key] = fresh }
        lock.unlock()

        guard lands else {
            // Stopped here, because nothing else holds it. It is underneath
            // the video on screen, so it goes without being seen.
            fresh.renderer.fadeOutAndStop(over: 0)
            if newest, !composited {
                extensionLog("playlist step drew nothing d=\(key.displayID), kept the last one")
            }
            return
        }
        // The screen may have locked or unlocked while the new video was being
        // built, and the policy that ran then only reached the old one.
        let play = fresh.isScreenSaverSurface ? shouldScreenSaverPlay() : shouldPlayNow()
        play ? fresh.renderer.resume() : fresh.renderer.pause()
        fresh.setShowingStill(!play)
        if fresh.drawsStill { fresh.setStill(DesktopStill.current(displayID: fresh.displayID)) }
        // The old video goes last, on top of the new one, so the new one is
        // what shows through it.
        let fades = play && ready
        old.renderer.fadeOutAndStop(over: fades ? Self.stepCrossfade : 0)
        extensionLog(
            "playlist step d=\(key.displayID) "
                + "\(fresh.isScreenSaverSurface ? "saver" : "lock") \(play ? "playing" : "held")"
                + (play && !fades ? " without a fade" : "")
        )
    }
}

import AppKit
import AVFoundation

/// Owns one wallpaper window on one screen: a borderless, click-through
/// window seated just below the desktop icons, containing an AVPlayerLayer
/// that loops a video via AVPlayerLooper (seek-free, no loop hitch).
///
/// Playback pauses whenever the window is not actually visible — fullscreen
/// app covering the desktop, screen locked, or displays asleep — so the
/// engine costs 0% CPU exactly when nobody can see the wallpaper.
public final class WallpaperWindowController {
    private let window: NSWindow
    private var player: AVQueuePlayer
    private var playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private var observers: [NSObjectProtocol] = []
    private var currentURL: URL

    /// A wallpaper change builds a second player on a second layer above the
    /// first, and only takes the old one down once the new one has a frame to
    /// show. Swapping the item on the single existing layer would blink black
    /// while the new file loads, which at the ten second steps automations
    /// allow would be constant.
    private struct PendingVideo {
        let player: AVQueuePlayer
        let layer: AVPlayerLayer
        let looper: AVPlayerLooper
    }

    private var pending: PendingVideo?
    private var readyObservation: NSKeyValueObservation?
    private var swapTimeout: DispatchWorkItem?

    /// The crossfade is short on purpose: long enough not to read as a cut,
    /// short enough that two videos are rarely decoding at once.
    private static let crossfadeSeconds = 0.45

    /// Both the visible player and any swap still in flight, so a pause or a
    /// speed change never leaves the incoming video out of step.
    private var allPlayers: [AVQueuePlayer] {
        pending.map { [player, $0.player] } ?? [player]
    }

    /// True while a condition (lock/sleep/occlusion/user pause) is holding
    /// playback. Playback resumes only when every hold is released.
    private var holds = Set<String>()
    private var pauseAfterSeconds: Int?
    private var settleTimer: Timer?
    private var desiredRate: Float = 1.0
    /// Settings toggle. Off means the wallpaper keeps playing even when it is
    /// covered, which costs CPU for something nobody can see, so it stays on
    /// unless the user deliberately turns it off.
    private var autoPauseFullScreen = true

    public init(screen: NSScreen, videoURL: URL) {
        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // One below the desktop icon layer: video sits above the static
        // wallpaper, below the icons — icons stay visible and clickable.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false

        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill

        let contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        contentView.wantsLayer = true
        playerLayer.frame = contentView.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView.layer?.addSublayer(playerLayer)
        window.contentView = contentView

        currentURL = videoURL
        let item = AVPlayerItem(url: videoURL)
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    // MARK: - Changing wallpaper without rebuilding the window

    /// Replaces the looping video on this screen, crossfading to it.
    ///
    /// The engine used to answer a wallpaper change by destroying this whole
    /// controller and building a new NSWindow and AVPlayer, which flashed
    /// black and spiked CPU on every switch.
    public func setVideo(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        discardPendingSwap()

        let nextPlayer = AVQueuePlayer()
        nextPlayer.isMuted = true
        nextPlayer.preventsDisplaySleepDuringVideoPlayback = false

        let nextLayer = AVPlayerLayer(player: nextPlayer)
        nextLayer.videoGravity = .resizeAspectFill
        nextLayer.frame = playerLayer.frame
        nextLayer.autoresizingMask = playerLayer.autoresizingMask
        nextLayer.opacity = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.contentView?.layer?.addSublayer(nextLayer)
        CATransaction.commit()

        let nextLooper = AVPlayerLooper(player: nextPlayer, templateItem: AVPlayerItem(url: url))
        pending = PendingVideo(player: nextPlayer, layer: nextLayer, looper: nextLooper)
        // A new wallpaper is a new chance to watch it move, including every
        // automation and playlist step.
        release("settled")
        armSettleTimer()
        if holds.isEmpty { nextPlayer.playImmediately(atRate: desiredRate) }

        // `isReadyForDisplay` is the layer saying it has a frame to draw. Only
        // then is it safe to take the outgoing video away.
        readyObservation = nextLayer.observe(
            \.isReadyForDisplay, options: [.initial, .new]
        ) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.completeSwap() }
        }

        // A damaged or unreadable file may never become ready. Rather than
        // leave a dead layer stacked on the window forever, give up and show
        // it anyway after a moment.
        let timeout = DispatchWorkItem { [weak self] in self?.completeSwap() }
        swapTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func completeSwap() {
        guard let incoming = pending else { return }
        pending = nil
        readyObservation = nil
        swapTimeout?.cancel()
        swapTimeout = nil

        let outgoingPlayer = player
        let outgoingLayer = playerLayer
        let outgoingLooper = looper

        player = incoming.player
        playerLayer = incoming.layer
        looper = incoming.looper

        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.crossfadeSeconds)
        CATransaction.setCompletionBlock {
            outgoingLooper?.disableLooping()
            outgoingPlayer.pause()
            outgoingPlayer.removeAllItems()
            outgoingLayer.player = nil
            outgoingLayer.removeFromSuperlayer()
        }
        incoming.layer.opacity = 1
        CATransaction.commit()

        EngineLog.log("switched to \(currentURL.lastPathComponent)")
    }

    /// Drops a swap that never completed, e.g. two wallpaper changes in quick
    /// succession, so layers cannot pile up on the window.
    private func discardPendingSwap() {
        readyObservation = nil
        swapTimeout?.cancel()
        swapTimeout = nil
        guard let stale = pending else { return }
        pending = nil
        stale.looper.disableLooping()
        stale.player.pause()
        stale.player.removeAllItems()
        stale.layer.player = nil
        stale.layer.removeFromSuperlayer()
    }

    public func start() {
        window.orderFrontRegardless()
        player.playImmediately(atRate: desiredRate)
        installObservers()
        armSettleTimer()
    }

    public func stop() {
        discardPendingSwap()
        settleTimer?.invalidate()
        settleTimer = nil
        player.pause()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        window.orderOut(nil)
    }

    /// Menu-bar play/pause. A user pause is just another hold, so it
    /// composes cleanly with lock/sleep/occlusion.
    public func setUserPaused(_ paused: Bool) {
        paused ? hold("user") : release("user")
    }

    /// Power-driven pause (Low Power Mode / low battery), gated by the
    /// Settings toggles in EngineController. Plain holds, so they compose
    /// with lock/sleep/occlusion/user pause and release cleanly.
    public func setPowerPause(lowPower: Bool, lowBattery: Bool) {
        lowPower ? hold("low-power-mode") : release("low-power-mode")
        lowBattery ? hold("low-battery") : release("low-battery")
    }

    /// Occlusion pause from Settings. Turning it off releases any occlusion
    /// hold immediately, so the wallpaper resumes without waiting for the
    /// window to become visible again.
    public func setAutoPauseFullScreen(_ enabled: Bool) {
        guard enabled != autoPauseFullScreen else { return }
        autoPauseFullScreen = enabled
        occlusionChanged()
    }

    /// "Pause after": let a wallpaper move for a while when it starts, then
    /// freeze it on a frame. Zero or nil means it never freezes.
    ///
    /// It is an ordinary hold named `settled`, so it composes with lock,
    /// sleep, occlusion and the user pause exactly like the rest, and the
    /// wallpaper only actually resumes when every hold is gone.
    public func setPauseAfter(_ seconds: Int?) {
        let normalized = PauseAfter.normalise(seconds)
        guard normalized != pauseAfterSeconds else { return }
        pauseAfterSeconds = normalized
        armSettleTimer()
    }

    /// Restarts the clock. Called whenever playback genuinely begins again:
    /// a new wallpaper, an unlock, a resume from any other hold.
    private func armSettleTimer() {
        settleTimer?.invalidate()
        settleTimer = nil
        release("settled")
        guard let seconds = pauseAfterSeconds, holds.isEmpty else { return }
        let timer = Timer(timeInterval: Double(seconds), repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.settle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func settle() {
        settleTimer = nil
        hold("settled")
    }

    /// Playback speed from Settings (0.5×–1.5×). Applied live when playing.
    public func setPlaybackRate(_ rate: Float) {
        guard abs(rate - desiredRate) > 0.001 else { return }
        desiredRate = rate
        for player in allPlayers where player.rate > 0 { player.rate = rate }
    }

    // MARK: - Visibility-driven pause/resume

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            self?.occlusionChanged()
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.hold("display-sleep")
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.release("display-sleep")
        })

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.hold("screen-lock")
        })
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // Unlocking is the other moment the issue asks about: the desktop
            // reappears, so it gets its window of motion again.
            self?.release("screen-lock")
            self?.armSettleTimer()
        })
    }

    private func occlusionChanged() {
        if window.occlusionState.contains(.visible) || !autoPauseFullScreen {
            release("occluded")
        } else {
            hold("occluded")
        }
    }

    private func hold(_ reason: String) {
        let wasEmpty = holds.isEmpty
        holds.insert(reason)
        if wasEmpty {
            allPlayers.forEach { $0.pause() }
            EngineLog.log("paused (\(reason))")
        }
    }

    private func release(_ reason: String) {
        holds.remove(reason)
        guard holds.isEmpty else { return }
        let stopped = allPlayers.filter { $0.rate == 0 }
        guard !stopped.isEmpty else { return }
        stopped.forEach { $0.playImmediately(atRate: desiredRate) }
        EngineLog.log("resumed (\(reason) cleared)")
        // Playback really did just start again, so the settle clock starts
        // again with it. Not for `settled` itself, which would loop.
        if reason != "settled" { armSettleTimer() }
    }
}

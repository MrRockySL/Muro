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
    private let player: AVQueuePlayer
    private let playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private var observers: [NSObjectProtocol] = []

    /// True while a condition (lock/sleep/occlusion/user pause) is holding
    /// playback. Playback resumes only when every hold is released.
    private var holds = Set<String>()
    private var desiredRate: Float = 1.0

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

        let item = AVPlayerItem(url: videoURL)
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    public func start() {
        window.orderFrontRegardless()
        player.playImmediately(atRate: desiredRate)
        installObservers()
    }

    public func stop() {
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

    /// Playback speed from Settings (0.5×–1.5×). Applied live when playing.
    public func setPlaybackRate(_ rate: Float) {
        guard abs(rate - desiredRate) > 0.001 else { return }
        desiredRate = rate
        if player.rate > 0 { player.rate = rate }
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
            self?.release("screen-lock")
        })
    }

    private func occlusionChanged() {
        if window.occlusionState.contains(.visible) {
            release("occluded")
        } else {
            hold("occluded")
        }
    }

    private func hold(_ reason: String) {
        let wasEmpty = holds.isEmpty
        holds.insert(reason)
        if wasEmpty {
            player.pause()
            EngineLog.log("paused (\(reason))")
        }
    }

    private func release(_ reason: String) {
        holds.remove(reason)
        if holds.isEmpty && player.rate == 0 {
            player.playImmediately(atRate: desiredRate)
            EngineLog.log("resumed (\(reason) cleared)")
        }
    }
}

import SwiftUI
import AVFoundation
import AppKit

/// Muted, seamlessly looping in-window video (hero + full-screen preview).
/// Same AVQueuePlayer + AVPlayerLooper technique as the engine, so previews
/// are hardware-decoded and cheap.
struct LoopingPlayerView: NSViewRepresentable {
    let url: URL
    /// Holds playback for a reason the view cannot see for itself, e.g. the
    /// Home hero sitting behind a full screen preview. Occlusion, minimising
    /// and window close are detected by the view without this.
    var isActive = true

    func makeNSView(context: Context) -> LoopingPlayerNSView { LoopingPlayerNSView() }

    func updateNSView(_ view: LoopingPlayerNSView, context: Context) {
        view.play(url: url)
        view.setActive(isActive)
    }
}

/// Playback follows the same rule the wallpaper engine uses: decode only when
/// somebody can actually see the picture. Without this the hero kept decoding
/// 4K behind other windows, while minimised, and underneath the full screen
/// preview, which is exactly the CPU the app promises not to spend.
final class LoopingPlayerNSView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var isActive = true
    private var occlusionObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        // Cheap re-check while the view is on screen, in case the window was
        // already visible when the view was installed and no occlusion
        // notification ever arrived.
        updatePlayback()
    }

    /// Occlusion is reported per window, and a minimised or hidden window
    /// counts as not visible, so this one notification covers every case.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                self?.updatePlayback()
            }
        }
        updatePlayback()
    }

    func play(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        looper = nil
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        updatePlayback()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        updatePlayback()
    }

    /// Read live rather than cached, so a stale flag can never leave the video
    /// paused on a window that is plainly on screen.
    private var windowIsVisible: Bool {
        guard let window else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func updatePlayback() {
        let shouldPlay = isActive && windowIsVisible && currentURL != nil
        if shouldPlay {
            if player.rate == 0 { player.play() }
        } else if player.rate != 0 {
            player.pause()
        }
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        player.pause()
    }
}

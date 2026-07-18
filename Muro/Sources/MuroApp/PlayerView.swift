import SwiftUI
import AVFoundation

/// Muted, seamlessly looping in-window video (hero + full-screen preview).
/// Same AVQueuePlayer + AVPlayerLooper technique as the engine, so previews
/// are hardware-decoded and cheap.
struct LoopingPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> LoopingPlayerNSView { LoopingPlayerNSView() }
    func updateNSView(_ view: LoopingPlayerNSView, context: Context) { view.play(url: url) }
}

final class LoopingPlayerNSView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

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
    }

    func play(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        looper = nil
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    deinit { player.pause() }
}

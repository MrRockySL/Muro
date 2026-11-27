import AppKit

/// A static wallpaper on one screen (owner, 2026-11-27): the same kind of
/// window a live wallpaper plays in, seated just below the desktop icons on
/// every Space, showing a picture instead of a video.
///
/// Nothing plays, so it costs no CPU at all once it is up. The picture is
/// decoded once, off the main thread, at the size this screen needs to be
/// filled edge to edge, and never bigger than it is.
///
/// Like an interactive wallpaper's page it fades in over whatever the screen
/// showed, and says so (`onShown`), so the engine takes the old one away only
/// once it is covered and nothing blinks.
public final class StillWindowController {
    private let window: NSWindow
    private let screen: NSScreen
    private let picture: URL
    private let pictureLayer = CALayer()
    private var stopped = false
    private var shown = false

    /// The picture has faded in and covers whatever was on this screen before.
    public var onShown: (() -> Void)?

    /// The same as a change of live wallpaper.
    private static let fadeSeconds = 0.6

    public init(screen: NSScreen, picture: URL) {
        self.screen = screen
        self.picture = picture
        window = NSWindow(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Command-H hides an app's windows; the wallpaper is not interface.
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        pictureLayer.frame = content.bounds
        pictureLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        pictureLayer.contentsGravity = .resizeAspectFill
        pictureLayer.contentsScale = screen.backingScaleFactor
        pictureLayer.masksToBounds = true
        content.layer?.addSublayer(pictureLayer)
        window.contentView = content
    }

    /// Decodes the picture behind a window nobody can see yet, then fades the
    /// window in.
    public func start() {
        window.alphaValue = 0
        window.orderFrontRegardless()
        let url = picture
        let scale = screen.backingScaleFactor
        let screenPixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = StaticStill.pixelSize(of: url) ?? screenPixels
            let image = StaticStill.image(
                at: url, maxPixels: StaticStill.fillPixels(picture: size, screen: screenPixels)
            )
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                if image == nil {
                    EngineLog.log("could not read \(url.lastPathComponent)")
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.pictureLayer.contents = image
                CATransaction.commit()
                self.show()
            }
        }
    }

    private func show() {
        guard !shown, !stopped else { return }
        shown = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self, !self.stopped else { return }
            self.onShown?()
        })
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        window.orderOut(nil)
        pictureLayer.contents = nil
    }
}

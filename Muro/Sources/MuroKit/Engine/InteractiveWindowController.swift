import AppKit

/// Owns one interactive wallpaper on one screen (issue #59): the same
/// borderless, click-through window a live wallpaper plays in, just below the
/// desktop icons, with a web page in it instead of a video.
///
/// It is paused by the same things, each a hold of the same name as in
/// `WallpaperWindowController`: the menu bar's pause, a covered or locked or
/// sleeping screen, Low Power Mode, a low battery, and Play only on desktop.
/// A paused page draws nothing and is told nothing, and the Mac's sound is
/// listened to only while a page that asked for it is moving.
public final class InteractiveWindowController {
    private let window: NSWindow
    private let page: InteractivePage
    private let screen: NSScreen
    private var observers: [NSObjectProtocol] = []
    private var holds = Set<String>()
    private var autoPauseFullScreen = true
    private var playOnlyOnDesktop = false
    private var desktopCovered: Bool?
    private var listening: UUID?
    private var stopped = false
    private var shown = false
    private var pointerInside = false

    /// The page has faded in and covers whatever was on this screen before.
    public var onShown: (() -> Void)?

    /// How long the page takes to fade in over what was there. The same as a
    /// change of live wallpaper.
    private static let fadeSeconds = 0.6

    public init(screen: NSScreen, index: URL) {
        self.screen = screen
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
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        page = InteractivePage(index: index, frame: NSRect(origin: .zero, size: screen.frame.size))
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        page.view.frame = content.bounds
        content.addSubview(page.view)
        window.contentView = content
    }

    /// Loads the page behind a window nobody can see yet, and fades the
    /// window in once the page has drawn, so the screen never shows a blank.
    public func start() {
        window.alphaValue = 0
        window.orderFrontRegardless()
        installObservers()
        page.onWantsAudio = { [weak self] in self?.updateListening() }
        page.onReady = { [weak self] in self?.show() }
        page.load()
        // A page that never says it is ready is shown anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.show() }
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
        stopListening()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        page.close()
        window.orderOut(nil)
    }

    // MARK: - What the engine tells it

    public func setUserPaused(_ paused: Bool) {
        paused ? hold("user") : release("user")
    }

    public func setPowerPause(lowPower: Bool, lowBattery: Bool) {
        lowPower ? hold("low-power-mode") : release("low-power-mode")
        lowBattery ? hold("low-battery") : release("low-battery")
    }

    public func setAutoPauseFullScreen(_ enabled: Bool) {
        guard enabled != autoPauseFullScreen else { return }
        autoPauseFullScreen = enabled
        occlusionChanged()
    }

    public func setPlayOnlyOnDesktop(_ on: Bool) {
        guard on != playOnlyOnDesktop else { return }
        playOnlyOnDesktop = on
        applyDesktopHold()
    }

    public func setDesktopCovered(_ covered: Bool?) {
        guard covered != desktopCovered else { return }
        desktopCovered = covered
        applyDesktopHold()
    }

    private func applyDesktopHold() {
        if DesktopPlayback.holds(isCovered: desktopCovered, playOnlyOnDesktop: playOnlyOnDesktop) {
            hold("desktop-covered")
        } else {
            release("desktop-covered")
        }
    }

    /// Where the pointer is, in the screen coordinates AppKit uses, and
    /// whether it is over the desktop itself rather than an app window.
    public func pointer(at point: NSPoint, onDesktop: Bool) {
        guard holds.isEmpty else { return }
        let place = self.place(point)
        // The page answers only a pointer on this display's own desktop. One
        // over an app window or on another display is told once, as it
        // leaves; after that the page hears nothing until it comes back.
        let inside = place.inside && onDesktop
        guard inside || pointerInside else { return }
        pointerInside = inside
        page.mouse(x: place.x, y: place.y, inside: inside)
    }

    /// A click on the desktop, in the screen coordinates AppKit uses.
    public func click(at point: NSPoint) {
        guard holds.isEmpty else { return }
        let place = self.place(point)
        if place.inside { page.click(x: place.x, y: place.y) }
    }

    private func place(_ point: NSPoint) -> (x: Double, y: Double, inside: Bool) {
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return (0.5, 0.5, false) }
        return (
            Double((point.x - frame.minX) / frame.width),
            Double(1 - (point.y - frame.minY) / frame.height),
            frame.contains(point)
        )
    }

    // MARK: - Holds

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in self?.occlusionChanged() })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hold("display-sleep") })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.release("display-sleep") })

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.hold("screen-lock") })
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.release("screen-lock") })
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
        guard wasEmpty else { return }
        page.setPaused(true)
        updateListening()
        EngineLog.log("interactive paused (\(reason))")
    }

    private func release(_ reason: String) {
        guard holds.remove(reason) != nil, holds.isEmpty else { return }
        page.setPaused(false)
        updateListening()
        EngineLog.log("interactive resumed (\(reason) cleared)")
    }

    // MARK: - Sound

    /// Listens only while the page asked for sound and is moving.
    private func updateListening() {
        let wanted = !stopped && page.wantsAudio && holds.isEmpty
        if wanted, listening == nil {
            listening = SystemSound.shared.add { [weak self] bands in self?.page.audio(bands) }
        } else if !wanted {
            stopListening()
        }
    }

    private func stopListening() {
        guard let id = listening else { return }
        listening = nil
        SystemSound.shared.remove(id)
        // The page settles back instead of freezing on the last beat.
        page.audio([Float](repeating: 0, count: InteractiveBridge.bandCount))
    }
}

/// Watches the pointer for interactive wallpapers, which sit under a window
/// that lets every click through and so never see it themselves.
///
/// An interactive wallpaper answers only a pointer that is on the desktop
/// itself. Over an app window the pointer is told once, as it gets there, and
/// then not again until it is back on the desktop: somebody at work in an app
/// is not playing with the wallpaper behind it.
///
/// Only where the pointer is and that a click landed on the desktop are read,
/// never what was clicked. Watching the mouse needs no permission. It runs
/// only while an interactive wallpaper is on a screen.
public final class PointerWatcher {
    /// The pointer moved, in AppKit's screen coordinates, and whether it is
    /// over the desktop itself rather than over an app window.
    public var onMove: ((NSPoint, Bool) -> Void)?
    /// A click landed on the desktop itself, not on a window.
    public var onClick: ((NSPoint) -> Void)?

    private var monitors: [Any] = []
    private var lastSent = DispatchTime(uptimeNanoseconds: 0)
    private var trailing: DispatchWorkItem?
    /// At most this often, however fast the mouse reports.
    private static let interval: UInt64 = 14_000_000
    /// Where the app windows were at the last look, in the window list's own
    /// coordinates, and when that look was. Looking means reading the window
    /// list, so it is done a few times a second, not for every move; every
    /// move is checked against the last look, so the edge of a window is felt
    /// where it is.
    private var windows: [CGRect] = []
    private var lookedAt = DispatchTime(uptimeNanoseconds: 0)
    private static let lookEvery: UInt64 = 200_000_000
    /// Whether the last place handed on was on the desktop.
    private var toldOnDesktop = false

    public init() {}

    deinit { stop() }

    public var isRunning: Bool { !monitors.isEmpty }

    public func start() {
        guard monitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            self?.moved()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.moved()
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.clicked()
        }) { monitors.append(monitor) }
        moved()
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        trailing?.cancel()
        trailing = nil
        windows = []
        lookedAt = DispatchTime(uptimeNanoseconds: 0)
        toldOnDesktop = false
    }

    /// Sends now, or once more a moment later, so the last place the pointer
    /// stopped is never the one that was skipped. Over an app window it sends
    /// only the first move.
    private func moved() {
        let now = DispatchTime.now()
        if now.uptimeNanoseconds - lookedAt.uptimeNanoseconds >= Self.lookEvery {
            lookedAt = now
            windows = Self.appWindows()
        }
        let point = NSEvent.mouseLocation
        let onDesktop = Self.isOnDesktop(point, windows: windows)
        guard onDesktop || toldOnDesktop else {
            trailing?.cancel()
            trailing = nil
            return
        }
        // Leaving the desktop is told at once, so the wallpaper lets go of
        // the pointer the moment it reaches a window.
        if !onDesktop || now.uptimeNanoseconds - lastSent.uptimeNanoseconds >= Self.interval {
            send(point, onDesktop: onDesktop)
            return
        }
        guard trailing == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trailing = nil
            let point = NSEvent.mouseLocation
            let onDesktop = Self.isOnDesktop(point, windows: self.windows)
            guard onDesktop || self.toldOnDesktop else { return }
            self.send(point, onDesktop: onDesktop)
        }
        trailing = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.interval)), execute: item)
    }

    private func send(_ point: NSPoint, onDesktop: Bool) {
        lastSent = .now()
        toldOnDesktop = onDesktop
        onMove?(point, onDesktop)
    }

    private func clicked() {
        let point = NSEvent.mouseLocation
        guard Self.isOnDesktop(point, windows: Self.appWindows()) else { return }
        onClick?(point)
    }

    /// Where the app windows on screen are. Only positions and layers are
    /// read, by the same rule as Play only on desktop: the Dock, the menu bar
    /// and desktop widgets are not app windows.
    static func appWindows() -> [CGRect] {
        DesktopCoverage.onScreenWindows().filter(DesktopCoverage.counts).map(\.bounds)
    }

    /// Whether no app window is under this point. The window list is in
    /// coordinates that start at the top left of the main display; AppKit's
    /// start at its bottom left.
    static func isOnDesktop(_ point: NSPoint, windows: [CGRect]) -> Bool {
        guard !windows.isEmpty, let main = NSScreen.screens.first else { return true }
        let flipped = CGPoint(x: point.x, y: main.frame.maxY - point.y)
        return !windows.contains { $0.contains(flipped) }
    }
}

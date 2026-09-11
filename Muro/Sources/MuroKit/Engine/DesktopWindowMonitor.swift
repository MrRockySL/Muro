import AppKit

/// Issue #22. Looks at the window list while either desktop switch is on and
/// reports, by display UUID, which screens have an app window open on them.
///
/// macOS posts nothing when a window on a screen is minimised or closed, so a
/// cheap look on a timer is the only way to notice everything without asking
/// for Accessibility. The timer is the floor, not the speed: a click, an app
/// switch, a hide, a launch, a quit or a Space change each start a short run
/// of looks timed to catch windows as they finish opening, closing or sliding
/// away, so the common cases answer in a few tenths of a second.
public final class DesktopWindowMonitor {
    /// Fired on the main queue after every look, with every screen that has an
    /// app window on it. A display missing from the set has a clear desktop.
    public var onUpdate: ((Set<String>) -> Void)?

    /// Between events. Short enough that a window closed or minimised from
    /// the keyboard, which nothing announces, is noticed within half a second.
    private static let interval: TimeInterval = 0.5
    /// After a click or an app switch, windows open, close, minimise and slide
    /// over the next few tenths of a second, so look again as they settle.
    private static let followUps: [TimeInterval] = [0.1, 0.25, 0.45, 0.75]
    /// How long a desktop has to stay clear before it is reported clear. See
    /// `DesktopCoverage.settle`.
    private static let confirmDelay: TimeInterval = 0.12

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitors: [Any] = []
    private var followUpLooks: [DispatchWorkItem] = []
    private var confirmation: DispatchWorkItem?
    private var reported: Set<String>?

    public init() {}

    deinit { stop() }

    /// Starts looking if it is not already, and looks once straight away
    /// either way, so a display that has just been added gets its reading.
    public func start() {
        if timer == nil {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.look() }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer

            let center = NSWorkspace.shared.notificationCenter
            let names: [Notification.Name] = [
                NSWorkspace.didActivateApplicationNotification,
                NSWorkspace.didHideApplicationNotification,
                NSWorkspace.didUnhideApplicationNotification,
                NSWorkspace.didLaunchApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
                NSWorkspace.activeSpaceDidChangeNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.lookAsWindowsSettle()
                })
            }

            // Most windows are opened, closed, minimised and revealed with a
            // click, so a click is the earliest sign that one is about to
            // change. Only the fact that a click happened is used, never where
            // it landed or on what. Watching the mouse needs no permission;
            // watching keys would.
            let clicks: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp]
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
                self?.lookAsWindowsSettle()
            }) {
                clickMonitors.append(monitor)
            }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
                self?.lookAsWindowsSettle()
                return event
            }) {
                clickMonitors.append(monitor)
            }
        }
        look()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors.removeAll()
        followUpLooks.forEach { $0.cancel() }
        followUpLooks.removeAll()
        confirmation?.cancel()
        confirmation = nil
        reported = nil
    }

    /// Looks now, and again as the windows involved finish moving. A new event
    /// replaces the looks still waiting from the last one, so a burst of
    /// clicks costs no more than the clicks themselves.
    private func lookAsWindowsSettle() {
        look()
        followUpLooks.forEach { $0.cancel() }
        followUpLooks = Self.followUps.map { delay in
            let item = DispatchWorkItem { [weak self] in self?.look() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func look(confirming: Bool = false) {
        var screens: [String: CGRect] = [:]
        for screen in NSScreen.screens {
            guard let uuid = displayUUID(for: screen),
                  let id = directDisplayID(for: screen)
            else { continue }
            screens[uuid] = CGDisplayBounds(id)
        }
        let covered = DesktopCoverage.coveredScreens(
            windows: DesktopCoverage.onScreenWindows(), screens: screens
        )
        let next = DesktopCoverage.settle(previous: reported, current: covered, confirming: confirming)
        reported = next.report
        onUpdate?(next.report)
        if next.needsConfirmation { confirmSoon() }
    }

    private func confirmSoon() {
        guard confirmation == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.confirmation = nil
            self?.look(confirming: true)
        }
        confirmation = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmDelay, execute: item)
    }
}

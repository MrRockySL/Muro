import SwiftUI
import AppKit

/// Custom menu bar item + dropdown panel. Replaces MenuBarExtra(.window):
/// on macOS 26+ its system window draws a large glass sheet of its own
/// around the content — the "double panel" look (owner feedback). Here the
/// panel window is fully transparent and the only visible surface is our
/// rounded dark-glass card.
@MainActor
final class StatusBarController: NSObject {
    static private(set) var shared: StatusBarController?

    private var statusItem: NSStatusItem?
    private let panel: NSPanel
    private let container = NSView()
    private let hostingView: NSHostingView<MenuBarPanelRoot>
    private var eventMonitors: [Any] = []
    /// When the panel is open and the status item is clicked, a dismissal
    /// monitor sees that click first and closes the panel; the button's own
    /// action then runs against an already-closed panel and reopens it, so it
    /// never shuts. Anything reopening within this window of a close is that
    /// same click coming back around, and gets ignored.
    private var lastCloseAt: Date = .distantPast
    private let reopenSuppression: TimeInterval = 0.25

    init(store: AppStore) {
        hostingView = FirstMouseHostingView(rootView: MenuBarPanelRoot(store: store))

        panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        container.wantsLayer = true
        container.layer?.cornerRadius = 26
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = container

        super.init()
        StatusBarController.shared = self
        syncStatusItemVisibility()
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil
        )
    }

    // MARK: - Status item

    @objc private func defaultsChanged() {
        Task { @MainActor in self.syncStatusItemVisibility() }
    }

    private func syncStatusItemVisibility() {
        let show = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = MuroGlyph.menuBarImage()
            item.button?.target = self
            item.button?.action = #selector(togglePanel)
            statusItem = item
        } else if !show, let item = statusItem {
            closePanel()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Panel

    @objc func togglePanel() {
        if panel.isVisible {
            closePanel()
            return
        }
        guard Date().timeIntervalSince(lastCloseAt) > reopenSuppression else { return }
        openPanel()
    }

    private func openPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let size = hostingView.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.midX - size.width / 2
        if let screen = buttonWindow.screen {
            x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        }
        let y = anchor.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        button.highlight(true)
        installEventMonitors()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastCloseAt = Date()
        statusItem?.button?.highlight(false)
        removeEventMonitors()
    }

    // MARK: - Dismissal (click outside / Esc)

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        if let global { eventMonitors.append(global) }

        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closePanel(); return nil }   // Esc
                return event
            }
            let window = event.window
            let inPanel = window === self.panel
                || (window.map { self.panel.childWindows?.contains($0) ?? false } ?? false)
                // GlassDropdown popovers present in their own popover windows.
                || (window.map { String(describing: type(of: $0)).contains("Popover") } ?? false)
            let onStatusButton = window === self.statusItem?.button?.window
            if !inPanel && !onStatusButton { self.closePanel() }
            return event
        }
        if let local { eventMonitors.append(local) }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
    }
}

/// Borderless panels refuse key status by default; the dropdown needs it so
/// buttons, hover and popovers inside react without activating the app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel never activates the app, so without this the first click on any
/// control is swallowed by click-through protection.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The SwiftUI content of the dropdown. The dark wash sits between the
/// behind-window blur below and the controls above (same recipe as the
/// Settings window's glass).
struct MenuBarPanelRoot: View {
    @ObservedObject var store: AppStore

    var body: some View {
        MenuBarView()
            .environmentObject(store)
            .background(Color.black.opacity(0.25))
            .preferredColorScheme(.dark)
    }
}

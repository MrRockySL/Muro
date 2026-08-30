import SwiftUI
import AppKit
import MuroKit

/// The Muro app: gallery window + settings + menu bar, with the wallpaper
/// engine embedded (one process, one config, instant hot-reload).
@MainActor
final class MuroAppDelegate: NSObject, NSApplicationDelegate {
    let engine = EngineController()
    private var statusBar: StatusBarController?

    /// True when macOS started Muro at login rather than a person opening it.
    private var startedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Read here and nowhere later. The launch Apple event only sits on the
        // queue while the app is starting, so by the time anything else could
        // ask, the answer is gone.
        startedAtLogin = Self.launchedAsLoginItem()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyActivationPolicy()
        engine.start()
        statusBar = StatusBarController(store: AppStore.shared)

        // Starting at login is the Mac booting, not a person asking to see the
        // gallery. Muro used to throw its full window on screen every single
        // boot, which had to be closed by hand every single time. It starts in
        // the menu bar now and waits to be asked.
        if startedAtLogin {
            hideMainWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Opening an app that is already running, from Spotlight, the Dock or
    /// Finder. Without this the click did nothing at all: the window is only
    /// ordered out, not closed, so nothing reopened it and the only way back
    /// in was the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.applyActivationPolicy()
        showMainWindow()
        return true
    }

    /// Re-assert the Dock setting whenever Muro comes to the front.
    ///
    /// Launching an already-running Muro from Spotlight left an icon in the
    /// Dock even with "Show Dock icon" switched off, and it stayed there. The
    /// only cure anyone found was opening Settings and flicking that toggle on
    /// and off, which is nothing more than calling `setActivationPolicy`
    /// again. So call it again here, where it costs nothing and no one has to
    /// know the trick.
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.applyActivationPolicy()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep playing wallpapers from the menu bar
    }

    // MARK: - Helpers

    /// The Dock icon setting, applied. Idempotent, so it is safe to call on
    /// every activation.
    static func applyActivationPolicy() {
        let showDock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        let wanted: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }

    /// Did macOS start us as a login item?
    ///
    /// There is no flag on `NSApplication` for this. The launch Apple event
    /// carries it: an `oapp` event with a `prdt` parameter of `lgit`. This is
    /// the documented way and it is what `SMAppService` login starts send.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?
            .enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Put the gallery away without closing it.
    ///
    /// Run more than once on purpose. SwiftUI creates the `Window` scene's
    /// `NSWindow` around launch rather than at a moment we control, so a
    /// single pass here can happen before the window exists and miss it. The
    /// later passes are cheap and catch that case.
    private func hideMainWindow() {
        mainWindow?.orderOut(nil)
        Task { @MainActor in
            mainWindow?.orderOut(nil)
            try? await Task.sleep(nanoseconds: 250_000_000)
            mainWindow?.orderOut(nil)
        }
    }
}

@main
struct MuroApp: App {
    @NSApplicationDelegateAdaptor(MuroAppDelegate.self) var delegate
    @StateObject private var store = AppStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window(MuroWindow.gallery, id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
                .onAppear {
                    SettingsWindowOpener.shared.open = { openWindow(id: "settings") }
                    // Here rather than in the delegate: the window is what is
                    // being reconfigured, and by the time its content appears
                    // it definitely exists. Re-applied on every appearance, so
                    // it survives the window being rebuilt.
                    makeMinimiseHideTheWindow(titled: MuroWindow.gallery)
                }
        }
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.hiddenTitleBar)

        Window(MuroWindow.settings, id: "settings") {
            SettingsView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onAppear { makeMinimiseHideTheWindow(titled: MuroWindow.settings) }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack(alignment: .top) {
            Color.muroBG.ignoresSafeArea()

            // A straight crossfade. The per-tab .id makes SwiftUI treat each
            // page as insert/remove so the transition actually fires.
            //
            // No slide here, unlike everywhere else in the app. See
            // `.muroTab`: these are whole windows, so moving one moves its
            // background and resizes the glass tray's corners with it.
            Group {
                switch store.tab {
                case .home: HomeView()
                case .explore: ExploreView()
                case .library: LibraryView()
                }
            }
            .id(store.tab)
            .transition(.opacity)

            TopBar()

            if let preview = store.previewItem {
                PreviewView(itemID: preview.id)
                    .zIndex(10)
                    .transition(.opacity)
            }
        }
        .animation(.muroTab, value: store.tab)
        .animation(.easeInOut(duration: 0.18), value: store.previewItem?.id)
        .alert("Couldn’t set wallpaper", isPresented: Binding(
            get: { store.applyError != nil },
            set: { if !$0 { store.applyError = nil } }
        )) {
            Button("OK", role: .cancel) { store.applyError = nil }
        } message: {
            Text(store.applyError ?? "Unknown error")
        }
        .alert("Couldn’t import video", isPresented: Binding(
            get: { store.importError != nil },
            set: { if !$0 { store.importError = nil } }
        )) {
            Button("OK", role: .cancel) { store.importError = nil }
        } message: {
            Text(store.importError ?? "Unknown error")
        }
        .sheet(item: $store.pendingDelete) { request in
            ConfirmDeleteView(request: request)
                .environmentObject(store)
        }
        .sheet(isPresented: $store.whatsNewOpen) {
            WhatsNewView()
                .environmentObject(store)
        }
        // The lock screen is set, macOS just has not noticed. A dead-end
        // error here is what people reported; this says what finishes it and
        // offers the button that gets them there.
        .alert("One more step", isPresented: $store.lockScreenNeedsSystemSettings) {
            Button("Open System Settings") {
                store.lockScreenNeedsSystemSettings = false
                openWallpaperSettings()
            }
            Button("Later", role: .cancel) { store.lockScreenNeedsSystemSettings = false }
        } message: {
            Text("Muro set your lock screen wallpaper but macOS has not picked it up yet. Open System Settings, go to Wallpaper, and choose Muro to finish it.")
        }
        // A damaged library.json stops every edit, because Muro will not write
        // over a list it could not read. Saying so is the difference between
        // an app protecting the user's library and an app that has silently
        // stopped responding.
        .alert("Muro cannot read your wallpaper list", isPresented: $store.libraryUnreadable) {
            Button("Show the File") {
                store.libraryUnreadable = false
                NSWorkspace.shared.activateFileViewerSelecting([
                    LibraryManifest.manifestURL(root: store.root)
                ])
            }
            Button("Later", role: .cancel) { store.libraryUnreadable = false }
        } message: {
            Text("Your wallpapers are safe on disk, and Muro has stopped rather than overwrite the list with an empty one. Liking, importing and downloading will not work until library.json is repaired or moved out of Muro's folder.")
        }
        .alert("Playlist stopped", isPresented: Binding(
            get: { store.deleteNotice != nil },
            set: { if !$0 { store.deleteNotice = nil } }
        )) {
            Button("OK", role: .cancel) { store.deleteNotice = nil }
        } message: {
            Text(store.deleteNotice ?? "")
        }
        // Every dropdown and right-click menu in the main window draws here
        // rather than in a popover of its own.
        .menuHost()
    }
}

/// System Settings, Wallpaper pane. The lock screen's manual fallback: the
/// user picking Muro there is the same acquire WallpaperAgent skipped.
@MainActor
func openWallpaperSettings() {
    let pane = "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
    guard let url = URL(string: pane) else { return }
    NSWorkspace.shared.open(url)
}

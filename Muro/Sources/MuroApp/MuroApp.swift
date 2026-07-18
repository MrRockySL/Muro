import SwiftUI
import AppKit
import MuroKit

/// The Muro app: gallery window + settings + menu bar, with the wallpaper
/// engine embedded (one process, one config, instant hot-reload).
final class MuroAppDelegate: NSObject, NSApplicationDelegate {
    let engine = EngineController()
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showDock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        engine.start()
        statusBar = StatusBarController(store: AppStore.shared)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keep playing wallpapers from the menu bar
    }
}

@main
struct MuroApp: App {
    @NSApplicationDelegateAdaptor(MuroAppDelegate.self) var delegate
    @StateObject private var store = AppStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Muro", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
                .onAppear {
                    SettingsWindowOpener.shared.open = { openWindow(id: "settings") }
                }
        }
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.hiddenTitleBar)

        Window("Muro Settings", id: "settings") {
            SettingsView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
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

            // Small directional slide + fade when switching pages. The
            // per-tab .id makes SwiftUI treat each page as insert/remove so
            // the transition actually fires.
            Group {
                switch store.tab {
                case .home: HomeView()
                case .explore: ExploreView()
                case .library: LibraryView()
                }
            }
            .id(store.tab)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 26 * store.tabShift)),
                removal: .opacity.combined(with: .offset(x: -26 * store.tabShift))
            ))

            TopBar()

            if let preview = store.previewItem {
                PreviewView(itemID: preview.id)
                    .zIndex(10)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: store.tab)
        .animation(.easeInOut(duration: 0.18), value: store.previewItem?.id)
    }
}

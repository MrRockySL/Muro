import AppKit
import MuroKit
import os

/// muro:// links, so another app or a script can change the live wallpaper
/// without opening Muro's window.
///
///     muro://set?id=<wallpaper id>                      every display
///     muro://set?id=<wallpaper id>&display=<UUID>       one display
///     muro://set?id=…&surface=desktop|lockscreen|screensaver|all
///     muro://pause
///     muro://resume
///
/// `open -g` keeps Muro in the background.
///
/// Any web page can open one of these, and the browser's "Open Muro?" is one
/// click, so a link is held to what is safe from a page:
///
/// - `set` takes a live wallpaper that is already in the Library and a
///   display that is connected, and is ignored otherwise (see `MuroLink`).
///   It never starts a download.
/// - Links are carried out one at a time, in the order they came, and only
///   so many may wait (see `MuroLinkQueue`).
/// - A link never opens a window or shows anything. One that is ignored, or
///   that fails, is written to the log with the reason.
/// - `linksOff` in Muro's defaults turns every link off.
@MainActor
enum RemoteLinks {
    private static let log = Logger(subsystem: "com.mrrockysl.muro", category: "links")

    /// Sixteen is far more than a script or a Shortcut sends at once, and
    /// few enough that a page cannot keep Muro busy for long.
    private static let queue = MuroLinkQueue<URL>(limit: 16) { url in
        await carryOut(url)
    }

    /// Called from `applicationWillFinishLaunching`. A link that opens Muro
    /// from quit is delivered before `applicationDidFinishLaunching`, so a
    /// handler installed any later never sees it. Installing it here also
    /// replaces SwiftUI's own handler, which would open a window for every
    /// link.
    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            Handler.shared,
            andSelector: #selector(Handler.handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Called from `applicationDidFinishLaunching` once the engine and the
    /// store are up. Links that came while Muro was starting have waited in
    /// the line, and are carried out now in the order they came.
    static func launched() {
        hasLaunched = true
        queue.start()
    }

    /// False while Muro is starting. The launch applies the Dock setting
    /// itself then, and nothing here may do it first.
    private static var hasLaunched = false

    /// macOS gives a running Muro its Dock icon back the moment it hands it
    /// a link, also with Show Dock Icon off. Opening Muro again from
    /// Spotlight does the same, and there Muro becoming active puts the
    /// setting back. A link in the background never makes Muro active, so
    /// the icon stayed until Muro was quit.
    ///
    /// Leaving the Dock takes the front away from Muro as well. A link must
    /// not put the gallery behind another app while somebody is using it, so
    /// Muro takes the front back when it had it, the way the Show Dock Icon
    /// switch does. It never takes a front it did not have.
    private static func stayOutOfTheDock() {
        guard hasLaunched else { return }
        let before = NSApp.activationPolicy()
        let wasActive = NSApp.isActive
        MuroAppDelegate.applyActivationPolicy()
        if wasActive, NSApp.activationPolicy() != before {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    final class Handler: NSObject {
        static let shared = Handler()

        @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
            MainActor.assumeIsolated { RemoteLinks.take(text) }
        }
    }

    /// `defaults write com.mrrockysl.muro linksOff -bool true` turns links
    /// off, for somebody who wants nothing outside Muro to change it.
    private static var off: Bool { UserDefaults.standard.bool(forKey: "linksOff") }

    /// A link that has just arrived. Nothing is done with it here: it joins
    /// the line.
    private static func take(_ text: String) {
        // First, and for every link: one that is ignored has brought the
        // Dock icon back too.
        stayOutOfTheDock()
        guard !off else {
            log.info("ignored a link: links are turned off")
            return
        }
        // Before it is read or kept. A real link is about a hundred
        // characters.
        guard text.utf8.count <= MuroLink.longestLink else {
            log.error("ignored a link of \(text.utf8.count) characters: too long")
            return
        }
        guard let url = URL(string: text) else {
            log.error("ignored \(text, privacy: .public): not a link")
            return
        }
        switch queue.add(url) {
        case .taken:
            break
        case .alreadyWaiting:
            log.info("skipped \(text, privacy: .public): the same link is already waiting")
        case .full:
            log.error("ignored \(text, privacy: .public): too many links are waiting")
        }
    }

    /// Carries one link out, and returns when it is done.
    private static func carryOut(_ url: URL) async {
        let link = url.absoluteString
        let store = AppStore.shared
        // Read now, not when the link came: a display can be unplugged while
        // a link waits.
        let connected = Set(store.displays.map(\.id))
        switch MuroLink.read(url, connectedDisplays: connected) {
        case .failure(let refusal):
            log.error("ignored \(link, privacy: .public): \(String(describing: refusal), privacy: .public)")
        case .success(.pause):
            store.setPaused(true)
        case .success(.resume):
            store.setPaused(false)
        case .success(.set(let id, let display, let surface)):
            guard let item = store.item(id: id) else {
                log.error("ignored \(link, privacy: .public): no live wallpaper with that id")
                return
            }
            // Apple's still pictures, the wallpapers macOS draws and screen
            // savers are shown by macOS, not played by Muro. Setting one
            // means writing macOS's own wallpaper settings, and a still
            // picture may have to be fetched from Apple first.
            guard !AppleAerials.isMacOSOnly(item.id) else {
                log.error("ignored \(link, privacy: .public): macOS shows this one itself, a link cannot set it")
                return
            }
            guard item.isDownloaded else {
                log.error("ignored \(link, privacy: .public): not in the Library")
                return
            }
            let problems = await store.setWallpaper(
                fromLink: item,
                target: display.map { .display($0) } ?? .all,
                surface: surface.map(applySurface)
            )
            for problem in problems {
                log.error("could not finish \(link, privacy: .public): \(problem, privacy: .public)")
            }
        }
    }

    private static func applySurface(_ surface: MuroLink.Surface) -> ApplySurface {
        switch surface {
        case .all: .all
        case .desktop: .desktop
        case .lockscreen: .lockscreen
        case .screensaver: .screensaver
        }
    }
}

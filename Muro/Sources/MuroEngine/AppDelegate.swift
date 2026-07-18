import AppKit
import MuroKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [WallpaperWindowController] = []
    private var engine: EngineController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments

        // No arguments → library mode: play whatever config.json assigns,
        // per display, hot-reloading on changes. This is the real engine.
        guard args.count > 1 else {
            engine = EngineController()
            engine?.start()
            EngineLog.log("engine running in library mode")
            return
        }

        // With a path argument → single-file test mode (Phase 0 behavior).
        let videoURL = URL(fileURLWithPath: args[1])
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            fputs("muro-engine: no such file: \(videoURL.path)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        guard let screen = NSScreen.main else {
            fputs("muro-engine: no screen available\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let controller = WallpaperWindowController(screen: screen, videoURL: videoURL)
        controller.start()
        controllers.append(controller)

        EngineLog.log("engine running — video: \(videoURL.lastPathComponent), screen: \(screen.localizedName) \(Int(screen.frame.width))x\(Int(screen.frame.height))")
    }
}

import AppKit
import MuroKit
import os

/// The Download Folder row in Settings: where the wallpaper videos live, and
/// moving them somewhere else or back. The move itself is `DownloadFolder`,
/// which keeps every video safe until its copy is checked.
@MainActor
final class DownloadFolderController: ObservableObject {
    static let shared = DownloadFolderController()

    @Published private(set) var location: DownloadFolder.Location
    /// Videos done and in all, while a move runs.
    @Published private(set) var moving: (done: Int, total: Int)?
    /// How much of the move's bytes are copied, 0 to 1, while it runs.
    @Published private(set) var movedFraction: Double?
    /// Set by Cancel, read by the move on its own thread.
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)
    @Published private(set) var cancelling = false
    @Published var message: String?

    private let root = LibraryManifest.defaultRoot()
    private var observers: [NSObjectProtocol] = []

    private init() {
        location = DownloadFolder.location(root: root)
        // A drive coming or going changes what the row should say.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let controller = DownloadFolderController.shared
                    controller.refresh()
                    // The hero and the previews decide from the store whether
                    // a video is there to play, so they look again too.
                    if controller.isCustom { AppStore.shared.objectWillChange.send() }
                }
            })
        }
    }

    var isCustom: Bool { location != .builtIn }

    var subtitle: String {
        if cancelling { return "Cancelling…" }
        if let moving {
            let percent = movedFraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            return moving.total == 0
                ? "Moving your wallpapers…\(percent)"
                : "Moving \(min(moving.done + 1, moving.total)) of \(moving.total) wallpapers…\(percent)"
        }
        switch location {
        case .builtIn:
            return "On this Mac, in Muro's own folder"
        case .custom(let url):
            return Self.displayPath(url)
        case .unavailable(let url):
            return "\(DownloadFolder.placeName(url)) is not connected"
        }
    }

    func refresh() {
        location = DownloadFolder.location(root: root)
    }

    /// The Mac's own folder picker, then the move.
    func choose() {
        guard moving == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Muro moves your downloaded wallpapers into a folder called \(DownloadFolder.folderName) here. New downloads go there too."
        if case .custom(let url) = location {
            panel.directoryURL = url.deletingLastPathComponent()
        }
        NSApp.activate(ignoringOtherApps: true)
        if let settings = window(titled: MuroWindow.settings), settings.isVisible {
            panel.beginSheetModal(for: settings) { response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { self.move(into: url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            move(into: url)
        }
    }

    /// Back into the library on this Mac.
    func reset() {
        guard moving == nil else { return }
        move(into: nil)
    }

    /// Stops a move. Nothing has changed until the last video is copied, so
    /// the videos simply stay where they were.
    func cancel() {
        guard moving != nil, !cancelling else { return }
        cancelling = true
        stopRequested.withLock { $0 = true }
    }

    private func move(into picked: URL?) {
        moving = (0, 0)
        movedFraction = nil
        cancelling = false
        stopRequested.withLock { $0 = false }
        let root = self.root
        let stop = stopRequested
        Task.detached(priority: .userInitiated) {
            var lastShown = -1.0
            let failure: String? = {
                do {
                    try DownloadFolder.move(
                        root: root,
                        into: picked,
                        progress: { done, total in
                            Task { @MainActor in
                                // A step that arrives after the move has
                                // finished must not bring the progress back.
                                let controller = DownloadFolderController.shared
                                if controller.moving != nil { controller.moving = (done, total) }
                            }
                        },
                        bytes: { copied, total in
                            guard total > 0 else { return }
                            let fraction = Double(copied) / Double(total)
                            guard fraction - lastShown >= 0.01 || fraction >= 1 else { return }
                            lastShown = fraction
                            Task { @MainActor in
                                let controller = DownloadFolderController.shared
                                if controller.moving != nil { controller.movedFraction = fraction }
                            }
                        },
                        isCancelled: { stop.withLock { $0 } }
                    )
                    return nil
                } catch DownloadFolder.MoveError.cancelled {
                    // Asked for, so not an alert.
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }()
            await MainActor.run {
                let controller = DownloadFolderController.shared
                controller.moving = nil
                controller.movedFraction = nil
                controller.cancelling = false
                controller.refresh()
                controller.message = failure
                AppStore.shared.recomputeSize()
            }
        }
    }

    /// Where the folder is, the way Finder would name it: the drive first for
    /// a folder on one, Home for one under the home folder.
    static func displayPath(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            return parts.dropFirst(2).joined(separator: " › ")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        if parts.starts(with: home) {
            return (["Home"] + parts.dropFirst(home.count)).joined(separator: " › ")
        }
        let disk = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?
            .volumeLocalizedName ?? "Mac"
        return ([disk] + parts.dropFirst()).joined(separator: " › ")
    }
}

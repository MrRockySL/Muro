import AppKit
import Darwin
import ExtensionFoundation
import Foundation

let extensionDomain = "com.mrrockysl.muro.wallpaper-extension"

// MARK: - Logging
//
// The log earned its place while the lock screen was being solved, and it is
// still the only window into what WallpaperAgent asks this extension to do.
// What it must not do is grow forever on a stranger's Mac. So: routine chatter
// is off unless someone turns it on, what remains is capped, and one previous
// file is kept so a bug report still has history either side of a failure.

/// Set `MURO_WALLPAPER_DEBUG` in the environment to record the routine
/// chatter as well. Off, only failures and the acquire/render milestones that
/// matter to a bug report are written.
private let verboseLogging = ProcessInfo.processInfo.environment["MURO_WALLPAPER_DEBUG"] != nil

/// Built once. It used to be constructed on every single log line, which is
/// an expensive object to make for the sake of one timestamp.
///
/// A date formatter is not thread safe, and this extension logs from the
/// renderer, XPC and notification callbacks alike, so it is only ever touched
/// inside `logQueue` below. That serialisation is what makes the unchecked
/// annotation true.
nonisolated(unsafe) private let logTimestamps = ISO8601DateFormatter()

/// Serialises writes, since renderer, XPC and notification callbacks all log
/// from different queues.
private let logQueue = DispatchQueue(label: "com.mrrockysl.muro.wallpaper-log")

private let maxLogBytes = 256 * 1024

private var logURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
        .appendingPathComponent("extension.log")
}

/// Routine chatter: connections, notifications, surface bookkeeping. Recorded
/// only when `MURO_WALLPAPER_DEBUG` is set, so a normal install writes almost
/// nothing. The message is only built if it will be used.
func extensionTrace(_ message: @autoclosure () -> String) {
    guard verboseLogging else { return }
    extensionLog(message())
}

/// Failures, and the few milestones worth having in every bug report.
func extensionLog(_ message: String) {
    let now = Date()
    logQueue.sync {
        let line = "[\(logTimestamps.string(from: now))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        appendToLog(data)
    }
}

private func appendToLog(_ data: Data) {
    let manager = FileManager.default
    let url = logURL

    // Roll rather than truncate, so the lines just before a failure are not
    // the ones thrown away.
    if let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int,
       size + data.count > maxLogBytes {
        let previous = url.deletingLastPathComponent()
            .appendingPathComponent("extension.previous.log")
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: url, to: previous)
    }

    guard manager.fileExists(atPath: url.path) else {
        try? data.write(to: url, options: .atomic)
        return
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

@objc(MuroWallpaperExtensionProxyXPCProtocol)
private protocol WallpaperExtensionProxyXPCProtocol {
    @objc(pingWithId:)
    func ping(withId id: Any?)

    @objc(updateSettingsViewModels:reply:)
    func updateSettingsViewModels(_ models: Any?, reply: @escaping (NSError?) -> Void)

    @objc(requestReadOnlyAccessTo:reply:)
    func requestReadOnlyAccess(to url: Any?, reply: @escaping (Any?) -> Void)

    @objc(invalidateSnapshotsWithReply:)
    func invalidateSnapshots(reply: @escaping (NSError?) -> Void)
}

@objc(MuroWallpaperExtensionXPCProtocol)
private protocol WallpaperExtensionXPCProtocol {
    @objc(acquireWithId:request:reply:)
    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, NSError?) -> Void)

    @objc(updateWithId:request:reply:)
    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable (NSError?) -> Void)

    @objc(invalidateWithId:reply:)
    func invalidate(withId id: Any?, reply: @escaping @Sendable (NSError?) -> Void)

    @objc(snapshotWithId:reply:)
    func snapshot(withId id: Any?, reply: @escaping @Sendable (Any?, NSError?) -> Void)

    @objc(provideSettingsViewModelsWithContentTypes:reply:)
    func provideSettingsViewModels(
        withContentTypes types: Any?,
        reply: @escaping @Sendable (Any?, NSError?) -> Void
    )

    @objc(selectedChoicesDidChangeFor:reply:)
    func selectedChoicesDidChange(for id: Any?, reply: @escaping @Sendable (NSError?) -> Void)

    @objc(isChoiceDownloadedWith:reply:)
    func isChoiceDownloaded(with choiceID: Any?, reply: @escaping @Sendable (Bool, NSError?) -> Void)

    @objc(handleNotificationWithNamed:reply:)
    func handleNotification(withNamed name: Any?, reply: @escaping @Sendable (NSError?) -> Void)
}

private final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    private static let snapshotQueue = DispatchQueue(
        label: "com.mrrockysl.muro.wallpaper-snapshot"
    )
    private var acquiredAsPreview = false

    func acquire(
        withId id: Any?,
        request: Any?,
        reply: @escaping @Sendable (Any?, NSError?) -> Void
    ) {
        nonisolated(unsafe) let unsafeID = id
        nonisolated(unsafe) let unsafeRequest = request
        RendererState.lifecycleQueue.async {
            self.acquireBody(id: unsafeID, request: unsafeRequest, reply: reply)
        }
    }

    private func acquireBody(
        id: Any?,
        request: Any?,
        reply: @escaping @Sendable (Any?, NSError?) -> Void
    ) {
        let info = inspectWallpaperRequest(request)
        acquiredAsPreview = info.isPreview
        RendererState.shared.noteDestination(info)
        let key = RendererState.shared.surfaceKey(id: id, request: info)

        // Resolved before anything is built, because it is also the answer to
        // "why was the desktop black". A surface with no picture has only the
        // video to show, and a video that is created paused may composite no
        // frame at all, which is a black rectangle where the desktop was.
        //
        // Nothing is resolved for a System Settings preview: that is showing
        // the lock wallpaper on purpose, and the desktop's own picture there
        // would be the wrong one.
        //
        // The fallback is a frame of this wallpaper rather than its thumbnail,
        // because a thumbnail can be missing. See WallpaperFrame.
        let fallbackStill = info.isPreview ? nil : WallpaperFrame.image(for: info.choiceID)
        // The screen saver is not the desktop and must never be handed the
        // desktop's picture: what belongs behind a screen saver that fails to
        // decode is a frame of the screen saver. It is only ever a backstop,
        // because this surface plays.
        let desktopStill = info.isPreview
            ? nil
            : (info.isScreenSaver ? fallbackStill : (DesktopStill.current() ?? fallbackStill))

        // The mode is logged because it is what decides still against video,
        // and a lock screen showing the wrong one of the two is answered by
        // this line and nothing else. `still` is logged for the same reason on
        // the desktop side: a black desktop is either "no" here, or something
        // outside this process.
        extensionLog(
            "acquire \(info.destinationSize.width)x\(info.destinationSize.height) "
                + "display=\(info.displayID.map(String.init) ?? "default") "
                + "preview=\(info.isPreview) choice=\(info.choiceID ?? "none") "
                + "mode=\(info.presentationMode ?? "unset") "
                + "activity=\(info.activityState ?? "unset") "
                + "screensaver=\(info.isScreenSaver) "
                + "covered=\(ScreenState.isCovered()) "
                + "still=\(info.isPreview ? "n/a" : (desktopStill != nil ? "yes" : "no"))"
        )

        if let existing = RendererState.shared.context(for: key),
           existing.choiceID == info.choiceID,
           let response = createRemoteContextXPC(contextId: existing.context.contextId)
        {
            extensionLog("reusing surface ctx=\(existing.context.contextId)")
            AcquireReceipt.record(
                id: info.choiceID, preview: info.isPreview, ok: true, detail: "reused"
            )
            reply(response, nil)
            return
        }

        let videoURL = info.files.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? stagedVideoURL(for: info.choiceID)
        guard let videoURL else {
            AcquireReceipt.record(
                id: info.choiceID, preview: info.isPreview, ok: false, detail: "not staged"
            )
            reply(nil, extensionError(2, "The selected Muro video is not staged."))
            return
        }

        var options: [String: Any] = [:]
        if let displayID = info.displayID { options["displayId"] = displayID }
        let rawContext: Any? = options.isEmpty
            ? CAContext.remoteContext()
            : CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: options)?.takeUnretainedValue()
        guard let context = rawContext as? CAContext, context.contextId != 0 else {
            AcquireReceipt.record(
                id: info.choiceID, preview: info.isPreview, ok: false, detail: "no context"
            )
            reply(nil, extensionError(3, "Could not create the remote wallpaper context."))
            return
        }

        extensionLog("built surface ctx=\(context.contextId)")

        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: info.destinationSize)
        rootLayer.contentsScale = info.scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill
        // Underneath the video, on the context's own layer, and set before the
        // context is handed over, so the first thing macOS composites already
        // carries the desktop's picture. It used to be a sublayer added after
        // the handover: one more thing that had to arrive before the desktop
        // was anything at all.
        rootLayer.contents = desktopStill
        rootLayer.isOpaque = desktopStill != nil
        context.layer = rootLayer
        CATransaction.flush()

        guard let response = createRemoteContextXPC(contextId: context.contextId) else {
            AcquireReceipt.record(
                id: info.choiceID, preview: info.isPreview, ok: false, detail: "no remote context"
            )
            reply(nil, extensionError(4, "Could not wrap the remote wallpaper context."))
            return
        }

        do {
            let renderer = try VideoRenderer.create(rootLayer: rootLayer, videoURL: videoURL)
            let wallpaper = ActiveWallpaper(
                context: context,
                rootLayer: rootLayer,
                renderer: renderer,
                choiceID: info.choiceID,
                // A screen saver keeps the frame it was built with. Restaging
                // the desktop's picture must not reach across onto it.
                drawsStill: !info.isPreview && !info.isScreenSaver,
                isScreenSaverSurface: info.isScreenSaver,
                fallback: fallbackStill
            )
            RendererState.shared.install(wallpaper, for: key)
            // A surface is not trusted to have come up right. See
            // RendererState.scheduleStillReassert for what was measured.
            if !info.isPreview { RendererState.shared.scheduleStillReassert() }
            let responseBox = SendableBox(value: response)
            let contextID = context.contextId
            let choiceID = info.choiceID
            let isPreview = info.isPreview
            // The request's own mode, not whatever this process was last told
            // about some other surface. A surface created for a locked screen
            // has to start playing, and after a restart nothing has said the
            // screen is locked. See RendererState.shouldPlayNow.
            if !info.isPreview {
                RendererState.shared.adopt(
                    mode: info.presentationMode, activity: info.activityState
                )
            }
            let shouldPlay = info.isScreenSaver
                ? RendererState.shared.shouldScreenSaverPlay()
                : RendererState.shared.shouldPlayNow(
                    mode: info.presentationMode,
                    activity: info.activityState,
                    isPreview: info.isPreview
                )
            // Read before the reply closure, which is Sendable and cannot reach
            // into a layer.
            let showingStill = !shouldPlay && desktopStill != nil
            wallpaper.setShowingStill(!shouldPlay)
            renderer.start(initiallyPaused: !shouldPlay) { composited in
                extensionTrace("remote context \(contextID) ready")
                // A video that drew nothing must not be the layer on screen,
                // whatever the mode says. The still is the only thing left
                // that can be a wallpaper rather than a black rectangle.
                if !composited { wallpaper.setShowingStill(true) }
                // Recorded whether or not a frame landed. A paused start still
                // composites one, so this stays true for the desktop surface,
                // where the extension is deliberately frozen.
                AcquireReceipt.record(
                    id: choiceID,
                    preview: isPreview,
                    // A still covering a video that never composited is a
                    // desktop showing the right picture, not a failed apply.
                    ok: composited || showingStill,
                    detail: composited ? "rendering" : "still only"
                )
                reply(responseBox.value, nil)
            }
        } catch {
            extensionLog("renderer creation failed: \(error)")
            AcquireReceipt.record(
                id: info.choiceID, preview: info.isPreview, ok: false,
                detail: "renderer failed"
            )
            reply(nil, extensionError(5, error.localizedDescription))
        }
    }

    func update(
        withId id: Any?,
        request: Any?,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        guard !acquiredAsPreview else { reply(nil); return }
        let mode = request.flatMap { mirrorProperty("presentationMode", in: $0) }
            .map(wallpaperEnumCase) ?? "default"
        let activity = request.flatMap { mirrorProperty("activityState", in: $0) }
            .map(wallpaperEnumCase) ?? "active"
        RendererState.shared.setPresentation(mode: mode, activity: activity)
        reply(nil)
    }

    func invalidate(withId id: Any?, reply: @escaping @Sendable (NSError?) -> Void) {
        if let uuid = extractWallpaperUUID(from: id) {
            RendererState.shared.scheduleRemoval(identifier: uuid.uuidString)
            extensionTrace("scheduled surface release after invalidate")
        }
        reply(nil)
    }

    /// macOS asking what this wallpaper looks like as a picture. It exports
    /// the answer to the Preboot volume, and that is what the login screen
    /// shows while the Mac is still asking for a password, before any of this
    /// code can be running. Answering nothing left the login screen on a
    /// desktop picture from months ago. See `WallpaperSnapshot`.
    func snapshot(
        withId id: Any?,
        reply: @escaping @Sendable (Any?, NSError?) -> Void
    ) {
        nonisolated(unsafe) let unsafeID = id
        // Its own queue, not the lifecycle one: the first snapshot decodes a
        // frame, and queueing that behind an acquire would hold up the
        // wallpaper itself.
        Self.snapshotQueue.async {
            let identifier = extractWallpaperUUID(from: unsafeID)?.uuidString
            let choiceID = RendererState.shared.choiceID(forIdentifier: identifier)
                ?? soleStagedChoiceID()
            guard let snapshot = WallpaperSnapshot.make(
                choiceID: choiceID,
                size: RendererState.shared.snapshotSize
            ) else {
                reply(nil, self.extensionError(6, "No Muro wallpaper to snapshot."))
                return
            }
            extensionTrace("snapshot provided for \(choiceID ?? "none")")
            reply(snapshot, nil)
        }
    }

    func provideSettingsViewModels(
        withContentTypes types: Any?,
        reply: @escaping @Sendable (Any?, NSError?) -> Void
    ) {
        extensionTrace("settings request received through ExtensionFoundation")
        if let models = makeSettingsResponse() {
            reply(models, nil)
        } else {
            reply(nil, NSError(
                domain: extensionDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Muro choices could not be built."]
            ))
        }
    }

    func selectedChoicesDidChange(
        for id: Any?,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        extensionTrace("selected choices changed")
        reply(nil)
    }

    func isChoiceDownloaded(
        with choiceID: Any?,
        reply: @escaping @Sendable (Bool, NSError?) -> Void
    ) {
        reply(true, nil)
    }

    func handleNotification(
        withNamed name: Any?,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        extensionTrace("notification: \(String(describing: name))")
        reply(nil)
    }

    private func extensionError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: extensionDomain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct MuroWallpaperConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        extensionTrace("XPC connection from PID \(connection.processIdentifier)")

        let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
        let runtimeNames = [
            "WallpaperIDXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperContentTypeSetXPC",
            "WallpaperSettingsViewModelsXPC",
        ]
        let allowed = NSMutableSet(array: [
            NSString.self, NSNumber.self, NSData.self, NSArray.self,
            NSDictionary.self, NSURL.self, NSError.self,
        ])
        for name in runtimeNames {
            if let cls = objc_getClass(name) { allowed.add(cls) }
        }
        let classes = allowed as! Set<AnyHashable>

        let acquire = #selector(WallpaperXPCHandler.acquire(withId:request:reply:))
        exported.setClasses(classes, for: acquire, argumentIndex: 0, ofReply: false)
        exported.setClasses(classes, for: acquire, argumentIndex: 1, ofReply: false)
        exported.setClasses(classes, for: acquire, argumentIndex: 0, ofReply: true)

        let update = #selector(WallpaperXPCHandler.update(withId:request:reply:))
        exported.setClasses(classes, for: update, argumentIndex: 0, ofReply: false)
        exported.setClasses(classes, for: update, argumentIndex: 1, ofReply: false)

        let invalidate = #selector(WallpaperXPCHandler.invalidate(withId:reply:))
        exported.setClasses(classes, for: invalidate, argumentIndex: 0, ofReply: false)

        let snapshot = #selector(WallpaperXPCHandler.snapshot(withId:reply:))
        exported.setClasses(classes, for: snapshot, argumentIndex: 0, ofReply: false)
        exported.setClasses(classes, for: snapshot, argumentIndex: 0, ofReply: true)

        let settings = #selector(
            WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)
        )
        exported.setClasses(classes, for: settings, argumentIndex: 0, ofReply: false)
        exported.setClasses(classes, for: settings, argumentIndex: 0, ofReply: true)

        let selected = #selector(WallpaperXPCHandler.selectedChoicesDidChange(for:reply:))
        exported.setClasses(classes, for: selected, argumentIndex: 0, ofReply: false)

        let downloaded = #selector(WallpaperXPCHandler.isChoiceDownloaded(with:reply:))
        exported.setClasses(classes, for: downloaded, argumentIndex: 0, ofReply: false)

        let notification = #selector(WallpaperXPCHandler.handleNotification(withNamed:reply:))
        exported.setClasses(classes, for: notification, argumentIndex: 0, ofReply: false)

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(
            with: WallpaperExtensionProxyXPCProtocol.self
        )
        connection.exportedObject = WallpaperXPCHandler()
        connection.invalidationHandler = {
            extensionTrace("XPC connection invalidated")
        }
        connection.interruptionHandler = {
            extensionTrace("XPC connection interrupted")
        }
        connection.resume()
        extensionTrace("XPC accepted with wallpaper protocol")
        return true
    }
}

@main
private final class MuroWallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()
        _ = ExtensionPlaybackCoordinator.shared
        let path = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if dlopen(path, RTLD_LAZY) != nil {
            extensionTrace("WallpaperExtensionKit loaded at runtime")
        } else {
            extensionLog("WallpaperExtensionKit failed to load")
        }
    }

    var configuration: some AppExtensionConfiguration {
        MuroWallpaperConfiguration()
    }
}

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
        let key = RendererState.shared.surfaceKey(id: id, request: info)
        extensionLog(
            "acquire \(info.destinationSize.width)x\(info.destinationSize.height) "
                + "display=\(info.displayID.map(String.init) ?? "default") "
                + "preview=\(info.isPreview) choice=\(info.choiceID ?? "none")"
        )

        if let existing = RendererState.shared.context(for: key),
           existing.choiceID == info.choiceID,
           let response = createRemoteContextXPC(contextId: existing.context.contextId)
        {
            extensionTrace("reusing remote context \(existing.context.contextId)")
            reply(response, nil)
            return
        }

        let videoURL = info.files.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? stagedVideoURL(for: info.choiceID)
        guard let videoURL else {
            reply(nil, extensionError(2, "The selected Muro video is not staged."))
            return
        }

        var options: [String: Any] = [:]
        if let displayID = info.displayID { options["displayId"] = displayID }
        let rawContext: Any? = options.isEmpty
            ? CAContext.remoteContext()
            : CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: options)?.takeUnretainedValue()
        guard let context = rawContext as? CAContext, context.contextId != 0 else {
            reply(nil, extensionError(3, "Could not create the remote wallpaper context."))
            return
        }

        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: info.destinationSize)
        rootLayer.contentsScale = info.scaleFactor
        rootLayer.contentsGravity = .resizeAspectFill
        context.layer = rootLayer
        CATransaction.flush()

        guard let response = createRemoteContextXPC(contextId: context.contextId) else {
            reply(nil, extensionError(4, "Could not wrap the remote wallpaper context."))
            return
        }

        do {
            let renderer = try VideoRenderer.create(rootLayer: rootLayer, videoURL: videoURL)
            RendererState.shared.install(
                ActiveWallpaper(
                    context: context,
                    rootLayer: rootLayer,
                    renderer: renderer,
                    choiceID: info.choiceID
                ),
                for: key
            )
            let responseBox = SendableBox(value: response)
            let contextID = context.contextId
            renderer.start(initiallyPaused: !RendererState.shared.shouldPlayNow(isPreview: info.isPreview)) {
                extensionTrace("remote context \(contextID) ready")
                reply(responseBox.value, nil)
            }
        } catch {
            extensionLog("renderer creation failed: \(error)")
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

    func snapshot(
        withId id: Any?,
        reply: @escaping @Sendable (Any?, NSError?) -> Void
    ) {
        reply(nil, nil)
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

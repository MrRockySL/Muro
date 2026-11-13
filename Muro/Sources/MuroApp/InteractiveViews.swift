import AppKit
import MuroKit
import SwiftUI
import WebKit

/// How the gallery tells the running page about a click on it. The page takes
/// no clicks of its own (the bar drawn over it has to keep working), so the
/// click is caught in SwiftUI, which knows it landed on the page and not on
/// the bar, and handed over here.
final class InteractivePreviewLink {
    var click: ((Double, Double) -> Void)?
}

/// An interactive wallpaper running in the gallery, on its own page, so it can
/// be tried before it is set (issue #59). The same page the desktop shows,
/// told where the pointer is over it and what the Mac is playing.
struct InteractivePreview: NSViewRepresentable {
    let page: URL
    let link: InteractivePreviewLink

    func makeNSView(context: Context) -> Host {
        let host = Host()
        host.show(page)
        link.click = { [weak host] x, y in host?.click(x: x, y: y) }
        return host
    }

    func updateNSView(_ host: Host, context: Context) {
        host.show(page)
    }

    static func dismantleNSView(_ host: Host, coordinator: ()) {
        host.close()
    }

    final class Host: NSView {
        private var page: InteractivePage?
        private var shown: URL?
        private var monitors: [Any] = []
        private var listening: UUID?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func show(_ url: URL) {
            guard url != shown else { return }
            close()
            shown = url
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            let page = InteractivePage(index: url, frame: bounds)
            page.view.frame = bounds
            page.view.alphaValue = 0
            addSubview(page.view)
            page.onReady = { [weak page] in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    page?.view.animator().alphaValue = 1
                }
            }
            page.onWantsAudio = { [weak self] in self?.updateListening() }
            self.page = page
            page.load()
            watchPointer()
            updatePaused()
        }

        func close() {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            stopListening()
            page?.close()
            page = nil
            shown = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            // A gallery nobody can see runs nothing.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.updatePaused() })
            updatePaused()
        }

        private var isSeen: Bool {
            guard let window else { return false }
            return window.isVisible && window.occlusionState.contains(.visible)
        }

        private func updatePaused() {
            page?.setPaused(!isSeen)
            updateListening()
        }

        private func updateListening() {
            let wanted = page?.wantsAudio == true && isSeen
            if wanted, listening == nil {
                // Heard only if Muro is already listening for a wallpaper on
                // the desktop. Looking at one here never makes macOS ask.
                listening = SystemSound.shared.add(starting: false) { [weak self] bands in
                    self?.page?.audio(bands)
                }
            } else if !wanted {
                stopListening()
            }
        }

        private func stopListening() {
            guard let id = listening else { return }
            listening = nil
            SystemSound.shared.remove(id)
        }

        /// The page takes no clicks of its own, so the bar drawn over it keeps
        /// working. The pointer is read here and told to it instead.
        private func watchPointer() {
            let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
                self?.pointer(event)
                return event
            }) { monitors.append(monitor) }
            window?.acceptsMouseMovedEvents = true
        }

        private func place(_ event: NSEvent) -> (x: Double, y: Double, inside: Bool)? {
            guard let window, event.window === window, bounds.width > 0, bounds.height > 0 else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            return (
                Double(point.x / bounds.width),
                Double(isFlipped ? point.y / bounds.height : 1 - point.y / bounds.height),
                bounds.contains(point)
            )
        }

        private func pointer(_ event: NSEvent) {
            window?.acceptsMouseMovedEvents = true
            guard let place = place(event) else { return }
            page?.mouse(x: place.x, y: place.y, inside: place.inside)
        }

        /// A click on the page, 0 to 1 from its top left.
        func click(x: Double, y: Double) {
            page?.click(x: x, y: y)
        }
    }
}

/// Takes the picture an interactive wallpaper is shown by in the Library: the
/// page itself, run for a moment where nobody sees it.
@MainActor
enum InteractiveSnapshot {
    /// One at a time: each takes a web view and a few seconds.
    private static var last: Task<Bool, Never>?

    static func save(page: URL, to destination: URL) async -> Bool {
        let previous = last
        let task = Task { @MainActor () -> Bool in
            _ = await previous?.value
            return await take(page: page, to: destination)
        }
        last = task
        return await task.value
    }

    private static func take(page url: URL, to destination: URL) async -> Bool {
        let size = NSSize(width: 1280, height: 720)
        // On screen, so the page runs, and see-through, so nobody sees it.
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.level = .screenSaver
        window.alphaValue = 0
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let page = InteractivePage(index: url, frame: NSRect(origin: .zero, size: size))
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(page.view)
        window.contentView = content
        window.orderFrontRegardless()
        defer {
            page.close()
            window.orderOut(nil)
        }

        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            var told = false
            let done = {
                guard !told else { return }
                told = true
                ready.resume()
            }
            page.onReady = done
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: done)
            page.load()
        }
        // Long enough for a page to fade itself in and settle.
        try? await Task.sleep(for: .seconds(2.2))

        let image: NSImage? = await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = 1280
            page.view.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        else { return false }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try jpeg.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

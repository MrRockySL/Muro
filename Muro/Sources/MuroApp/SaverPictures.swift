import Foundation
import MuroKit

/// Pictures for the screen savers a person imports that carry none of their
/// own (owner, 2026-09-30). Most do: XScreenSaver puts one in every screen
/// saver it ships. For the rest, `muro-saver-picture` runs each once, in a
/// process of its own so a broken screen saver cannot take Muro down, and
/// leaves one frame where every card in the Apple section looks for its sharp
/// picture (`AppleAerialInfo.framePath`). One at a time, in the background,
/// about twenty seconds each.
@MainActor
final class SaverPictures {
    static let shared = SaverPictures()

    private var waiting: [AppleAerial] = []
    private var running: String?
    private var landed: (() -> Void)?

    /// The helper sits beside Muro's own executable, in the app and in a
    /// development build alike.
    private var helper: URL? {
        guard let url = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("muro-saver-picture"),
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }

    /// Whether this screen saver still needs a picture of Muro's.
    static func needsPicture(_ saver: AppleAerial) -> Bool {
        guard !AppleAerialInfo.hasFrame(assetID: saver.assetID),
              !FileManager.default.fileExists(atPath: triedFile(saver.assetID).path)
        else { return false }
        return Bundle(url: saver.videoURL)?.urlForImageResource("thumbnail") == nil
    }

    /// Left for one that drew nothing, so it is not tried at every launch.
    static func triedFile(_ assetID: String) -> URL {
        AppleAerialInfo.directory.appendingPathComponent("\(assetID).no-picture")
    }

    /// Every file Muro keeps for a screen saver's picture: the one taken, the
    /// one from its bundle or the drawn stand-in, and the mark above. All go
    /// when it is deleted, or importing it again would bring back the old one.
    static func files(_ assetID: String) -> [URL] {
        let directory = AppleAerialInfo.directory
        return [
            directory.appendingPathComponent("\(assetID).jpg"),
            directory.appendingPathComponent("\(assetID).png"),
            triedFile(assetID),
        ]
    }

    /// Queues the ones that need a picture. `landed` runs after each one
    /// that arrives, so its card can change at once.
    func take(_ savers: [AppleAerial], landed: @escaping () -> Void) {
        self.landed = landed
        for saver in savers where Self.needsPicture(saver)
            && saver.assetID != running
            && !waiting.contains(where: { $0.assetID == saver.assetID }) {
            waiting.append(saver)
        }
        next()
    }

    private func next() {
        guard running == nil, !waiting.isEmpty, let helper else { return }
        let saver = waiting.removeFirst()
        running = saver.assetID
        let output = URL(fileURLWithPath: AppleAerialInfo.framePath(assetID: saver.assetID))
        try? FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = helper
        process.arguments = [saver.videoURL.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let taken = finished.terminationReason == .exit && finished.terminationStatus == 0
            Task { @MainActor in self.done(saver, taken: taken) }
        }
        do {
            try process.run()
        } catch {
            done(saver, taken: false)
            return
        }
        // The helper gives up by itself after 28 seconds; this is for one
        // that cannot even do that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
            if process.isRunning { process.terminate() }
        }
    }

    private func done(_ saver: AppleAerial, taken: Bool) {
        running = nil
        if taken {
            landed?()
        } else {
            FileManager.default.createFile(atPath: Self.triedFile(saver.assetID).path, contents: nil)
        }
        next()
    }
}

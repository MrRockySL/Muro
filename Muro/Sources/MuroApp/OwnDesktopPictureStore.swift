import AppKit
import MuroKit

/// Keeps the person's own desktop picture for each display where Muro is
/// only the lock screen (#58). What it is for is in `OwnDesktopPicture`.
///
/// One record and one copy per display. The record says which file the
/// picture came from, and the copy is what the wallpaper extension draws on
/// the desktop while the Mac is unlocked. A copy has a new name every time it
/// is made: the extension is handed a picture by its path, and the same path
/// twice reads as the same picture.
@MainActor
final class OwnDesktopPictureStore {
    private struct Record: Codable {
        /// The person's file, as macOS named it.
        var source: String
        /// The copy's file name inside `OwnDesktop`.
        var copy: String
    }

    private let root: URL
    private var records: [String: Record] = [:]

    private var directory: URL { root.appendingPathComponent("OwnDesktop", isDirectory: true) }
    private var recordURL: URL { root.appendingPathComponent("own-desktop.json") }

    init(root: URL) {
        self.root = root
        if let data = try? Data(contentsOf: recordURL),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        }
    }

    /// Every display a picture is kept for.
    var displays: Set<String> { Set(records.keys) }

    /// The copy to draw on this display's desktop, when there is one.
    func picture(forDisplay uuid: String) -> URL? {
        guard let record = records[uuid] else { return nil }
        let url = directory.appendingPathComponent(record.copy)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The file this display's picture came from.
    func source(forDisplay uuid: String) -> URL? {
        records[uuid].map { URL(fileURLWithPath: $0.source) }
    }

    /// Keeps `source` as this display's picture, and says whether it could.
    ///
    /// The same file again changes nothing, so asking twice is free. The copy
    /// is made off the main thread: a large photo takes a moment to decode.
    @discardableResult
    func remember(_ source: URL, displayUUID uuid: String, screen: CGSize) async -> Bool {
        if records[uuid]?.source == source.path, picture(forDisplay: uuid) != nil { return true }
        let name = "\(uuid)-\(UUID().uuidString.prefix(8)).jpg"
        let destination = directory.appendingPathComponent(name)
        let made = await Task.detached(priority: .userInitiated) {
            (try? OwnDesktopPicture.makeCopy(of: source, to: destination, screen: screen)) != nil
        }.value
        guard made else { return false }
        let old = records[uuid]?.copy
        records[uuid] = Record(source: source.path, copy: name)
        save()
        if let old, old != name {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
        return true
    }

    /// Drops the pictures kept for these displays.
    func forget(_ uuids: some Sequence<String>) {
        var changed = false
        for uuid in uuids {
            guard let record = records.removeValue(forKey: uuid) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.copy))
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: recordURL, options: .atomic)
    }
}

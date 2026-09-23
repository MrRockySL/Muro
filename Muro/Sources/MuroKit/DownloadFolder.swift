import Foundation

/// Where Muro keeps its wallpaper videos.
///
/// By default they sit in `Masters` inside the library. A person can move them
/// anywhere, an external drive included: Muro makes a folder called "Muro
/// Wallpapers" in the place they pick, moves the videos into it, and turns
/// `Masters` into a link to it. Every path that already reads
/// `<library>/Masters/<id>.mov` keeps working unchanged, the engine, imports,
/// downloads, the lock screen's staging copy and the command line tools, and
/// the link is itself the setting, so there is nothing else to keep in step.
///
/// Only the videos move. library.json, config.json, likes, playlists,
/// thumbnails and previews stay in the library on this Mac, so a drive that is
/// not connected costs its wallpapers until it is back, never the settings.
///
/// A folder Muro did not make is never used. `LibraryWriter.sweepOrphans`
/// deletes files in `Masters` that no wallpaper refers to, so a link to a
/// folder holding anything else would delete that person's files. Muro's own
/// folder carries a hidden marker, and a "Muro Wallpapers" folder without one
/// is refused unless it is empty.
public enum DownloadFolder {
    public static let folderName = "Muro Wallpapers"
    static let markerName = ".muro-wallpapers"

    public enum Location: Equatable {
        /// The library's own `Masters` folder.
        case builtIn
        /// Somewhere else, and there.
        case custom(URL)
        /// Somewhere else, and not there, like a drive that is not connected.
        case unavailable(URL)
    }

    public enum MoveError: LocalizedError, Equatable {
        case notAFolder
        case insideLibrary
        case alreadyThere
        case folderInUse
        case notConnected(String)
        case notEnoughSpace(needed: Int64, available: Int64)
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAFolder:
                return "That is not a folder Muro can use."
            case .insideLibrary:
                return "Pick a folder outside the one Muro uses now."
            case .alreadyThere:
                return "Muro already keeps your wallpapers there."
            case .folderInUse:
                return "A folder called \(DownloadFolder.folderName) is already there and holds other files. Pick another place."
            case .notConnected(let name):
                return "Connect \(name) first. Your wallpapers are on it."
            case .notEnoughSpace(let needed, let available):
                let format = ByteCountFormatter()
                return "There is not enough space there. Your wallpapers need \(format.string(fromByteCount: needed)) and \(format.string(fromByteCount: available)) is free."
            case .copyFailed(let name):
                return "\(name) could not be copied. Nothing was moved."
            }
        }
    }

    public static func mastersURL(root: URL) -> URL {
        root.appendingPathComponent("Masters", isDirectory: true)
    }

    /// Read from the link itself, so every process sees the same answer.
    public static func location(root: URL) -> Location {
        let masters = mastersURL(root: root)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: masters.path)
        else { return .builtIn }
        let url = URL(fileURLWithPath: target, isDirectory: true)
        return isFolder(url) ? .custom(url) : .unavailable(url)
    }

    /// The name a person knows the place by: the drive's name for a folder on
    /// one, otherwise the folder's own name.
    public static func placeName(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return parts[2] }
        return url.deletingLastPathComponent().lastPathComponent
    }

    /// Moves every video into a "Muro Wallpapers" folder inside `picked`, or
    /// back into the library when `picked` is nil.
    ///
    /// Nothing is deleted until every video has a checked copy in its new
    /// place and the link points there. A failure before that removes only
    /// what this move made and leaves everything as it was.
    ///
    /// `progress` is called with the number of videos done and the total.
    public static func move(
        root: URL,
        into picked: URL?,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws {
        let manager = FileManager.default
        let masters = mastersURL(root: root)

        let current = location(root: root)
        let source: URL
        switch current {
        case .builtIn: source = masters
        case .custom(let url): source = url
        case .unavailable(let url): throw MoveError.notConnected(placeName(url))
        }

        let destination: URL
        if let picked {
            guard isFolder(picked) else { throw MoveError.notAFolder }
            guard !isInside(picked, root) else { throw MoveError.insideLibrary }
            destination = picked.appendingPathComponent(folderName, isDirectory: true)
            if case .custom = current, samePlace(destination, source) {
                throw MoveError.alreadyThere
            }
            guard !isInside(destination, source), !isInside(source, destination) else {
                throw MoveError.insideLibrary
            }
            if manager.fileExists(atPath: destination.path) {
                guard isFolder(destination), isOurs(destination) || isEmpty(destination) else {
                    throw MoveError.folderInUse
                }
            }
        } else {
            guard case .custom = current else { return }
            destination = root.appendingPathComponent("Masters.moving-\(UUID().uuidString)", isDirectory: true)
        }

        let videos = files(in: source)
        let total = videos.reduce(Int64(0)) { $0 + $1.size }
        if !sameVolume(source, destination) {
            let free = availableSpace(at: picked ?? root)
            // Room for the videos and a little over, so the move never fills
            // the disk to the last byte.
            let margin: Int64 = 256 * 1024 * 1024
            if free >= 0, free < total + margin {
                throw MoveError.notEnoughSpace(needed: total, available: free)
            }
        }

        let existed = manager.fileExists(atPath: destination.path)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var made: [URL] = []
        do {
            if picked != nil {
                let marker = destination.appendingPathComponent(markerName)
                if !manager.fileExists(atPath: marker.path) {
                    try Data("Muro keeps its wallpaper videos here.\n".utf8).write(to: marker)
                }
            }
            progress(0, videos.count)
            for (index, video) in videos.enumerated() {
                let target = destination.appendingPathComponent(video.url.lastPathComponent)
                if size(of: target) != video.size {
                    try copy(video.url, to: target, size: video.size)
                    made.append(target)
                }
                progress(index + 1, videos.count)
            }

            switch (current, picked) {
            case (.builtIn, .some):
                var aside: URL?
                if manager.fileExists(atPath: masters.path) {
                    let moved = root.appendingPathComponent("Masters.old-\(UUID().uuidString)", isDirectory: true)
                    try manager.moveItem(at: masters, to: moved)
                    aside = moved
                }
                do {
                    try manager.createSymbolicLink(at: masters, withDestinationURL: destination)
                } catch {
                    if let aside { try? manager.moveItem(at: aside, to: masters) }
                    throw error
                }
                if let aside { finishLeaving(aside, for: destination, removeFolder: true) }
            case (.custom, .some):
                // A new link swapped in over the old one in a single step, so
                // there is no moment without a `Masters`.
                let link = root.appendingPathComponent("Masters.link-\(UUID().uuidString)")
                try manager.createSymbolicLink(at: link, withDestinationURL: destination)
                guard rename(link.path, masters.path) == 0 else {
                    let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    try? manager.removeItem(at: link)
                    throw error
                }
                finishLeaving(source, for: destination, removeFolder: isOurs(source))
            case (.custom, .none):
                try manager.removeItem(at: masters)
                do {
                    try manager.moveItem(at: destination, to: masters)
                } catch {
                    try? manager.createSymbolicLink(at: masters, withDestinationURL: source)
                    throw error
                }
                finishLeaving(source, for: masters, removeFolder: isOurs(source))
            default:
                break
            }
        } catch {
            for url in made { try? manager.removeItem(at: url) }
            if !existed { try? manager.removeItem(at: destination) }
            throw error
        }
    }

    // MARK: - Pieces

    /// Clears out the old folder once the new one is in use. A video that
    /// reached the old folder while the rest were copying, a download that
    /// finished then, is carried across rather than lost. A video that cannot
    /// be carried is left where it is, and so is the folder holding it.
    static func finishLeaving(_ old: URL, for new: URL, removeFolder: Bool) {
        let manager = FileManager.default
        for video in files(in: old) {
            let target = new.appendingPathComponent(video.url.lastPathComponent)
            if size(of: target) != video.size {
                guard (try? copy(video.url, to: target, size: video.size)) != nil else { continue }
            }
            try? manager.removeItem(at: video.url)
        }
        for name in (try? manager.contentsOfDirectory(atPath: old.path)) ?? []
            where name.hasSuffix(".partial") {
            try? manager.removeItem(at: old.appendingPathComponent(name))
        }
        guard removeFolder else { return }
        try? manager.removeItem(at: old.appendingPathComponent(markerName))
        if isEmpty(old, countingHidden: true) { try? manager.removeItem(at: old) }
    }

    /// Copied under a hidden name and renamed once the size checks out, so a
    /// copy cut short never sits under a video's real name.
    static func copy(_ file: URL, to target: URL, size expected: Int64) throws {
        let manager = FileManager.default
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).partial")
        try? manager.removeItem(at: partial)
        do {
            try manager.copyItem(at: file, to: partial)
            guard size(of: partial) == expected else {
                throw MoveError.copyFailed(file.lastPathComponent)
            }
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.moveItem(at: partial, to: target)
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    /// The videos in a folder: visible regular files, with their sizes.
    static func files(in folder: URL) -> [(url: URL, size: Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }
            return (url, Int64(values.fileSize ?? 0))
        }
        .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    static func isFolder(_ url: URL) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
    }

    static func isOurs(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(markerName).path)
    }

    static func isEmpty(_ folder: URL, countingHidden: Bool = false) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.allSatisfy { !countingHidden && $0.hasPrefix(".") }
    }

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func samePlace(_ a: URL, _ b: URL) -> Bool {
        canonicalPath(a) == canonicalPath(b)
    }

    /// True when `inner` is `outer` or anywhere under it.
    public static func isInside(_ inner: URL, _ outer: URL) -> Bool {
        let a = canonicalPath(inner), b = canonicalPath(outer)
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// Same disk, so a copy is a clone and needs no free space. Compared on the
    /// nearest folder that exists, since the destination may not yet.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            var probe = url
            while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
                probe = probe.deletingLastPathComponent()
            }
            return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let first = volume(a), let second = volume(b) else { return false }
        return first.isEqual(second)
    }

    /// Free space where the folder will go, or -1 when the disk will not say.
    static func availableSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let plain = values?.volumeAvailableCapacity { return Int64(plain) }
        return -1
    }
}

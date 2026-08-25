import Foundation

/// Serialises every read-modify-write of `library.json`.
///
/// Downloads run in parallel, imports run on their own task, and the app also
/// edits the manifest for likes and removals. Each of those used to load the
/// manifest, change it and save it on its own. Two finishing close together
/// both read the same starting point, so the later save silently dropped the
/// other's work: a downloaded wallpaper could vanish from the library while
/// its files sat on disk.
///
/// A lock rather than an actor, deliberately. The importer is synchronous
/// because it is also the `muro-import` command line tool, while the
/// downloader is async. A lock is the one thing both can share, and the
/// critical section is a small file read followed by a small file write.
public enum LibraryWriter {
    private static let lock = NSLock()

    /// Reads the manifest from disk, applies `change`, and writes it back,
    /// with no other caller able to interleave. Always work from the manifest
    /// handed to the closure, never from a copy read earlier, since that copy
    /// is exactly what goes stale.
    @discardableResult
    public static func update(
        root: URL,
        _ change: (inout LibraryManifest) throws -> Void
    ) throws -> LibraryManifest {
        lock.lock()
        defer { lock.unlock() }
        // The in-process lock cannot see another process, and the app and the
        // command line tools share one library, so a file lock covers the case
        // of `muro-import` running while Muro is open. It is released when the
        // descriptor closes, including on a crash, so it cannot go stale.
        let descriptor = openLockFile(root: root)
        defer {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }

        var manifest = LibraryManifest.load(root: root)
        try change(&manifest)
        try manifest.save(root: root)
        return manifest
    }

    /// Removes wallpapers from the library for good: their entries leave the
    /// manifest, then their files leave the disk. Returns the saved manifest.
    ///
    /// Manifest first, deliberately. If the app dies between the two halves,
    /// this order leaves files that nothing points at, which costs disk space
    /// and is invisible. The other order leaves entries pointing at files
    /// that are gone, which is a broken card in the Library and a wallpaper
    /// that cannot play.
    ///
    /// The files are read from the manifest on disk rather than from the
    /// caller's copy of the entry, so a variant or preview generated since
    /// that copy was made is deleted too instead of being left behind.
    /// Deletes asset files that no manifest entry references, and reports how
    /// many bytes that freed.
    ///
    /// Importing writes the video, thumbnail and preview and appends the
    /// manifest row only at the end, and a download writes its master straight
    /// to its final path. A crash or a quit in between strands files nothing
    /// can reach again: no id anywhere names them, so no delete and no Clear
    /// will ever find them, and they sit there for the life of the library.
    ///
    /// That same ordering is why this cannot simply remove everything
    /// unreferenced. A file with no row yet may be one an import is still
    /// writing, and `muro-import` can be that import, in another process this
    /// one cannot see. A file being written keeps a fresh modification date,
    /// so anything touched within `grace` is spared and only files old enough
    /// to have outlived any plausible transcode are swept.
    ///
    /// Runs inside `update` so it reads the manifest under the same lock every
    /// other writer takes, and cannot race a row being appended.
    @discardableResult
    public static func sweepOrphans(root: URL, grace: TimeInterval = 900) throws -> Int64 {
        // Every file is unreferenced when there is nothing to reference it,
        // so a manifest that failed to open reads exactly like a library
        // holding nothing and this would take all of it. Checked before
        // `update`, which would otherwise write an empty manifest over the
        // unreadable one and destroy the only copy of what was in it. A
        // library with no manifest yet is one import old at most and has
        // nothing worth sweeping.
        guard LibraryManifest.loadIfPresent(root: root) != nil else { return 0 }

        let manager = FileManager.default
        var freed: Int64 = 0
        _ = try update(root: root) { manifest in
            let referenced = Set(manifest.wallpapers.flatMap(\.relativeFiles))
            let cutoff = Date().addingTimeInterval(-grace)
            for folder in ["Masters", "Thumbnails", "Previews"] {
                let directory = root.appendingPathComponent(folder, isDirectory: true)
                guard let names = try? manager.contentsOfDirectory(atPath: directory.path)
                else { continue }
                for name in names where !name.hasPrefix(".") {
                    guard !referenced.contains("\(folder)/\(name)") else { continue }
                    let url = directory.appendingPathComponent(name)
                    let attributes = try? manager.attributesOfItem(atPath: url.path)
                    if let modified = attributes?[.modificationDate] as? Date, modified > cutoff {
                        continue
                    }
                    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                    if (try? manager.removeItem(at: url)) != nil { freed += size }
                }
            }
        }
        return freed
    }

    @discardableResult
    public static func delete(ids: Set<String>, root: URL) throws -> LibraryManifest {
        var doomed: [String] = []
        let manifest = try update(root: root) { manifest in
            doomed = manifest.wallpapers
                .filter { ids.contains($0.id) }
                .flatMap(\.relativeFiles)
            manifest.wallpapers.removeAll { ids.contains($0.id) }
        }
        for relative in doomed {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(relative))
        }
        return manifest
    }

    /// Best effort: if the lock file cannot be opened the update still runs,
    /// protected by the in-process lock alone. Losing cross-process safety is
    /// better than refusing to save the user's library.
    private static func openLockFile(root: URL) -> Int32 {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".library.lock").path
        return open(path, O_CREAT | O_RDWR, 0o644)
    }
}

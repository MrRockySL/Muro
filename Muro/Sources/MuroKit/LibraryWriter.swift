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

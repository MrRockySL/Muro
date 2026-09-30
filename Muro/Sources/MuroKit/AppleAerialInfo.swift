import Foundation

/// What Muro has learned about each of Apple's aerials from Apple's own
/// servers, and the sharp picture it took of each one.
///
/// **Why this exists.** Apple's manifest says almost nothing about a video.
/// There is no size, no length and no resolution in it, and the still macOS
/// keeps beside it is 214 by 130 pixels, which is what made the first version
/// of the gallery look blurry. Measured 2026-09-30 across all 164 on the
/// owner's Mac: sizes run from 37 MB to 1.5 GB (441 MB is typical), lengths
/// from 30 seconds to 7 minutes, and most are 3840 by 2160, not the 4480 by
/// 3088 the first version assumed for every one of them.
///
/// So the real numbers are read once and kept: the size from the length
/// Apple's server reports, the rest from the video's own header, which is
/// read anyway to take the picture. None of it changes for a given video
/// address, so a saved fact is kept until Apple ships a new address.
///
/// Lives in `~/Library/Caches`, because everything here can be fetched again.
/// Nothing is ever uploaded anywhere, and nothing of Apple's is stored but one
/// picture per aerial the user has looked at.
public enum AppleAerialInfo {

    /// The facts about one aerial's video. Every field but the address is
    /// optional, because the size and the rest arrive from two different reads.
    public struct Facts: Codable, Equatable, Sendable {
        /// The video these facts describe. When Apple ships a new address for
        /// the same aerial, the facts are stale and are read again.
        public var video: String
        public var bytes: Int64?
        public var duration: Double?
        public var width: Int?
        public var height: Int?
        public var fps: Double?

        public init(
            video: String, bytes: Int64? = nil, duration: Double? = nil,
            width: Int? = nil, height: Int? = nil, fps: Double? = nil
        ) {
            self.video = video
            self.bytes = bytes
            self.duration = duration
            self.width = width
            self.height = height
            self.fps = fps
        }

        /// This fact sheet with every field `other` knows filled in.
        func merged(with other: Facts) -> Facts {
            guard other.video == video else { return other }
            return Facts(
                video: video,
                bytes: other.bytes ?? bytes,
                duration: other.duration ?? duration,
                width: other.width ?? width,
                height: other.height ?? height,
                fps: other.fps ?? fps
            )
        }
    }

    // MARK: - Where it lives

    /// Overridable so the tests never touch the real cache.
    nonisolated(unsafe) public static var directoryOverride: URL?

    public static var directory: URL {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muro/AppleAerials", isDirectory: true)
    }

    private static var factsURL: URL { directory.appendingPathComponent("facts.json") }

    /// Where the sharp picture of one aerial is kept, whether or not it has
    /// been taken yet. Touches nothing on disk, so it is cheap enough for a
    /// view body.
    public static func framePath(assetID: String) -> String {
        directory.appendingPathComponent("\(assetID).jpg").path
    }

    public static func hasFrame(assetID: String) -> Bool {
        FileManager.default.fileExists(atPath: framePath(assetID: assetID))
    }

    // MARK: - The facts

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: Facts]?

    /// Read from disk once, then kept in memory. The engine asks for these on
    /// every reconcile, so a file read each time would be waste.
    private static func all() -> [String: Facts] {
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: factsURL))
            .flatMap { try? JSONDecoder().decode([String: Facts].self, from: $0) } ?? [:]
        loaded = read
        return read
    }

    /// What is known about this aerial's current video, or nil when nothing
    /// is, or when what is known describes an older video.
    public static func facts(assetID: String, video: URL) -> Facts? {
        lock.lock()
        defer { lock.unlock() }
        guard let facts = all()[assetID], facts.video == video.absoluteString else { return nil }
        return facts
    }

    /// Adds what was just learned to what was known, and saves it.
    ///
    /// The write happens under the lock, so two reads finishing together can
    /// never save their files in the wrong order and lose the newer one.
    public static func record(_ learned: [String: Facts]) {
        guard !learned.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var facts = all()
        for (assetID, new) in learned {
            facts[assetID] = facts[assetID].map { $0.merged(with: new) } ?? new
        }
        loaded = facts
        guard let data = try? JSONEncoder().encode(facts) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: factsURL, options: .atomic)
    }

    public static func record(_ facts: Facts, assetID: String) {
        record([assetID: facts])
    }

    // MARK: - Space

    /// Everything kept here, for the Storage row's Clear.
    public static func sizeOnDisk() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Forgets everything. The gallery shows Apple's own stills again until
    /// the sharp ones are taken again.
    public static func clear() {
        lock.lock()
        loaded = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }
}

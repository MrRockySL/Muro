import Foundation

/// Disk cache for the streamed p720 detail-view previews (~1 MB each),
/// LRU-capped at 200 MB. Lives in ~/Library/Caches — it is re-downloadable
/// data, so it must not sit in the App Support library where it would count
/// toward the library size and survive "Clear cache".
///
/// A preview is fetched whole before playing (they are tiny; a full download
/// is simpler and loops more reliably than progressive streaming, and the
/// faststart layout still lets a future streaming player reuse the same
/// files). Contents at a given id never change, so a cache hit is always
/// valid — no expiry, only LRU eviction.
enum PreviewCache {
    static let capBytes: Int64 = 200 * 1024 * 1024

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muro/Previews", isDirectory: true)
    }

    private static func fileURL(id: String) -> URL {
        directory.appendingPathComponent("\(id)-p720.mov")
    }

    /// Cache hit, touched so LRU eviction sees it as fresh.
    static func cachedURL(id: String) -> URL? {
        let url = fileURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
        return url
    }

    /// Returns a local URL for the preview, downloading it on a miss.
    static func fetch(id: String, from remote: URL) async throws -> URL {
        if let hit = cachedURL(id: id) { return hit }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (temp, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.badServerResponse)
        }
        let destination = fileURL(id: id)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        prune()
        return destination
    }

    /// Evicts oldest-touched previews until the cache fits the cap.
    private static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var entries: [(url: URL, date: Date, size: Int64)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast,
                    Int64(values.fileSize ?? 0))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > capBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > capBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

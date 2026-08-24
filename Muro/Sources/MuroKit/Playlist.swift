import Foundation

/// A rotation of wallpapers: apply the next one every `intervalMinutes`,
/// in order or shuffled. Stored in playlists.json next to the manifest.
public struct Playlist: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var wallpaperIDs: [String]
    public var intervalMinutes: Int
    public var shuffle: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        wallpaperIDs: [String] = [],
        intervalMinutes: Int = 30,
        shuffle: Bool = false
    ) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
        self.intervalMinutes = intervalMinutes
        self.shuffle = shuffle
    }
}

public enum PlaylistStore {
    public static func url(root: URL) -> URL {
        root.appendingPathComponent("playlists.json")
    }

    public static func load(root: URL) -> [Playlist] {
        guard let data = try? Data(contentsOf: url(root: root)) else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
    }

    /// Strips deleted wallpaper ids out of every playlist. Returns the pruned
    /// playlists plus the ids of the ones that just lost their last wallpaper,
    /// so a caller can stop one that is running instead of leaving it ticking
    /// over an empty list.
    public static func pruned(
        _ playlists: [Playlist],
        removing ids: Set<String>
    ) -> (playlists: [Playlist], emptied: [String]) {
        var emptied: [String] = []
        let out = playlists.map { playlist -> Playlist in
            var copy = playlist
            copy.wallpaperIDs.removeAll { ids.contains($0) }
            if copy.wallpaperIDs.isEmpty, !playlist.wallpaperIDs.isEmpty {
                emptied.append(playlist.id)
            }
            return copy
        }
        return (out, emptied)
    }

    public static func save(_ playlists: [Playlist], root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(playlists).write(to: url(root: root), options: .atomic)
    }
}

/// The first of "New Playlist", "New Playlist 2", "New Playlist 3" that nobody
/// has taken.
///
/// Playlists and automations are picked from by name, in the menu bar, in the
/// apply panel and in the Library, so two of them called the same thing cannot
/// be told apart. The editors refuse a duplicate typed by hand; this is what
/// stops the default name from walking into that refusal on its own.
public func uniqueName(base: String, taken: [String]) -> String {
    let used = Set(taken.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    })
    guard used.contains(base.lowercased()) else { return base }
    var n = 2
    while used.contains("\(base) \(n)".lowercased()) { n += 1 }
    return "\(base) \(n)"
}

/// Whether `name` is already taken, ignoring case, surrounding spaces and the
/// row being edited.
public func nameIsTaken(_ name: String, in existing: [(id: String, name: String)], excluding id: String?) -> Bool {
    let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { return false }
    return existing.contains {
        $0.id != id
            && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(wanted) == .orderedSame
    }
}

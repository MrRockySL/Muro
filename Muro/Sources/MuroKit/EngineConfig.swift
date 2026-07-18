import Foundation

/// What should play where. Written by the UI / `muro-set`, read (and watched)
/// by the engine — the same mechanism the full app will use later.
public struct EngineConfig: Codable {
    public struct Assignment: Codable {
        public var wallpaperID: String
        /// "smooth" (original fps) or "efficient" (30 fps variant)
        public var mode: String

        public init(wallpaperID: String, mode: String = "smooth") {
            self.wallpaperID = wallpaperID
            self.mode = mode
        }
    }

    /// Fallback for every display without a specific assignment.
    public var allDisplays: Assignment?
    /// Per-display overrides, keyed by display UUID.
    public var perDisplay: [String: Assignment]
    /// User pause from the menu bar (nil = false, keeps old configs valid).
    public var paused: Bool?
    /// Playback speed 0.5–1.5 (nil = 1.0).
    public var playbackSpeed: Double?

    public init(allDisplays: Assignment? = nil, perDisplay: [String: Assignment] = [:]) {
        self.allDisplays = allDisplays
        self.perDisplay = perDisplay
    }

    public func assignment(forDisplayUUID uuid: String?) -> Assignment? {
        if let uuid, let specific = perDisplay[uuid] { return specific }
        return allDisplays
    }

    // MARK: - Load / save

    public static func configURL(root: URL) -> URL {
        root.appendingPathComponent("config.json")
    }

    public static func load(root: URL) -> EngineConfig {
        guard let data = try? Data(contentsOf: configURL(root: root)) else {
            return EngineConfig()
        }
        return (try? JSONDecoder().decode(EngineConfig.self, from: data)) ?? EngineConfig()
    }

    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: EngineConfig.configURL(root: root), options: .atomic)
    }
}

/// Picks the actual video file for an assignment: the Efficient variant when
/// requested and available, otherwise the master.
public func resolveVideoURL(entry: WallpaperEntry, mode: String, root: URL) -> URL {
    if mode == "efficient", let efficient = entry.efficientFile {
        return root.appendingPathComponent(efficient)
    }
    return root.appendingPathComponent(entry.file)
}

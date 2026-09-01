import Foundation

/// The shape of Apple's own wallpaper store, and the one rule Muro has to
/// follow when writing into it.
///
/// `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, and
/// its sibling `Index2.plist`, hold a tree of nodes: one per Space, one per
/// display, plus a system default. Each node keeps its wallpaper under a
/// surface key, and carries a `Type` saying which key that is. macOS's own
/// `WallpaperAgent` knows four types and three surfaces:
///
/// | `Type`       | What the node carries              |
/// |--------------|------------------------------------|
/// | `individual` | `Desktop` and `Idle`, kept apart   |
/// | `linked`     | `Linked`, one wallpaper for both   |
/// | `desktop`    | `Desktop` only                     |
/// | `idle`       | `Idle` only, the screen saver      |
///
/// **The lock screen has no surface of its own.** WallpaperAgent's runtime
/// knows only `linked`, `desktop` and `screenSaver`, so the lock screen
/// renders whatever fills the desktop role: `Desktop` on an individual node,
/// `Linked` on a linked one.
///
/// Muro used to write `Desktop` on every node regardless of its `Type`. On a
/// Mac whose desktop and lock screen are linked, that put the wallpaper under
/// a key macOS never reads, so the lock screen went on showing whatever
/// `Linked` still held, which is Apple's own wallpaper. That is issue #11, and
/// it is why picking the same wallpaper by hand in System Settings worked
/// while applying it from inside Muro did not.
///
/// This lives in MuroKit rather than beside `LockScreenService` for one
/// reason: none of it can be exercised on the machine it was written on. The
/// developer's Mac runs macOS 27 and has never held a linked node, so the only
/// way to know this is right is to rebuild each reported shape as a plist and
/// assert on the result.
public enum AppleWallpaperStore {
    /// Every key a node can keep a wallpaper under.
    public static let surfaceNames = ["Desktop", "Idle", "Linked"]

    /// A dictionary is a wallpaper node when it carries at least one surface.
    ///
    /// Deliberately not keyed on `Type`: a node can be missing it, and the
    /// containers above these nodes (`Spaces`, `Displays`) carry neither.
    public static func isWallpaperNode(_ node: [String: Any]) -> Bool {
        surfaceNames.contains { node[$0] is [String: Any] }
    }

    /// The key this node keeps the wallpaper the lock screen renders under, or
    /// `nil` when Muro has no business writing to this node at all.
    ///
    /// `idle` is the screen saver on its own. Writing there would make Muro
    /// the screen saver rather than the wallpaper, which is not what anybody
    /// asked for, so those nodes are left alone. A node carrying no `Type` at
    /// all keeps the old behaviour and gets `Desktop`.
    public static func desktopSurfaceName(of node: [String: Any]) -> String? {
        switch node["Type"] as? String {
        case "linked": return "Linked"
        case "idle": return nil
        default: return "Desktop"
        }
    }

    /// Puts one choice into a surface, leaving everything else about it alone.
    ///
    /// `Content` is preserved rather than replaced so a surface keeps whatever
    /// else macOS put there, and `Shuffle` is only filled in when it is
    /// missing.
    public static func surfaceApplying(
        choice: [String: Any],
        to surface: [String: Any],
        now: Date = Date()
    ) -> [String: Any] {
        var updated = surface
        var content = updated["Content"] as? [String: Any] ?? [:]
        content["Choices"] = [choice]
        if content["Shuffle"] == nil { content["Shuffle"] = "$null" }
        updated["Content"] = content
        updated["LastSet"] = now
        updated["LastUse"] = now
        return updated
    }

    /// Walks every wallpaper node in the tree, letting the caller rewrite it.
    ///
    /// Recursion stops at a surface key, so nothing inside a `Content`
    /// dictionary is ever mistaken for a node of its own.
    public static func mutateNodes(
        in value: inout Any,
        path: [String] = [],
        transform: ([String], [String: Any]) -> [String: Any]
    ) {
        guard var dictionary = value as? [String: Any] else { return }
        if isWallpaperNode(dictionary) {
            dictionary = transform(path, dictionary)
        }
        // Snapshot the keys: `transform` above may have added or removed some.
        for key in Array(dictionary.keys) where !surfaceNames.contains(key) {
            guard var child = dictionary[key] else { continue }
            mutateNodes(in: &child, path: path + [key], transform: transform)
            dictionary[key] = child
        }
        value = dictionary
    }

    /// Read-only twin of `mutateNodes`.
    public static func forEachNode(
        in value: Any,
        path: [String] = [],
        _ body: ([String], [String: Any]) -> Void
    ) {
        guard let dictionary = value as? [String: Any] else { return }
        if isWallpaperNode(dictionary) { body(path, dictionary) }
        for (key, child) in dictionary where !surfaceNames.contains(key) {
            forEachNode(in: child, path: path + [key], body)
        }
    }

    /// The providers named by a surface, in order.
    public static func providers(of surface: [String: Any]) -> [String] {
        guard let content = surface["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]]
        else { return [] }
        return choices.compactMap { $0["Provider"] as? String }
    }

    /// Whether any surface anywhere in the store names `provider`.
    ///
    /// Looks at all three surfaces. The old check looked only at `Desktop`, so
    /// on a linked Mac a perfectly good apply read back as a failure and the
    /// user was told to go and use System Settings.
    public static func containsProvider(_ provider: String, in store: Any?) -> Bool {
        guard let store else { return false }
        var found = false
        forEachNode(in: store) { _, node in
            for name in surfaceNames {
                guard let surface = node[name] as? [String: Any] else { continue }
                if providers(of: surface).contains(provider) { found = true }
            }
        }
        return found
    }

    /// Writes `choice` into the surface each matching node actually uses.
    ///
    /// `targetKey` is either `"all"` or a display UUID, matched against the
    /// node's path so a single display can be set without touching the rest.
    ///
    /// Returns how many nodes were written, so the caller can tell "the store
    /// had nowhere to put this" apart from "it is written everywhere it
    /// belongs".
    @discardableResult
    public static func applyChoice(
        _ choice: [String: Any],
        to store: inout Any,
        targetKey: String,
        now: Date = Date()
    ) -> Int {
        var written = 0
        mutateNodes(in: &store) { path, node in
            guard targetKey == "all" || path.contains(targetKey) else { return node }
            guard let name = desktopSurfaceName(of: node),
                  let surface = node[name] as? [String: Any]
            else { return node }
            written += 1
            var updated = node
            updated[name] = surfaceApplying(choice: choice, to: surface, now: now)
            return updated
        }
        return written
    }

    /// Puts the choice on one node, creating the surface key when the node
    /// does not have one yet.
    ///
    /// An existing `Type` is never rewritten. That field records how the user
    /// arranged their own desktop and lock screen, and changing it would
    /// silently link or unlink the two behind their back. The single exception
    /// is a screen-saver-only node, which has to gain a desktop surface before
    /// it can hold one, and is then labelled honestly.
    public static func nodeApplying(
        choice: [String: Any],
        to node: [String: Any],
        desktopFallback: [String: Any],
        idleFallback: [String: Any],
        now: Date = Date()
    ) -> [String: Any] {
        var updated = node
        if let name = desktopSurfaceName(of: node) {
            let base = node[name] as? [String: Any] ?? desktopFallback
            updated[name] = surfaceApplying(choice: choice, to: base, now: now)
            return updated
        }
        updated["Desktop"] = surfaceApplying(choice: choice, to: desktopFallback, now: now)
        if updated["Idle"] == nil { updated["Idle"] = idleFallback }
        updated["Type"] = "individual"
        return updated
    }

    /// A node built from nothing, in the one shape observed to work: an
    /// `individual` node carrying both a `Desktop` holding our choice and an
    /// `Idle` left to the system.
    ///
    /// The old code stamped `Type` as `individual` while writing a `Desktop`
    /// and no `Idle`, which describes a node that cannot exist. One reporter's
    /// Mac carried exactly that and macOS never once asked the extension for a
    /// frame.
    public static func makeNode(
        choice: [String: Any],
        desktopFallback: [String: Any],
        idleFallback: [String: Any],
        now: Date = Date()
    ) -> [String: Any] {
        [
            "Type": "individual",
            "Desktop": surfaceApplying(choice: choice, to: desktopFallback, now: now),
            "Idle": idleFallback,
        ]
    }

    /// Whether a node describes itself honestly: every surface it carries is
    /// one its `Type` allows, and every surface that `Type` promises is there.
    ///
    /// Only used by the tests, but it is the invariant the whole file exists
    /// to keep, so it belongs next to the rules rather than beside them.
    public static func isWellFormed(_ node: [String: Any]) -> Bool {
        let present = Set(surfaceNames.filter { node[$0] is [String: Any] })
        switch node["Type"] as? String {
        case "individual": return present == ["Desktop", "Idle"]
        case "linked": return present == ["Linked"]
        case "desktop": return present == ["Desktop"]
        case "idle": return present == ["Idle"]
        default: return true
        }
    }
}

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
/// **The screen saver is the other role**, and it is `Idle` on an individual
/// node. A `linked` node is the one place the two roles are the same key:
/// linking a Mac's desktop and screen saver is what that type means, so one
/// wallpaper serves both and neither can be set without the other.
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

    /// The two roles a wallpaper can fill. Which key each one lands on depends
    /// on the node, which is what the rest of this file is about.
    public enum Surface: Sendable {
        /// The desktop, and with it the lock screen, which has no key of its own.
        case desktop
        /// The screen saver.
        case screenSaver
    }

    /// The key this node keeps the wallpaper for `surface` under, or `nil`
    /// when Muro has no business writing to this node at all.
    ///
    /// A node typed `idle` carries the screen saver and nothing else, so the
    /// desktop role has nowhere to go on it and leaves it alone. Everything
    /// else has a key for both roles, or can be given one. A node carrying no
    /// `Type` at all keeps the old behaviour and gets `Desktop`.
    public static func surfaceName(of node: [String: Any], for surface: Surface) -> String? {
        switch node["Type"] as? String {
        case "linked": return "Linked"
        case "idle" where surface == .desktop: return nil
        default: return surface == .screenSaver ? "Idle" : "Desktop"
        }
    }

    /// The key the lock screen renders from. Unchanged shorthand for the
    /// desktop role, kept because it is what most of the app asks for.
    public static func desktopSurfaceName(of node: [String: Any]) -> String? {
        surfaceName(of: node, for: .desktop)
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

    /// Whether this store holds `provider` **in one particular role**, for one
    /// particular target.
    ///
    /// `containsProvider` answers a different and much broader question, "is
    /// Muro anywhere in this file at all", and it has to stay that way:
    /// `healIfNeeded` uses it to decide whether macOS has thrown Muro out
    /// altogether, and a stricter test there would make Muro tear down a
    /// perfectly good lock screen because the screen saver alone was missing.
    ///
    /// **This is the question an apply needs and never asked.** Muro keeps two
    /// store files and writes both. On 2026-09-10 the owner's Mac ended up
    /// with the screen saver role held by Muro in `Index2.plist` and by
    /// Apple's default in `Index.plist`, which is the file macOS was reading,
    /// so the screen saver showed Apple's aerial wallpaper. The apply that
    /// should have repaired it asked `containsProvider`, got `true` from the
    /// wrong file, called itself settled and stopped retrying. Asking per role,
    /// per target and per file is what makes the retry loop retry.
    public static func holdsRole(
        _ provider: String,
        in store: Any?,
        targetKey: String,
        surface: Surface
    ) -> Bool {
        guard let store else { return false }
        var found = false
        forEachNode(in: store) { path, node in
            guard !found else { return }
            // The key this node keeps the role under, which is not the same on
            // every node: a linked node carries both roles on `Linked`, and an
            // `idle` node has no desktop at all.
            guard let name = surfaceName(of: node, for: surface),
                  let occupant = node[name] as? [String: Any],
                  surfaceBelongsToTarget(path + [name], targetKey: targetKey)
            else { return }
            if providers(of: occupant).contains(provider) { found = true }
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
        surface: Surface = .desktop,
        missingSurface: [String: Any] = [:],
        now: Date = Date()
    ) -> Int {
        var written = 0
        mutateNodes(in: &store) { path, node in
            guard targetKey == "all" || path.contains(targetKey) else { return node }
            guard let name = surfaceName(of: node, for: surface) else { return node }
            if let existing = node[name] as? [String: Any] {
                written += 1
                var updated = node
                updated[name] = surfaceApplying(choice: choice, to: existing, now: now)
                return updated
            }
            // Only the screen saver reaches here, and only on a node that has
            // never had one: `desktop` says so outright, and an untyped node
            // can carry a `Desktop` alone. The desktop role always names a key
            // its own node already has, so nothing about it changes.
            guard surface == .screenSaver else { return node }
            written += 1
            var updated = node
            updated[name] = surfaceApplying(choice: choice, to: missingSurface, now: now)
            // A node that now carries both is an individual one, and saying so
            // is the same honesty `nodeApplying` keeps in the other direction.
            if updated["Type"] as? String == "desktop" { updated["Type"] = "individual" }
            return updated
        }
        return written
    }

    /// The nodes a store already keeps a shared wallpaper in, nearest first.
    ///
    /// `AllSpacesAndDisplays` is the one macOS reads when a display has no
    /// node of its own. `SystemDefault` sits behind it and Apple writes both,
    /// so both are offered.
    public static let sharedNodePaths = [["AllSpacesAndDisplays"], ["SystemDefault"]]

    /// Whether a wallpaper node already sits at `path`.
    public static func hasNode(at path: [String], in store: Any) -> Bool {
        var current = store
        for component in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component]
            else { return false }
            current = next
        }
        guard let node = current as? [String: Any] else { return false }
        return isWallpaperNode(node)
    }

    /// Where to put a choice that `applyChoice` found no room for.
    ///
    /// This is issue #11's second half. A per-display apply matches on the
    /// display's UUID, and a Mac that has never been given a different
    /// wallpaper per screen has no node carrying that UUID at all: its one
    /// wallpaper lives in `AllSpacesAndDisplays`. The old fallback invented
    /// `Displays/<uuid>` for it, which is a node macOS does not read while
    /// that shared node exists, so the apply wrote a file nothing rendered and
    /// then read its own writing back as success.
    ///
    /// So prefer the shared nodes the store already has, and keep inventing a
    /// per-display node only for a store that has neither. Writing the shared
    /// node cannot take a wallpaper away from another display: this is only
    /// reached when no per-display node matched, and a display that has its
    /// own node is served by that node rather than this one.
    public static func fallbackNodePaths(in store: Any, targetKey: String) -> [[String]] {
        if targetKey == "all" { return [["AllSpacesAndDisplays"]] }
        let shared = sharedNodePaths.filter { hasNode(at: $0, in: store) }
        return shared.isEmpty ? [["Displays", targetKey]] : shared
    }

    /// Whether a surface at `surfacePath` belongs to the display being applied
    /// to, or removed from.
    ///
    /// A shared node is everybody's. It is where a Mac with no per-display
    /// node keeps its one wallpaper, so a per-display apply has to write it
    /// and a per-display remove has to be able to take it back out again.
    /// Without this second half the fallback above would leave a wallpaper
    /// that nothing in the app could remove.
    public static func surfaceBelongsToTarget(_ surfacePath: [String], targetKey: String) -> Bool {
        if targetKey == "all" { return true }
        if surfacePath.contains(targetKey) { return true }
        return sharedNodePaths.contains { Array(surfacePath.dropLast()) == $0 }
    }

    /// Writes the choice at one path in the tree, whether or not a node is
    /// already there.
    ///
    /// Replaces two helpers that each bolted a `Desktop` key onto whatever
    /// they found and stamped `Type` as `individual` without adding the `Idle`
    /// that word promises. That left nodes describing a shape they did not
    /// have, and one reporter's Mac carried exactly that while macOS never
    /// asked the extension for a single frame.
    public static func ensureNode(
        at path: [String],
        choice: [String: Any],
        surface: Surface = .desktop,
        desktopFallback: [String: Any],
        idleFallback: [String: Any],
        root: inout Any,
        now: Date = Date()
    ) {
        guard let first = path.first, var rootDictionary = root as? [String: Any] else { return }
        if path.count == 1 {
            let existing = rootDictionary[first] as? [String: Any]
            rootDictionary[first] = existing.map {
                nodeApplying(
                    choice: choice,
                    to: $0,
                    surface: surface,
                    desktopFallback: desktopFallback,
                    idleFallback: idleFallback,
                    now: now
                )
            } ?? makeNode(
                choice: choice,
                surface: surface,
                desktopFallback: desktopFallback,
                idleFallback: idleFallback,
                now: now
            )
            root = rootDictionary
            return
        }
        var container = rootDictionary[first] as? [String: Any] ?? [:]
        var nested: Any = container
        ensureNode(
            at: Array(path.dropFirst()),
            choice: choice,
            surface: surface,
            desktopFallback: desktopFallback,
            idleFallback: idleFallback,
            root: &nested,
            now: now
        )
        container = nested as? [String: Any] ?? container
        rootDictionary[first] = container
        root = rootDictionary
    }

    /// The whole write: put the choice in every node that already serves this
    /// target, and when the tree has none, put it where that tree keeps its
    /// wallpaper.
    ///
    /// Returns how many existing nodes were written, so a caller can still
    /// tell a normal apply from one that had to fall back.
    @discardableResult
    public static func applyChoiceCreatingNode(
        _ choice: [String: Any],
        to store: inout Any,
        targetKey: String,
        surface: Surface = .desktop,
        desktopFallback: [String: Any],
        idleFallback: [String: Any],
        now: Date = Date()
    ) -> Int {
        let written = applyChoice(
            choice,
            to: &store,
            targetKey: targetKey,
            surface: surface,
            missingSurface: surface == .screenSaver ? idleFallback : desktopFallback,
            now: now
        )
        guard written == 0 else { return written }
        for path in fallbackNodePaths(in: store, targetKey: targetKey) {
            ensureNode(
                at: path,
                choice: choice,
                surface: surface,
                desktopFallback: desktopFallback,
                idleFallback: idleFallback,
                root: &store,
                now: now
            )
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
        surface: Surface = .desktop,
        desktopFallback: [String: Any],
        idleFallback: [String: Any],
        now: Date = Date()
    ) -> [String: Any] {
        var updated = node
        if let name = surfaceName(of: node, for: surface) {
            let base = node[name] as? [String: Any]
                ?? (name == "Idle" ? idleFallback : desktopFallback)
            updated[name] = surfaceApplying(choice: choice, to: base, now: now)
            if name == "Idle", updated["Desktop"] == nil, updated["Linked"] == nil {
                updated["Desktop"] = desktopFallback
            }
            if name == "Idle", updated["Type"] as? String == "desktop" {
                updated["Type"] = "individual"
            }
            return updated
        }
        // Only the desktop role reaches here, on a screen-saver-only node.
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
        surface: Surface = .desktop,
        desktopFallback: [String: Any],
        idleFallback: [String: Any],
        now: Date = Date()
    ) -> [String: Any] {
        switch surface {
        case .desktop:
            return [
                "Type": "individual",
                "Desktop": surfaceApplying(choice: choice, to: desktopFallback, now: now),
                "Idle": idleFallback,
            ]
        case .screenSaver:
            return [
                "Type": "individual",
                "Desktop": desktopFallback,
                "Idle": surfaceApplying(choice: choice, to: idleFallback, now: now),
            ]
        }
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

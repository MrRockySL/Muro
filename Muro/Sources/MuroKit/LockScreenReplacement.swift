import Foundation

/// When macOS gives a display's wallpaper slot to something else (#58).
///
/// macOS keeps one wallpaper per display for the desktop and the lock screen
/// together, and a lock screen set from Muro lives in that slot. A picture set
/// in System Settings or Finder goes into the same slot, so it takes the lock
/// screen with it. That is how macOS works, and Muro cannot stop it. What Muro
/// got wrong was going on saying "Applied". Its record was only checked at
/// launch, and only reset when Muro had gone from Apple's stores altogether,
/// which a screen saver of Muro's is enough to prevent.
///
/// Measured on the owner's Mac on 2026-10-26, a MacBook and a DELL. Setting a
/// picture on the MacBook rewrote four nodes with a fresh `LastSet`: the
/// display's own `Displays/<uuid>` and `Spaces//Displays/<uuid>`, plus
/// `Spaces//Default` and `SystemDefault`. Every other Space's node for the
/// MacBook kept Muro, with the `LastSet` of Muro's own apply. The DELL's own
/// nodes were not touched, and its lock screen stayed Muro's.
///
/// So the answer for a display is the choice set most recently among the
/// nodes that belong to it, and only those. A shared node changing says
/// nothing about a display that has nodes of its own.
public enum LockScreenReplacement {
    /// What macOS most recently put in one display's desktop role, which is
    /// also what its lock screen shows.
    public struct Choice: Equatable {
        public var providers: [String]
        public var setAt: Date?

        public init(providers: [String], setAt: Date?) {
            self.providers = providers
            self.setAt = setAt
        }
    }

    /// The choice set most recently for this display's desktop role, or `nil`
    /// when the store says nothing about it.
    ///
    /// The display's own nodes answer when it has any, in every Space. A Mac
    /// that has never been given a wallpaper per screen keeps its one
    /// wallpaper in the shared nodes, and only then do those answer.
    public static func latestDesktopChoice(forDisplay uuid: String, in store: Any?) -> Choice? {
        guard let store else { return nil }
        var own: Choice?
        var shared: Choice?
        AppleWallpaperStore.forEachNode(in: store) { path, node in
            // The key the lock screen renders from: `Desktop`, or `Linked` on
            // a linked node. An `idle` node is the screen saver only.
            guard let name = AppleWallpaperStore.surfaceName(of: node, for: .desktop),
                  let surface = node[name] as? [String: Any]
            else { return }
            let choice = Choice(
                providers: AppleWallpaperStore.providers(of: surface),
                setAt: surface["LastSet"] as? Date
            )
            if path.contains(uuid) {
                own = newer(own, choice)
            } else if isShared(path) {
                shared = newer(shared, choice)
            }
        }
        return own ?? shared
    }

    /// The whole surface behind `latestDesktopChoice`: what macOS most
    /// recently put in this display's desktop role, by the same rule. For
    /// reading what it holds, not only who it belongs to (see
    /// `OwnDesktopPicture`).
    public static func latestDesktopSurface(forDisplay uuid: String, in store: Any?) -> [String: Any]? {
        guard let store else { return nil }
        var own: (surface: [String: Any], at: Date)?
        var shared: (surface: [String: Any], at: Date)?
        AppleWallpaperStore.forEachNode(in: store) { path, node in
            guard let name = AppleWallpaperStore.surfaceName(of: node, for: .desktop),
                  let surface = node[name] as? [String: Any]
            else { return }
            let at = surface["LastSet"] as? Date ?? .distantPast
            if path.contains(uuid) {
                if own.map({ at > $0.at }) ?? true { own = (surface, at) }
            } else if isShared(path) {
                if shared.map({ at > $0.at }) ?? true { shared = (surface, at) }
            }
        }
        return (own ?? shared)?.surface
    }

    /// The displays among `claimed` whose lock screen macOS now gives to
    /// something other than `provider`.
    ///
    /// Two witnesses have to agree, because being wrong the other way is
    /// worse than the bug. A display Muro wrongly lets go of is one the
    /// desktop still writer is then free to write a picture into, and that
    /// would throw away a lock screen that was working.
    ///
    /// - The store: the choice set most recently for the display is not
    ///   `provider`'s.
    /// - macOS itself: `desktopPictures` holds what `NSWorkspace` names as
    ///   each display's desktop picture. While that is one of the extension's
    ///   own files, Muro is still there, whatever the store says. A display
    ///   it names nothing for is left to the store.
    public static func replacedDisplays(
        claimed: Set<String>,
        store: Any?,
        provider: String,
        desktopPictures: [String: URL]
    ) -> Set<String> {
        claimed.filter { uuid in
            guard let latest = latestDesktopChoice(forDisplay: uuid, in: store),
                  !latest.providers.isEmpty,
                  !latest.providers.contains(provider)
            else { return false }
            if let picture = desktopPictures[uuid], picture.path.contains(provider) {
                return false
            }
            return true
        }
    }

    /// `AllSpacesAndDisplays`, `SystemDefault`, and each Space's `Default`:
    /// the nodes a display with none of its own reads.
    private static func isShared(_ path: [String]) -> Bool {
        if AppleWallpaperStore.sharedNodePaths.contains(path) { return true }
        return path.count == 3 && path[0] == "Spaces" && path[2] == "Default"
    }

    /// A choice with no `LastSet` loses to any choice that has one.
    private static func newer(_ current: Choice?, _ candidate: Choice) -> Choice {
        guard let current else { return candidate }
        let a = current.setAt ?? .distantPast
        let b = candidate.setAt ?? .distantPast
        return b > a ? candidate : current
    }
}

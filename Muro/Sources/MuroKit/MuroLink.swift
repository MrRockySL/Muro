import Foundation

/// What a `muro://` link asks for, read on its own so it can be tested
/// without the app.
///
/// Any web page can open a `muro://` link, and the browser's "Open Muro?" is
/// one click, so a link is held to things that are safe to do from a page:
/// it can pick a wallpaper that is already on this Mac, on a display that is
/// connected, and pause or resume. Anything else is refused here, before the
/// app changes anything. Whether the wallpaper is on this Mac is the app's to
/// check, since only the app knows its Library.
public enum MuroLink: Equatable {
    case set(id: String, display: String?, surface: Surface?)
    case pause
    case resume

    /// Where a `set` link puts the wallpaper. Left out, it goes where picking
    /// the wallpaper in the menu bar would put it.
    public enum Surface: String, CaseIterable {
        case all, desktop, lockscreen, screensaver
    }

    /// The longest link that is read at all. A real one is about a hundred
    /// characters.
    public static let longestLink = 1024

    /// Why a link was ignored, for the log.
    public enum Refusal: Error, Equatable {
        case tooLong
        case notMuro
        case unknownAction(String)
        case missingID
        case displayNotConnected(String)
        case unknownSurface(String)
    }

    /// Reads `url`. `connectedDisplays` holds the UUIDs of the displays
    /// plugged in now. A display that isn't one of them is refused: applying
    /// to it would stop a playlist and leave an entry in the config for a
    /// screen that isn't there.
    public static func read(_ url: URL, connectedDisplays: Set<String>) -> Result<MuroLink, Refusal> {
        guard url.absoluteString.utf8.count <= longestLink else { return .failure(.tooLong) }
        guard url.scheme?.lowercased() == "muro" else { return .failure(.notMuro) }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        let action = (url.host ?? "").lowercased()
        switch action {
        case "pause":
            return .success(.pause)
        case "resume":
            return .success(.resume)
        case "set":
            guard let id = query["id"], !id.isEmpty else { return .failure(.missingID) }
            var display: String?
            if let asked = query["display"] {
                // UUIDs are compared without regard to case, and the
                // display's own spelling is the one passed on, since that is
                // the key the config uses.
                guard let match = connectedDisplays.first(where: { $0.caseInsensitiveCompare(asked) == .orderedSame })
                else { return .failure(.displayNotConnected(asked)) }
                display = match
            }
            var surface: Surface?
            if let asked = query["surface"] {
                guard let known = Surface(rawValue: asked.lowercased()) else {
                    return .failure(.unknownSurface(asked))
                }
                surface = known
            }
            return .success(.set(id: id, display: display, surface: surface))
        default:
            return .failure(.unknownAction(action))
        }
    }
}

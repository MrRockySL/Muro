import AppKit
import Foundation
import MuroKit

// muro-set: applies wallpapers from the library — the CLI form of the app's
// future "Set Wallpaper" button. The engine picks changes up instantly.
//
//   muro-set --list                          list library wallpapers
//   muro-set --displays                      list connected displays
//   muro-set "Snowfall" [--all]              apply to all displays (default)
//   muro-set "Snowfall" --display "DELL"     apply to one display (name match)
//   muro-set "Snowfall" --efficient          use / generate the 30 fps variant
//   muro-set --clear                         remove all assignments

func fail(_ message: String) -> Never {
    fputs("muro-set: \(message)\n", stderr)
    exit(1)
}

let root = LibraryManifest.defaultRoot()
var manifest = LibraryManifest.load(root: root)
var config = EngineConfig.load(root: root)

var query: String?
var displayQuery: String?
var applyToAll = true
var efficient = false
var listWallpapers = false
var listDisplays = false
var clear = false

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--list": listWallpapers = true
    case "--displays": listDisplays = true
    case "--clear": clear = true
    case "--all": applyToAll = true
    case "--efficient": efficient = true
    case "--display":
        guard !args.isEmpty else { fail("--display needs a name") }
        displayQuery = args.removeFirst()
        applyToAll = false
    default:
        query = arg
    }
}

if listWallpapers {
    for w in manifest.wallpapers {
        let eff = w.efficientFile != nil ? " [+30fps variant]" : ""
        print("\(w.title)  —  \(w.category), \(w.width)x\(w.height) @\(Int(w.fps))fps\(eff)")
    }
    exit(0)
}

if listDisplays {
    for screen in NSScreen.screens {
        let uuid = displayUUID(for: screen) ?? "?"
        let size = "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        print("\(screen.localizedName)  \(size)  uuid=\(uuid)")
    }
    exit(0)
}

if clear {
    config = EngineConfig()
    try? config.save(root: root)
    print("cleared all assignments")
    exit(0)
}

guard let query else {
    fail("usage: muro-set <title> [--display NAME | --all] [--efficient] | --list | --displays | --clear")
}

// Find the wallpaper by (partial, case-insensitive) title or exact id.
let matches = manifest.wallpapers.filter {
    $0.id == query || $0.title.localizedCaseInsensitiveContains(query)
}
guard let index = manifest.wallpapers.firstIndex(where: { $0.id == matches.first?.id }), matches.count == 1 else {
    if matches.isEmpty { fail("no wallpaper matches \"\(query)\" — try muro-set --list") }
    fail("\"\(query)\" is ambiguous: \(matches.map(\.title).joined(separator: ", "))")
}
var entry = manifest.wallpapers[index]

// Efficient mode: generate the 30 fps variant once if the master is >40 fps.
var mode = "smooth"
if efficient {
    mode = "efficient"
    if entry.fps > 40, entry.efficientFile == nil {
        let variantRelative = "Masters/\(entry.id)-eff.mov"
        let variantURL = root.appendingPathComponent(variantRelative)
        print("generating 30 fps variant of \"\(entry.title)\"…")
        do {
            _ = try transcodeToHEVC(
                source: root.appendingPathComponent(entry.file),
                destination: variantURL,
                halveFrameRate: true
            )
            entry.efficientFile = variantRelative
            manifest.wallpapers[index] = entry
            try manifest.save(root: root)
        } catch {
            fail("variant generation failed: \(error)")
        }
    }
}

let assignment = EngineConfig.Assignment(wallpaperID: entry.id, mode: mode)

if applyToAll {
    config.allDisplays = assignment
    config.perDisplay = [:]
    try? config.save(root: root)
    print("applied \"\(entry.title)\" (\(mode)) to all displays")
} else {
    guard let displayQuery else { fail("--display needs a name") }
    let screens = NSScreen.screens.filter {
        $0.localizedName.localizedCaseInsensitiveContains(displayQuery)
    }
    guard screens.count == 1, let uuid = displayUUID(for: screens[0]) else {
        let names = NSScreen.screens.map(\.localizedName).joined(separator: ", ")
        fail("display \"\(displayQuery)\" not found or ambiguous — connected: \(names)")
    }
    config.perDisplay[uuid] = assignment
    try? config.save(root: root)
    print("applied \"\(entry.title)\" (\(mode)) to \(screens[0].localizedName)")
}

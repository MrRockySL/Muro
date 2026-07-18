import Foundation
import MuroKit

// muro-import: brings a video into the Muro library.
//   muro-import --title "Snowy Japan" --category "Nature" [--library DIR] <video>
// Transcodes to HEVC (video only, fps preserved), generates a thumbnail,
// and appends the wallpaper to library.json.

func fail(_ message: String) -> Never {
    fputs("muro-import: \(message)\n", stderr)
    exit(1)
}

var title: String?
var category: String?
var libraryRoot = LibraryManifest.defaultRoot()
var sourcePath: String?

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--title":
        guard !args.isEmpty else { fail("--title needs a value") }
        title = args.removeFirst()
    case "--category":
        guard !args.isEmpty else { fail("--category needs a value") }
        category = args.removeFirst()
    case "--library":
        guard !args.isEmpty else { fail("--library needs a value") }
        libraryRoot = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
    default:
        sourcePath = arg
    }
}

guard let sourcePath else {
    fail("usage: muro-import --title T --category C [--library DIR] <video>")
}
let source = URL(fileURLWithPath: sourcePath)
guard FileManager.default.fileExists(atPath: source.path) else {
    fail("no such file: \(source.path)")
}

do {
    let started = Date()
    let entry = try importVideo(
        source: source,
        title: title,
        category: category ?? "Uncategorized",
        root: libraryRoot
    )
    let mb = Double(entry.sizeBytes) / 1_048_576
    let secs = Date().timeIntervalSince(started)
    print(String(
        format: "imported \"%@\" [%@] %dx%d @%.0ffps %.0fs %.1fMB (took %.1fs) id=%@",
        entry.title, entry.category, entry.width, entry.height,
        entry.fps, entry.duration, mb, secs, entry.id
    ))
} catch {
    fail("\(error)")
}

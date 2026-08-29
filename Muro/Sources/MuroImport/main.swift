import Foundation
import MuroKit

// muro-import: brings a video into the Muro library.
//   muro-import --title "Snowy Japan" --category "Nature" [--library DIR]
//               [--original] <video>
// Makes the master, a thumbnail and a p720 preview, then appends the
// wallpaper to library.json.
//
// --original copies the source video stream instead of re-encoding it to
// HEVC, so the master is the source picture to the bit. Use it for anything
// being published: a wallpaper people download should never be worse than the
// clip it came from. The file is bigger, which is the point of the trade.

func fail(_ message: String) -> Never {
    fputs("muro-import: \(message)\n", stderr)
    exit(1)
}

var title: String?
var category: String?
var libraryRoot = LibraryManifest.defaultRoot()
var sourcePath: String?
var preserveOriginal = false

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
    case "--original", "--no-transcode":
        preserveOriginal = true
    case "--library":
        guard !args.isEmpty else { fail("--library needs a value") }
        libraryRoot = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
    default:
        sourcePath = arg
    }
}

guard let sourcePath else {
    fail("usage: muro-import --title T --category C [--library DIR] [--original] <video>")
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
        root: libraryRoot,
        preserveOriginal: preserveOriginal
    )
    let mb = Double(entry.sizeBytes) / 1_048_576
    let secs = Date().timeIntervalSince(started)
    print(String(
        format: "imported \"%@\" [%@] %dx%d @%.0ffps %.0fs %.1fMB %@ (took %.1fs) id=%@",
        entry.title, entry.category, entry.width, entry.height,
        entry.fps, entry.duration, mb,
        preserveOriginal ? "original quality" : "hevc", secs, entry.id
    ))
} catch {
    fail("\(error)")
}

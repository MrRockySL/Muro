import Foundation
import MuroKit

// muro-publish — one command to publish wallpapers (PLAN §Distribution):
// regenerates catalog.json from the local library and (only with --upload)
// pushes the HEVC master + thumbnail of each wallpaper to the GitHub
// release. The DEFAULT is a dry run: nothing leaves this Mac without
// --upload, honoring the "no publishing until owner sign-off" gate.
//
// Usage:
//   muro-publish [--upload] [--repo OWNER/NAME] [--tag TAG]
//                [--catalog PATH] [title ...]
//
//   (no titles)     publish every wallpaper in the library
//   --upload        actually run `gh release upload` (default: dry run)
//   --repo          GitHub repo               (default: MrRockySL/Muro)
//   --tag           release tag for assets    (default: wallpapers)
//   --catalog       where to write catalog.json (default: ./catalog.json)
//
// After uploading, commit the generated catalog.json to the repo root on
// `main` — the app fetches it from raw.githubusercontent.com at launch,
// which is how every old install sees new wallpapers without an update.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("muro-publish: " + message + "\n").utf8))
    exit(1)
}

struct Options {
    var upload = false
    var repo = "MrRockySL/Muro-Wallpapers"
    var tag = "wallpapers"
    var catalogPath = "catalog.json"
    var titles: [String] = []
}

func parseOptions() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func value(for flag: String) -> String {
        guard !args.isEmpty else { die("\(flag) needs a value") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--upload":  opts.upload = true
        case "--dry-run": opts.upload = false
        case "--repo":    opts.repo = value(for: "--repo")
        case "--tag":     opts.tag = value(for: "--tag")
        case "--catalog": opts.catalogPath = value(for: "--catalog")
        case "--help", "-h":
            print("usage: muro-publish [--upload] [--repo OWNER/NAME] [--tag TAG] [--catalog PATH] [title ...]")
            exit(0)
        default:
            if arg.hasPrefix("--") { die("unknown option \(arg)") }
            opts.titles.append(arg)
        }
    }
    return opts
}

/// Runs a command, streaming its output; returns the exit code.
@discardableResult
func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    do { try process.run() } catch { die("failed to run \(launchPath): \(error.localizedDescription)") }
    process.waitUntilExit()
    return process.terminationStatus
}

func ghPath() -> String {
    for candidate in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    die("GitHub CLI (gh) not found — brew install gh, then gh auth login")
}

// MARK: - Select wallpapers

let opts = parseOptions()
let root = LibraryManifest.defaultRoot()
let manifest = LibraryManifest.load(root: root)
guard !manifest.wallpapers.isEmpty else { die("library is empty — nothing to publish") }

let selected: [WallpaperEntry]
if opts.titles.isEmpty {
    selected = manifest.wallpapers
} else {
    selected = opts.titles.map { title in
        guard let entry = manifest.wallpapers.first(where: {
            $0.title.lowercased() == title.lowercased()
        }) else {
            die("no wallpaper titled \"\(title)\" — titles: "
                + manifest.wallpapers.map(\.title).joined(separator: ", "))
        }
        return entry
    }
}

// Every asset must exist locally before we promise it in the catalog.
var assetFiles: [(entry: WallpaperEntry, paths: [String])] = []
for entry in selected {
    let paths = [entry.file, entry.thumbnail].map { root.appendingPathComponent($0).path }
    for path in paths where !FileManager.default.fileExists(atPath: path) {
        die("missing file for \"\(entry.title)\": \(path)")
    }
    assetFiles.append((entry, paths))
}

// MARK: - catalog.json

// Asset URLs use the flat basenames (<id>.mov / <id>.jpg) that
// `gh release upload` derives from the file paths.
let base = "https://github.com/\(opts.repo)/releases/download/\(opts.tag)/"
let catalog = RemoteCatalog(wallpapers: selected.map { entry in
    CatalogEntry(
        id: entry.id, title: entry.title, category: entry.category,
        width: entry.width, height: entry.height, fps: entry.fps,
        duration: entry.duration, sizeBytes: entry.sizeBytes,
        video: URL(string: base + (entry.file as NSString).lastPathComponent)!,
        thumbnail: URL(string: base + (entry.thumbnail as NSString).lastPathComponent)!
    )
})

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
do {
    try (try encoder.encode(catalog))
        .write(to: URL(fileURLWithPath: opts.catalogPath), options: .atomic)
} catch {
    die("could not write \(opts.catalogPath): \(error.localizedDescription)")
}
print("wrote \(opts.catalogPath) (\(catalog.wallpapers.count) wallpapers)")

// MARK: - Upload

let totalBytes = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
let totalMB = String(format: "%.0f MB", Double(totalBytes) / 1_048_576)

if !opts.upload {
    print("\nDRY RUN — nothing uploaded. Would run:")
    print("  gh release view \(opts.tag) --repo \(opts.repo)  (create if missing)")
    for (entry, paths) in assetFiles {
        print("  gh release upload \(opts.tag) \(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")) --repo \(opts.repo) --clobber   # \(entry.title)")
    }
    print("total upload: \(totalMB) in \(assetFiles.count * 2) assets")
    print("\nRe-run with --upload once the owner has signed off on publishing,")
    print("then commit \(opts.catalogPath) to the repo root on main as catalog.json.")
    exit(0)
}

let gh = ghPath()
print("checking release \(opts.tag) on \(opts.repo)…")
if run(gh, ["release", "view", opts.tag, "--repo", opts.repo]) != 0 {
    print("creating release \(opts.tag)…")
    guard run(gh, [
        "release", "create", opts.tag, "--repo", opts.repo,
        "--title", "Wallpapers",
        "--notes", "Wallpaper assets. The Muro app downloads these on demand — install the app instead of downloading from here."
    ]) == 0 else { die("could not create release \(opts.tag)") }
}

print("uploading \(assetFiles.count * 2) assets (\(totalMB))…")
let allPaths = assetFiles.flatMap(\.paths)
guard run(gh, ["release", "upload", opts.tag, "--repo", opts.repo, "--clobber"] + allPaths) == 0 else {
    die("upload failed")
}
print("done. Now commit \(opts.catalogPath) to the repo root on main as catalog.json —")
print("every installed app picks up the new wallpapers at next launch.")

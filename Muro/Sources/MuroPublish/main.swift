import Foundation
import MuroKit

// muro-publish — one command to publish wallpapers (PLAN §Distribution):
// regenerates catalog.json from the local library and (only with --upload)
// pushes each wallpaper's master + thumbnail + p720 preview. The DEFAULT is
// a dry run: nothing leaves this Mac without --upload.
//
// Where it publishes:
//   • If ~/.config/muro/r2.json exists (it does since 2026-07-19): Cloudflare
//     R2 — masters/<id>.mov, thumbs/<id>.jpg, p720/<id>.mov, plus
//     catalog.json uploaded to the bucket itself. Publishing is ONE command;
//     there is no git commit step. New wallpapers propagate in ~1 minute
//     (catalog is served with max-age=60).
//   • --github forces the legacy GitHub Releases path (assets on the
//     `wallpapers` tag + commit catalog.json to the repo yourself).
//
// Usage:
//   muro-publish [--upload] [--github] [--repo OWNER/NAME] [--tag TAG]
//                [--catalog PATH] [title ...]
//
//   (no titles)     publish every wallpaper in the library
//   --upload        actually upload (default: dry run)
//   --github        use GitHub Releases instead of R2
//   --repo          GitHub repo               (default: MrRockySL/Muro-Wallpapers)
//   --tag           release tag for assets    (default: wallpapers)
//   --catalog       where to also write catalog.json locally (default: ./catalog.json)

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("muro-publish: " + message + "\n").utf8))
    exit(1)
}

struct Options {
    var upload = false
    var forceGitHub = false
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
        case "--github":  opts.forceGitHub = true
        case "--repo":    opts.repo = value(for: "--repo")
        case "--tag":     opts.tag = value(for: "--tag")
        case "--catalog": opts.catalogPath = value(for: "--catalog")
        case "--help", "-h":
            print("usage: muro-publish [--upload] [--github] [--repo OWNER/NAME] [--tag TAG] [--catalog PATH] [title ...]")
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
// The master and thumbnail are mandatory; the p720 preview is published when
// present (its absence only costs the detail view its motion preview, and
// pre-preview libraries would otherwise be unpublishable).
var assetFiles: [(entry: WallpaperEntry, paths: [String])] = []
var missingPreviews: [String] = []
for entry in selected {
    let paths = [entry.file, entry.thumbnail].map { root.appendingPathComponent($0).path }
    for path in paths where !FileManager.default.fileExists(atPath: path) {
        die("missing file for \"\(entry.title)\": \(path)")
    }
    var all = paths
    if let preview = entry.previewFile {
        let path = root.appendingPathComponent(preview).path
        if FileManager.default.fileExists(atPath: path) {
            all.append(path)
        } else {
            die("library.json promises a preview for \"\(entry.title)\" but the file is missing: \(path)")
        }
    } else {
        missingPreviews.append(entry.title)
    }
    assetFiles.append((entry, all))
}
if !missingPreviews.isEmpty {
    print("note: no p720 preview for \(missingPreviews.count) wallpaper(s) — "
        + "run muro-prepare to generate them: \(missingPreviews.joined(separator: ", "))")
}

// MARK: - catalog.json

// MARK: - Destination

let r2 = opts.forceGitHub ? nil : R2Config.load()
if r2 == nil && !opts.forceGitHub {
    print("note: no \(R2Config.configPath) — falling back to GitHub Releases")
}

/// R2 object key for a library-relative path. Layout (PLAN §2.7):
/// masters/<id>.mov · thumbs/<id>.jpg · p720/<id>.mov · catalog.json
func r2Key(for relative: String, entry: WallpaperEntry) -> String {
    if relative == entry.file { return "masters/\(entry.id).mov" }
    if relative == entry.thumbnail { return "thumbs/\(entry.id).jpg" }
    return "p720/\(entry.id).mov"
}

// MARK: - catalog.json

let immutableCache = "public, max-age=31536000, immutable"
let catalogCache = "public, max-age=60"

let catalog: RemoteCatalog
if let r2 {
    let base = r2.publicBaseURL.hasSuffix("/") ? String(r2.publicBaseURL.dropLast()) : r2.publicBaseURL
    catalog = RemoteCatalog(wallpapers: selected.map { entry in
        CatalogEntry(
            id: entry.id, title: entry.title, category: entry.category,
            width: entry.width, height: entry.height, fps: entry.fps,
            duration: entry.duration, sizeBytes: entry.sizeBytes,
            video: URL(string: "\(base)/masters/\(entry.id).mov")!,
            thumbnail: URL(string: "\(base)/thumbs/\(entry.id).jpg")!,
            preview720: entry.previewFile != nil
                ? URL(string: "\(base)/p720/\(entry.id).mov") : nil
        )
    })
} else {
    // Asset URLs use the flat basenames (<id>.mov / <id>.jpg / <id>-p720.mov)
    // that `gh release upload` derives from the file paths.
    let base = "https://github.com/\(opts.repo)/releases/download/\(opts.tag)/"
    catalog = RemoteCatalog(wallpapers: selected.map { entry in
        CatalogEntry(
            id: entry.id, title: entry.title, category: entry.category,
            width: entry.width, height: entry.height, fps: entry.fps,
            duration: entry.duration, sizeBytes: entry.sizeBytes,
            video: URL(string: base + (entry.file as NSString).lastPathComponent)!,
            thumbnail: URL(string: base + (entry.thumbnail as NSString).lastPathComponent)!,
            preview720: entry.previewFile.map {
                URL(string: base + ($0 as NSString).lastPathComponent)!
            }
        )
    })
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let catalogData: Data
do {
    catalogData = try encoder.encode(catalog)
    try catalogData.write(to: URL(fileURLWithPath: opts.catalogPath), options: .atomic)
} catch {
    die("could not write \(opts.catalogPath): \(error.localizedDescription)")
}
print("wrote \(opts.catalogPath) (\(catalog.wallpapers.count) wallpapers)")

// MARK: - Upload

let totalBytes = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
let totalMB = String(format: "%.0f MB", Double(totalBytes) / 1_048_576)
let assetCount = assetFiles.reduce(0) { $0 + $1.paths.count }

if !opts.upload {
    print("\nDRY RUN — nothing uploaded. Would publish:")
    if let r2 {
        for (entry, _) in assetFiles {
            var keys = ["masters/\(entry.id).mov", "thumbs/\(entry.id).jpg"]
            if entry.previewFile != nil { keys.append("p720/\(entry.id).mov") }
            print("  → \(r2.bucket)/{\(keys.joined(separator: ", "))}   # \(entry.title)")
        }
        print("  → \(r2.bucket)/catalog.json")
    } else {
        for (entry, paths) in assetFiles {
            print("  gh release upload \(opts.tag) \(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")) --repo \(opts.repo) --clobber   # \(entry.title)")
        }
    }
    print("total upload: \(totalMB) in \(assetCount) assets")
    print("\nRe-run with --upload to publish.")
    exit(0)
}

if let r2 {
    print("uploading \(assetCount) assets (\(totalMB)) to R2 bucket \(r2.bucket)…")
    var uploaded = 0
    for (entry, paths) in assetFiles {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let relative = path.hasPrefix(root.path)
                ? String(path.dropFirst(root.path.count + 1)) : path
            let key = r2Key(for: relative, entry: entry)
            let sizeMB = Double((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0 ?? 0) / 1_048_576
            let contentType = key.hasSuffix(".jpg") ? "image/jpeg" : "video/quicktime"
            print(String(format: "  [%d/%d] %@ (%.1f MB)…", uploaded + 1, assetCount, key, sizeMB), terminator: " ")
            do {
                try r2Put(file: url, key: key, contentType: contentType,
                          cacheControl: immutableCache, config: r2)
                print("ok")
            } catch {
                print("")
                die("\(error)")
            }
            uploaded += 1
        }
    }
    print("  catalog.json…", terminator: " ")
    let tempCatalog = FileManager.default.temporaryDirectory
        .appendingPathComponent("muro-catalog-\(UUID().uuidString).json")
    do {
        try catalogData.write(to: tempCatalog)
        try r2Put(file: tempCatalog, key: "catalog.json",
                  contentType: "application/json",
                  cacheControl: catalogCache, config: r2)
        try? FileManager.default.removeItem(at: tempCatalog)
        print("ok")
    } catch {
        try? FileManager.default.removeItem(at: tempCatalog)
        print("")
        die("\(error)")
    }
    print("done. Live in ~1 minute — no git step. Verify: curl -sI \(r2.publicBaseURL)/catalog.json")
} else {
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

    let allPaths = assetFiles.flatMap(\.paths)
    print("uploading \(allPaths.count) assets (\(totalMB))…")
    guard run(gh, ["release", "upload", opts.tag, "--repo", opts.repo, "--clobber"] + allPaths) == 0 else {
        die("upload failed")
    }
    print("done. Now commit \(opts.catalogPath) to the repo root on main as catalog.json —")
    print("every installed app picks up the new wallpapers at next launch.")
}

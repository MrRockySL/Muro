import Foundation
import MuroKit

// muro-publish — one command to publish wallpapers (PLAN §Distribution):
// merges the local library into the live catalog.json and (only with
// --upload) pushes each new wallpaper's master + thumbnail + p720 preview.
// The DEFAULT is a dry run: nothing leaves this Mac without --upload.
//
// The catalog is the app's ENTIRE library list, so it is always merged, never
// replaced: wallpapers this Mac does not have are carried through from what
// is already live, and assets already published are not re-sent. That makes
// adding wallpapers additive — import the new ones, publish, done — and means
// a partial local library can no longer wipe wallpapers out of every install.
// --replace opts back into the old destructive behaviour.
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
//   --replace       publish ONLY the selected wallpapers, dropping everything
//                   else that is live (destructive — rarely what you want)
//   --reupload      re-send assets for wallpapers already published
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
    var replace = false
    var reupload = false
    var reorderOnly = false
    var repo = "MrRockySL/Muro-Wallpapers"
    var tag = "wallpapers"
    var catalogPath = "catalog.json"
    var libraryRoot = LibraryManifest.defaultRoot()
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
        case "--replace": opts.replace = true
        case "--reupload": opts.reupload = true
        case "--reorder-only": opts.reorderOnly = true
        case "--repo":    opts.repo = value(for: "--repo")
        case "--tag":     opts.tag = value(for: "--tag")
        case "--catalog": opts.catalogPath = value(for: "--catalog")
        case "--library":
            opts.libraryRoot = URL(fileURLWithPath: value(for: "--library"), isDirectory: true)
        case "--help", "-h":
            print("""
                usage: muro-publish [--upload] [--replace] [--reupload] [--github]
                                    [--library DIR] [--repo OWNER/NAME] [--tag TAG]
                                    [--catalog PATH] [title ...]

                  (no titles)  publish every wallpaper in the local library
                  --upload     actually upload (default: dry run)
                  --library    publish from this library instead of the app's own
                               (~/Library/Application Support/Muro). Use a staging
                               folder so publishing never fills your own library.
                  --replace    publish ONLY the selected wallpapers, dropping anything
                               else that is currently live (destructive — rarely wanted)
                  --reupload   re-upload assets for wallpapers already live
                  --reorder-only  rewrite just the order of the live catalog (newest
                               first) and re-upload catalog.json — no library needed,
                               no wallpaper assets touched
                """)
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
if opts.reorderOnly && opts.replace {
    die("--reorder-only cannot be combined with --replace")
}
let root = opts.libraryRoot

// --reorder-only rewrites only the order of the live catalog and touches no
// wallpapers, so it needs no local library. Every other mode publishes from
// the library, so it must exist and be non-empty.
let selected: [WallpaperEntry]
if opts.reorderOnly {
    selected = []
} else {
    let manifest = LibraryManifest.load(root: root)
    guard !manifest.wallpapers.isEmpty else { die("library is empty — nothing to publish") }
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

let publishedEntries: [CatalogEntry]
if let r2 {
    let base = r2.publicBaseURL.hasSuffix("/") ? String(r2.publicBaseURL.dropLast()) : r2.publicBaseURL
    publishedEntries = selected.map { entry in
        CatalogEntry(
            id: entry.id, title: entry.title, category: entry.category,
            width: entry.width, height: entry.height, fps: entry.fps,
            duration: entry.duration, sizeBytes: entry.sizeBytes,
            video: URL(string: "\(base)/masters/\(entry.id).mov")!,
            thumbnail: URL(string: "\(base)/thumbs/\(entry.id).jpg")!,
            preview720: entry.previewFile != nil
                ? URL(string: "\(base)/p720/\(entry.id).mov") : nil
        )
    }
} else {
    // Asset URLs use the flat basenames (<id>.mov / <id>.jpg / <id>-p720.mov)
    // that `gh release upload` derives from the file paths.
    let base = "https://github.com/\(opts.repo)/releases/download/\(opts.tag)/"
    publishedEntries = selected.map { entry in
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
    }
}

// MARK: - Merge with what is already live

// catalog.json is the app's ENTIRE library list, not a changelog. Writing it
// as just the wallpapers this run selected makes the live catalog a mirror of
// whichever Mac happened to publish — so a partial local library (a fresh
// install, a wiped Mac, or simply `muro-publish "One Title"`) would delete
// every other wallpaper from every installed app. So we merge: what we
// publish wins by id, and anything only the live catalog knows about is
// carried through untouched.
let liveCatalogURL: URL = {
    if let r2 {
        let base = r2.publicBaseURL.hasSuffix("/") ? String(r2.publicBaseURL.dropLast()) : r2.publicBaseURL
        return URL(string: "\(base)/catalog.json")!
    }
    return URL(string: "https://raw.githubusercontent.com/\(opts.repo)/main/catalog.json")!
}()

/// Reads the published catalog. `nil` means "there is no catalog yet" (404);
/// a thrown error means we could not tell, which must never be treated as
/// an empty catalog.
func fetchLiveCatalog(_ url: URL) throws -> RemoteCatalog? {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 20
    var payload: Data?
    var status = 0
    var transportError: Error?
    let finished = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        transportError = error
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        payload = data
        finished.signal()
    }.resume()
    finished.wait()
    if let transportError { throw transportError }
    if status == 404 { return nil }
    guard status == 200, let payload else {
        throw NSError(domain: "muro-publish", code: status, userInfo: [
            NSLocalizedDescriptionKey: "HTTP \(status) reading \(url.absoluteString)"
        ])
    }
    return try RemoteCatalog.makeDecoder().decode(RemoteCatalog.self, from: payload)
}

var liveEntries: [CatalogEntry] = []
if opts.replace {
    print("--replace: writing ONLY the \(publishedEntries.count) selected wallpaper(s); "
        + "anything else currently live will be removed from every install.")
} else {
    do {
        if let live = try fetchLiveCatalog(liveCatalogURL) {
            liveEntries = live.wallpapers
            print("live catalog: \(liveEntries.count) wallpapers — merging.")
        } else {
            print("live catalog: none yet — publishing a fresh one.")
        }
    } catch {
        // Publishing a replacing catalog because the network hiccuped is the
        // one failure that damages every installed app, so refuse instead.
        die("""
            could not read the live catalog at \(liveCatalogURL.absoluteString): \
            \(error.localizedDescription)
            Refusing to publish, because overwriting it blind would delete any \
            wallpaper missing from this Mac. Fix connectivity and retry, or pass \
            --replace if you really do mean to publish only these \
            \(publishedEntries.count) wallpaper(s).
            """)
    }
}

if opts.reorderOnly && liveEntries.isEmpty {
    die("--reorder-only needs an existing live catalog to reorder, but none was "
        + "found at \(liveCatalogURL.absoluteString)")
}

let publishedByID = Dictionary(uniqueKeysWithValues: publishedEntries.map { ($0.id, $0) })

/// Re-publishing a wallpaper must never make its catalog entry *poorer* than
/// the one already live. A library that downloaded a wallpaper through the app
/// has no local p720 file, so it would otherwise strip a perfectly good
/// published preview URL — the file is on the CDN either way.
func merging(live: CatalogEntry, with published: CatalogEntry) -> CatalogEntry {
    var result = published
    if result.preview720 == nil { result.preview720 = live.preview720 }
    // The publish date belongs to the wallpaper's first appearance, so the
    // live value always wins. Re-stamping it on every republish would make
    // the whole library look brand new to every install at once — exactly
    // the bug this field exists to fix.
    result.publishedAt = live.publishedAt ?? published.publishedAt
    return result
}

/// Orders the catalog newest first. The installed app paints Explore in
/// catalog array order (it has no sort of its own), so the order written here
/// is exactly what every install shows — reordering the catalog moves fresh
/// drops to the top for everyone, with no app update. Entries with no
/// publishedAt (catalogs from before that field existed) keep their existing
/// relative order at the bottom; the original index breaks ties so equal dates
/// and undated entries stay in a stable, deterministic order.
func newestFirst(_ entries: [CatalogEntry]) -> [CatalogEntry] {
    entries.enumerated().sorted { lhs, rhs in
        switch (lhs.element.publishedAt, rhs.element.publishedAt) {
        case let (l?, r?): return l == r ? lhs.offset < rhs.offset : l > r
        case (_?, nil):    return true      // dated entries sit above undated ones
        case (nil, _?):    return false
        case (nil, nil):   return lhs.offset < rhs.offset
        }
    }.map(\.element)
}

var mergedEntries = liveEntries.map { live in
    publishedByID[live.id].map { merging(live: live, with: $0) } ?? live
}
let liveIDs = Set(liveEntries.map(\.id))
// Anything the live catalog has never seen is being published now, so now is
// its publish date.
let publishDate = Date()
mergedEntries.append(contentsOf: publishedEntries
    .filter { !liveIDs.contains($0.id) }
    .map { entry in
        var stamped = entry
        stamped.publishedAt = publishDate
        return stamped
    })

// Newest wallpapers first so every install sees the latest drops at the top of
// Explore. This replaces the old append-to-the-end behaviour.
mergedEntries = newestFirst(mergedEntries)

let newCount = publishedEntries.filter { !liveIDs.contains($0.id) }.count
let updatedCount = publishedEntries.count - newCount
let carriedCount = mergedEntries.count - publishedEntries.count

let catalog = RemoteCatalog(wallpapers: mergedEntries)

let encoder = RemoteCatalog.makeEncoder()
let catalogData: Data
do {
    catalogData = try encoder.encode(catalog)
    try catalogData.write(to: URL(fileURLWithPath: opts.catalogPath), options: .atomic)
} catch {
    die("could not write \(opts.catalogPath): \(error.localizedDescription)")
}
print("wrote \(opts.catalogPath) — \(catalog.wallpapers.count) wallpapers "
    + "(\(newCount) new, \(updatedCount) updated, \(carriedCount) carried over)")
let head = mergedEntries.prefix(8).enumerated()
    .map { "  \($0.offset + 1). \($0.element.title) [\($0.element.category)]" }
    .joined(separator: "\n")
print("new order — top of Explore:\n\(head)")

// MARK: - Upload

// Assets are named by id and served immutable, so a wallpaper already in the
// live catalog already has its files on the CDN — re-sending them costs
// bandwidth and, worse, would overwrite the published copies with whatever
// this Mac happens to hold (an older, non-faststart master, say). Skip them
// unless --reupload asks for it.
let alreadyLive = opts.reupload ? [] : liveIDs
let pendingAssets = assetFiles.filter { !alreadyLive.contains($0.entry.id) }
let skippedCount = assetFiles.count - pendingAssets.count
if skippedCount > 0 {
    print("skipping \(skippedCount) wallpaper(s) already published "
        + "(pass --reupload to send them again).")
}

let totalBytes = pendingAssets.reduce(Int64(0)) { $0 + $1.entry.sizeBytes }
let totalMB = String(format: "%.0f MB", Double(totalBytes) / 1_048_576)
let assetCount = pendingAssets.reduce(0) { $0 + $1.paths.count }

if !opts.upload {
    print("\nDRY RUN — nothing uploaded. Would publish:")
    if let r2 {
        for (entry, _) in pendingAssets {
            var keys = ["masters/\(entry.id).mov", "thumbs/\(entry.id).jpg"]
            if entry.previewFile != nil { keys.append("p720/\(entry.id).mov") }
            print("  → \(r2.bucket)/{\(keys.joined(separator: ", "))}   # \(entry.title)")
        }
        print("  → \(r2.bucket)/catalog.json")
    } else {
        for (entry, paths) in pendingAssets {
            print("  gh release upload \(opts.tag) \(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")) --repo \(opts.repo) --clobber   # \(entry.title)")
        }
    }
    print("catalog.json would list \(catalog.wallpapers.count) wallpapers "
        + "(\(newCount) new, \(updatedCount) updated, \(carriedCount) carried over)")
    print("total upload: \(totalMB) in \(assetCount) assets")
    print("\nRe-run with --upload to publish.")
    exit(0)
}

if let r2 {
    print("uploading \(assetCount) assets (\(totalMB)) to R2 bucket \(r2.bucket)…")
    var uploaded = 0
    for (entry, paths) in pendingAssets {
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

    let allPaths = pendingAssets.flatMap(\.paths)
    if allPaths.isEmpty {
        print("no new assets to upload — catalog.json only.")
    } else {
        print("uploading \(allPaths.count) assets (\(totalMB))…")
        guard run(gh, ["release", "upload", opts.tag, "--repo", opts.repo, "--clobber"] + allPaths) == 0 else {
            die("upload failed")
        }
    }
    print("done. Now commit \(opts.catalogPath) to the repo root on main as catalog.json —")
    print("every installed app picks up the new wallpapers at next launch.")
}

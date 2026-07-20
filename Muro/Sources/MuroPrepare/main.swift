import Foundation
import MuroKit

// muro-prepare — brings an existing library up to the current asset spec,
// so it can be published. Two repairs, both idempotent:
//
//   1. Masters written before the transcoder set shouldOptimizeForNetworkUse
//      have their moov atom at the END of the file, which breaks streaming.
//      Those are remuxed losslessly (passthrough export — no re-encode, no
//      quality change) with the atom moved to the front.
//   2. Wallpapers without a p720 preview get one generated into Previews/.
//
// library.json is updated as work happens. Safe to re-run any time; already
// conforming wallpapers are skipped.
//
// Usage:
//   muro-prepare [--dry-run] [title ...]
//
//   (no titles)   prepare every wallpaper in the library
//   --dry-run     report what would be done without touching anything

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("muro-prepare: " + message + "\n").utf8))
    exit(1)
}

struct Options {
    var dryRun = false
    var titles: [String] = []
}

func parseOptions() -> Options {
    var opts = Options()
    for arg in CommandLine.arguments.dropFirst() {
        switch arg {
        case "--dry-run": opts.dryRun = true
        case "--help", "-h":
            print("usage: muro-prepare [--dry-run] [title ...]")
            exit(0)
        default:
            if arg.hasPrefix("--") { die("unknown option \(arg)") }
            opts.titles.append(arg)
        }
    }
    return opts
}

/// Reads the top-level QuickTime atoms and reports whether `moov` comes
/// before `mdat` — the "faststart" layout a streaming player needs.
func isFastStart(_ url: URL) -> Bool? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var offset: UInt64 = 0
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    while offset < fileSize {
        try? handle.seek(toOffset: offset)
        guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
        var size = UInt64(header.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) })
        let type = String(decoding: header[4..<8], as: UTF8.self)
        if size == 1 {   // 64-bit extended size follows the type
            guard header.count >= 16 else { return nil }
            size = header[8..<16].reduce(0) { ($0 << 8) | UInt64($1) }
        } else if size == 0 {   // atom runs to end of file
            size = fileSize - offset
        }
        if type == "moov" { return true }
        if type == "mdat" { return false }
        guard size > 0 else { return nil }
        offset += size
    }
    return nil
}

let opts = parseOptions()
let root = LibraryManifest.defaultRoot()
var manifest = LibraryManifest.load(root: root)
guard !manifest.wallpapers.isEmpty else { die("library is empty — nothing to prepare") }

let selectedIDs: Set<String>
if opts.titles.isEmpty {
    selectedIDs = Set(manifest.wallpapers.map(\.id))
} else {
    selectedIDs = Set(opts.titles.map { title in
        guard let entry = manifest.wallpapers.first(where: {
            $0.title.lowercased() == title.lowercased()
        }) else {
            die("no wallpaper titled \"\(title)\" — titles: "
                + manifest.wallpapers.map(\.title).joined(separator: ", "))
        }
        return entry.id
    })
}

let previewsDir = root.appendingPathComponent("Previews", isDirectory: true)
try? FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)

var remuxed = 0, previewed = 0, failures = 0

for index in manifest.wallpapers.indices where selectedIDs.contains(manifest.wallpapers[index].id) {
    let entry = manifest.wallpapers[index]
    let masterURL = root.appendingPathComponent(entry.file)
    guard FileManager.default.fileExists(atPath: masterURL.path) else {
        print("⚠︎ \(entry.title): master missing at \(masterURL.path) — skipped")
        failures += 1
        continue
    }

    // -- 1. faststart ------------------------------------------------------
    // The efficient variant is served whole (never streamed), so only the
    // master is checked.
    switch isFastStart(masterURL) {
    case false:
        if opts.dryRun {
            print("· \(entry.title): would remux (moov at end)")
        } else {
            let temp = masterURL.deletingLastPathComponent()
                .appendingPathComponent("\(entry.id).remux.mov")
            do {
                try remuxForStreaming(source: masterURL, destination: temp)
                guard isFastStart(temp) == true else {
                    try? FileManager.default.removeItem(at: temp)
                    throw TranscodeError.writerFailed("remux output is still not faststart")
                }
                _ = try FileManager.default.replaceItemAt(masterURL, withItemAt: temp)
                if let size = try? FileManager.default.attributesOfItem(atPath: masterURL.path)[.size] as? Int64 {
                    manifest.wallpapers[index].sizeBytes = size
                }
                print("✓ \(entry.title): remuxed, moov now at front")
                remuxed += 1
            } catch {
                print("✗ \(entry.title): remux failed — \(error)")
                failures += 1
                continue
            }
        }
    case true:
        break
    case nil:
        print("⚠︎ \(entry.title): could not parse atoms — skipped remux")
        failures += 1
    }

    // -- 2. p720 preview ---------------------------------------------------
    let relative = "Previews/\(entry.id)-p720.mov"
    let previewURL = root.appendingPathComponent(relative)
    let hasFile = FileManager.default.fileExists(atPath: previewURL.path)
    if entry.previewFile != nil && hasFile { continue }
    if opts.dryRun {
        print("· \(entry.title): would generate p720 preview")
        continue
    }
    do {
        let result = try generatePreview(source: masterURL, destination: previewURL, spec: .p720)
        manifest.wallpapers[index].previewFile = relative
        let mb = String(format: "%.1f MB", Double(result.sizeBytes) / 1_048_576)
        print("✓ \(entry.title): p720 preview \(result.width)×\(result.height), \(String(format: "%.0f", result.duration)) s, \(mb)")
        previewed += 1
    } catch {
        print("✗ \(entry.title): preview failed — \(error)")
        failures += 1
    }
}

if !opts.dryRun && (remuxed > 0 || previewed > 0) {
    do { try manifest.save(root: root) } catch { die("could not save library.json: \(error)") }
}
print("\ndone: \(remuxed) remuxed, \(previewed) previews generated, \(failures) failures")
exit(failures == 0 ? 0 : 1)

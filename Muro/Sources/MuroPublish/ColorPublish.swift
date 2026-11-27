import AVFoundation
import Foundation
import MuroKit

// muro-publish colors <folder> [--upload]
//
// Publishes the other colours of a few live wallpapers to their own section
// of the server, beside the live wallpapers (see `HostedColors` in MuroKit):
//
//   colors.json                                    the list, merged with the live one
//   colors/<wallpaper id>/<key>/<version>/<file>   each colour's files
//
// <folder> holds plan.json and, for every colour, a folder of its files:
//
//   plan.json                       {"families": [{"id": "<live wallpaper id>",
//                                      "order": 0,
//                                      "original": {"key": "blue", "name": "Blue", "hex": "#0E9BFB"},
//                                      "colors": [{"key": "red", "name": "Red", "hex": "#F83D31"}, ...]}]}
//   <id>/<key>/master.mov           the colour's full video
//   <id>/<key>/p720.mov             its 720p preview
//   <id>/<key>/thumb.jpg            its card picture
//
// Every family must belong to a live wallpaper in the live catalog.json.
// Every family already live and not in <folder> is carried over untouched,
// and a list that cannot be read stops the publish rather than being taken
// for an empty one.
//
// The DEFAULT is a dry run: nothing leaves this Mac without --upload.

private struct ColorPlan: Decodable {
    struct Family: Decodable {
        var id: String
        var order: Int?
        var original: HostedColors.Swatch
        var colors: [HostedColors.Swatch]
    }
    var families: [Family]
}

/// The live list, or nil when the server has none yet. Anything else that
/// stops it being read ends the publish.
private func fetchLiveColors(_ url: URL) -> HostedColors.List? {
    guard let (status, data) = fetchForColors(url) else {
        die("could not read the live \(HostedColors.listName). Nothing published.")
    }
    if status == 404 { return nil }
    guard status == 200 else { die("the live \(HostedColors.listName) answered HTTP \(status). Nothing published.") }
    guard let list = try? JSONDecoder().decode(HostedColors.List.self, from: data),
          let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let rawItems = raw["wallpapers"] as? [Any],
          rawItems.count == list.wallpapers.count
    else {
        die("the live \(HostedColors.listName) has entries this muro-publish cannot read. Nothing published.")
    }
    return list
}

private func fetchForColors(_ url: URL) -> (Int, Data)? {
    var outcome: (Int, Data)?
    let done = DispatchSemaphore(value: 0)
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if error == nil {
            outcome = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
        }
        done.signal()
    }.resume()
    done.wait()
    return outcome
}

/// A video's size in pixels, frame rate and length, as AVFoundation reads it.
private func videoFacts(_ url: URL) -> (width: Int, height: Int, fps: Double, duration: Double)? {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }
    let size = track.naturalSize.applying(track.preferredTransform)
    let duration = asset.duration.seconds
    guard duration.isFinite, duration > 0 else { return nil }
    return (Int(abs(size.width).rounded()), Int(abs(size.height).rounded()),
            Double(track.nominalFrameRate), duration)
}

private func fileRecord(_ url: URL, name: String) -> HostedInteractive.File? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return HostedInteractive.File(path: name, size: Int64(data.count), sha256: HostedInteractive.sha256(data))
}

func publishColors(_ arguments: [String]) -> Never {
    var upload = false
    var source: URL?
    for argument in arguments {
        switch argument {
        case "--upload": upload = true
        case "--dry-run": upload = false
        case "--help", "-h":
            print("usage: muro-publish colors <folder> [--upload]")
            exit(0)
        default:
            if argument.hasPrefix("--") { die("unknown option \(argument)") }
            guard source == nil else { die("one folder only") }
            source = URL(fileURLWithPath: argument, isDirectory: true).resolvingSymlinksInPath()
        }
    }
    guard let source else { die("usage: muro-publish colors <folder> [--upload]") }
    guard let config = R2Config.load() else { die("no R2 config at \(R2Config.configPath)") }
    guard let base = URL(string: config.publicBaseURL) else { die("publicBaseURL is not a URL") }

    guard let planData = try? Data(contentsOf: source.appendingPathComponent("plan.json")),
          let plan = try? JSONDecoder().decode(ColorPlan.self, from: planData)
    else { die("no readable plan.json in \(source.path)") }

    // Every family must belong to a live wallpaper people can already see.
    guard let (catalogStatus, catalogData) = fetchForColors(base.appendingPathComponent("catalog.json")),
          catalogStatus == 200,
          let catalog = try? RemoteCatalog.makeDecoder().decode(RemoteCatalog.self, from: catalogData)
    else { die("could not read the live catalog.json. Nothing published.") }
    let titles = Dictionary(catalog.wallpapers.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

    // MARK: Read and check every colour in the folder

    let today: String = {
        let days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]
        return days.string(from: Date())
    }()
    var local: [HostedColors.Family] = []
    var problems: [String] = []
    for planned in plan.families {
        guard titles[planned.id] != nil else {
            problems.append("\(planned.id): not a live wallpaper in catalog.json")
            continue
        }
        var variants: [HostedColors.Variant] = []
        for swatch in planned.colors {
            let home = source.appendingPathComponent(planned.id, isDirectory: true)
                .appendingPathComponent(swatch.key, isDirectory: true)
            let masterURL = home.appendingPathComponent(HostedColors.masterName)
            guard let master = fileRecord(masterURL, name: HostedColors.masterName),
                  let preview = fileRecord(home.appendingPathComponent(HostedColors.previewName), name: HostedColors.previewName),
                  let thumbnail = fileRecord(home.appendingPathComponent(HostedColors.thumbnailName), name: HostedColors.thumbnailName)
            else {
                problems.append("\(titles[planned.id] ?? planned.id) / \(swatch.name): needs \(HostedColors.masterName), \(HostedColors.previewName) and \(HostedColors.thumbnailName) in \(home.path)")
                continue
            }
            guard let facts = videoFacts(masterURL) else {
                problems.append("\(titles[planned.id] ?? planned.id) / \(swatch.name): \(HostedColors.masterName) is not a video AVFoundation can read")
                continue
            }
            variants.append(HostedColors.Variant(
                key: swatch.key, name: swatch.name, hex: swatch.hex,
                version: HostedColors.version(master: master, preview: preview, thumbnail: thumbnail),
                width: facts.width, height: facts.height, fps: facts.fps, duration: facts.duration,
                master: master, preview: preview, thumbnail: thumbnail
            ))
        }
        let family = HostedColors.Family(
            id: planned.id, original: planned.original, colors: variants,
            order: planned.order, added: today
        )
        guard HostedColors.isUsable(family) else {
            problems.append("\(titles[planned.id] ?? planned.id): not publishable (keys a-z, names up to 24 letters, colours #RRGGBB, 1 to \(HostedColors.mostColors) colours, no key twice)")
            continue
        }
        local.append(family)
    }
    if !problems.isEmpty { die("nothing published:\n  " + problems.joined(separator: "\n  ")) }
    guard !local.isEmpty else { die("no colours in \(source.path)") }

    // MARK: Merge with what is live

    let listURL = base.appendingPathComponent(HostedColors.listName)
    let live = fetchLiveColors(listURL)
    if live == nil { print("No \(HostedColors.listName) on the server yet: this starts it.") }
    var merged = live?.wallpapers ?? []
    var added: [String] = [], updated: [String] = [], unchanged: [String] = []
    var toUpload: [(family: String, variant: HostedColors.Variant)] = []
    for incoming in local {
        var family = incoming
        let title = titles[family.id] ?? family.id
        if let index = merged.firstIndex(where: { $0.id == family.id }) {
            // The day it first went up stays, whatever today is.
            family.added = merged[index].added
            let liveVersions = Dictionary(
                merged[index].colors.map { ($0.key, $0.version) }, uniquingKeysWith: { first, _ in first })
            if merged[index] == family {
                unchanged.append(title)
            } else {
                for variant in family.colors where liveVersions[variant.key] != variant.version {
                    toUpload.append((family.id, variant))
                }
                merged[index] = family
                updated.append(title)
            }
        } else {
            merged.append(family)
            added.append(title)
            for variant in family.colors { toUpload.append((family.id, variant)) }
        }
    }
    merged = HostedColors.sorted(merged)
    let carried = merged.count - local.count

    print("\(merged.count) live wallpapers with colors (\(added.count) new, \(updated.count) updated, \(unchanged.count) unchanged, \(carried) carried over)")
    var total: Int64 = 0
    for family in merged {
        let names = ([family.original.name + " (original)"] + family.colors.map(\.name)).joined(separator: ", ")
        print("  \(family.order.map(String.init) ?? "-")  \(titles[family.id] ?? family.id)  added \(family.added)  \(names)")
    }
    for (family, variant) in toUpload {
        for file in [variant.master, variant.preview, variant.thumbnail] {
            total += file.size
            let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
            print("  upload \(HostedColors.serverFolder)/\(family)/\(variant.key)/\(variant.version)/\(file.path)  \(size)")
        }
    }
    print("  upload \(HostedColors.listName)")
    print("To send: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let listData = try? encoder.encode(HostedColors.List(wallpapers: merged)) else {
        die("could not write the list")
    }
    let localCopy = source.appendingPathComponent(HostedColors.listName)

    guard upload else {
        print("Dry run: nothing uploaded. Run again with --upload.")
        exit(0)
    }

    // MARK: Upload: the files first, the list last

    do {
        for (family, variant) in toUpload {
            let home = source.appendingPathComponent(family, isDirectory: true)
                .appendingPathComponent(variant.key, isDirectory: true)
            for file in [variant.master, variant.preview, variant.thumbnail] {
                let key = "\(HostedColors.serverFolder)/\(family)/\(variant.key)/\(variant.version)/\(file.path)"
                try r2Put(
                    file: home.appendingPathComponent(file.path), key: key,
                    contentType: file.path.hasSuffix(".jpg") ? "image/jpeg" : "video/quicktime",
                    cacheControl: "public, max-age=31536000, immutable",
                    config: config
                )
                print("  sent \(key)")
            }
        }
        try listData.write(to: localCopy, options: .atomic)
        try r2Put(
            file: localCopy, key: HostedColors.listName,
            contentType: "application/json", cacheControl: "public, max-age=60", config: config
        )
        print("  sent \(HostedColors.listName)")
    } catch {
        die("upload failed: \(error)")
    }
    print("Live: \(listURL.absoluteString)")
    exit(0)
}

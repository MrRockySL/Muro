import Foundation
import ImageIO
import MuroKit

// muro-publish statics <folder> [--upload]
//
// Publishes static wallpapers (still pictures) to their own section of the
// server, beside the live wallpapers (see `HostedStatics` in MuroKit):
//
//   statics.json                        the list, merged with the live one
//   statics/<id>/<version>/<file>       each picture and its card picture
//
// <folder> holds one folder per picture: the picture itself (one .jpg, .jpeg,
// .png or .heic), thumb.jpg for its card, and a wallpaper.json naming it:
//
//   {"id": "static-...", "title": "...", "author": null,
//    "added": "2026-11-27", "order": 0}
//
// `order` pins a picture to the front of the Static section; the rest follow
// newest first. Every picture already live and not in <folder> is carried
// over untouched, and a list that cannot be read stops the publish rather
// than being taken for an empty one.
//
// The DEFAULT is a dry run: nothing leaves this Mac without --upload.

private struct StaticSourceInfo: Decodable {
    var id: String
    var title: String
    var author: String?
    var added: String
    var order: Int?
}

private func staticContentType(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "heic": return "image/heic"
    default: return "application/octet-stream"
    }
}

/// The live list, or nil when the server has none yet. Anything else that
/// stops it being read ends the publish.
private func fetchLiveStatics(_ url: URL) -> HostedStatics.List? {
    var outcome: Result<(Int, Data), Error>?
    let done = DispatchSemaphore(value: 0)
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            outcome = .failure(error)
        } else {
            outcome = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
        }
        done.signal()
    }.resume()
    done.wait()
    switch outcome! {
    case .failure(let error):
        die("could not read the live \(HostedStatics.listName): \(error.localizedDescription). Nothing published.")
    case .success(let (status, data)):
        if status == 404 { return nil }
        guard status == 200 else { die("the live \(HostedStatics.listName) answered HTTP \(status). Nothing published.") }
        guard let list = try? JSONDecoder().decode(HostedStatics.List.self, from: data),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawItems = raw["wallpapers"] as? [Any],
              rawItems.count == list.wallpapers.count
        else {
            die("the live \(HostedStatics.listName) has entries this muro-publish cannot read. Nothing published.")
        }
        return list
    }
}

/// The picture's size in pixels, as it shows (rotation applied).
private func pixelSize(of url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return orientation >= 5 ? (height, width) : (width, height)
}

func publishStatics(_ arguments: [String]) -> Never {
    var upload = false
    var source: URL?
    for argument in arguments {
        switch argument {
        case "--upload": upload = true
        case "--dry-run": upload = false
        case "--help", "-h":
            print("usage: muro-publish statics <folder> [--upload]")
            exit(0)
        default:
            if argument.hasPrefix("--") { die("unknown option \(argument)") }
            guard source == nil else { die("one folder only") }
            source = URL(fileURLWithPath: argument, isDirectory: true).resolvingSymlinksInPath()
        }
    }
    guard let source else { die("usage: muro-publish statics <folder> [--upload]") }
    guard let config = R2Config.load() else { die("no R2 config at \(R2Config.configPath)") }
    guard let base = URL(string: config.publicBaseURL) else { die("publicBaseURL is not a URL") }

    // MARK: Read and check every picture in the folder

    let manager = FileManager.default
    let names = ((try? manager.contentsOfDirectory(atPath: source.path)) ?? [])
        .filter { !$0.hasPrefix(".") }.sorted()
    var local: [(entry: HostedStatics.Entry, home: URL)] = []
    var problems: [String] = []
    for name in names {
        let home = source.appendingPathComponent(name, isDirectory: true)
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: home.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
        guard let data = try? Data(contentsOf: home.appendingPathComponent("wallpaper.json")),
              let info = try? JSONDecoder().decode(StaticSourceInfo.self, from: data)
        else {
            problems.append("\(name): no readable wallpaper.json")
            continue
        }
        let files = ((try? manager.contentsOfDirectory(atPath: home.path)) ?? []).filter { !$0.hasPrefix(".") }
        let pictures = files.filter {
            $0 != HostedStatics.thumbnailName
                && HostedStatics.pictureExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
        guard pictures.count == 1, let pictureName = pictures.first else {
            problems.append("\(name): needs exactly one picture (.jpg, .jpeg, .png or .heic) beside \(HostedStatics.thumbnailName), found \(pictures.count)")
            continue
        }
        guard files.contains(HostedStatics.thumbnailName) else {
            problems.append("\(name): no \(HostedStatics.thumbnailName)")
            continue
        }
        let pictureURL = home.appendingPathComponent(pictureName)
        let thumbURL = home.appendingPathComponent(HostedStatics.thumbnailName)
        guard let pictureBytes = try? Data(contentsOf: pictureURL),
              let thumbBytes = try? Data(contentsOf: thumbURL)
        else {
            problems.append("\(name): cannot read its files")
            continue
        }
        guard let size = pixelSize(of: pictureURL) else {
            problems.append("\(name): \(pictureName) is not a picture macOS can read")
            continue
        }
        let picture = HostedInteractive.File(
            path: pictureName.lowercased(), size: Int64(pictureBytes.count),
            sha256: HostedInteractive.sha256(pictureBytes))
        let thumbnail = HostedInteractive.File(
            path: HostedStatics.thumbnailName, size: Int64(thumbBytes.count),
            sha256: HostedInteractive.sha256(thumbBytes))
        let entry = HostedStatics.Entry(
            id: info.id, title: info.title, author: info.author, added: info.added, order: info.order,
            width: size.width, height: size.height,
            version: HostedStatics.version(picture: picture, thumbnail: thumbnail),
            picture: picture, thumbnail: thumbnail
        )
        guard HostedStatics.isUsable(entry) else {
            problems.append("\(name): not publishable (the id must start with \(HostedStatics.idPrefix), file names a-z 0-9 . _ - only, picture up to \(HostedStatics.largestPicture / 1_048_576) MB)")
            continue
        }
        local.append((entry, home))
    }
    if !problems.isEmpty { die("nothing published:\n  " + problems.joined(separator: "\n  ")) }
    guard !local.isEmpty else { die("no pictures in \(source.path)") }

    // MARK: Merge with what is live

    let listURL = base.appendingPathComponent(HostedStatics.listName)
    let live = fetchLiveStatics(listURL)
    if live == nil { print("No \(HostedStatics.listName) on the server yet: this starts it.") }
    var merged = live?.wallpapers ?? []
    var added: [String] = [], updated: [String] = [], unchanged: [String] = []
    var toUpload: [(entry: HostedStatics.Entry, home: URL, pictureName: String)] = []
    for (incoming, home) in local {
        var entry = incoming
        let pictureName = ((try? manager.contentsOfDirectory(atPath: home.path)) ?? [])
            .first { $0.lowercased() == entry.picture.path } ?? entry.picture.path
        if let index = merged.firstIndex(where: { $0.id == entry.id }) {
            // The day it first went up stays, whatever the folder says now.
            entry.added = merged[index].added
            if merged[index] == entry {
                unchanged.append(entry.title)
            } else {
                if merged[index].version != entry.version { toUpload.append((entry, home, pictureName)) }
                merged[index] = entry
                updated.append(entry.title)
            }
        } else {
            merged.append(entry)
            added.append(entry.title)
            toUpload.append((entry, home, pictureName))
        }
    }
    merged = HostedStatics.sorted(merged)
    let carried = merged.count - local.count

    print("\(merged.count) static wallpapers (\(added.count) new, \(updated.count) updated, \(unchanged.count) unchanged, \(carried) carried over)")
    for entry in merged {
        let size = ByteCountFormatter.string(fromByteCount: entry.picture.size, countStyle: .file)
        print("  \(entry.order.map(String.init) ?? "-")  \(entry.title)  \(entry.width)x\(entry.height)  \(size)  added \(entry.added)  v\(entry.version)")
    }
    for (entry, _, _) in toUpload {
        for file in [entry.picture, entry.thumbnail] {
            print("  upload statics/\(entry.id)/\(entry.version)/\(file.path)")
        }
    }
    print("  upload \(HostedStatics.listName)")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let listData = try? encoder.encode(HostedStatics.List(wallpapers: merged)) else {
        die("could not write the list")
    }
    let localCopy = source.appendingPathComponent(HostedStatics.listName)

    guard upload else {
        print("Dry run: nothing uploaded. Run again with --upload.")
        exit(0)
    }

    // MARK: Upload: the files first, the list last

    do {
        for (entry, home, pictureName) in toUpload {
            let pairs: [(file: HostedInteractive.File, local: URL)] = [
                (entry.picture, home.appendingPathComponent(pictureName)),
                (entry.thumbnail, home.appendingPathComponent(HostedStatics.thumbnailName)),
            ]
            for (file, url) in pairs {
                let key = "statics/\(entry.id)/\(entry.version)/\(file.path)"
                try r2Put(
                    file: url, key: key,
                    contentType: staticContentType(for: file.path),
                    cacheControl: "public, max-age=31536000, immutable",
                    config: config
                )
                print("  sent \(key)")
            }
        }
        try listData.write(to: localCopy, options: .atomic)
        try r2Put(
            file: localCopy, key: HostedStatics.listName,
            contentType: "application/json", cacheControl: "public, max-age=60", config: config
        )
        print("  sent \(HostedStatics.listName)")
    } catch {
        die("upload failed: \(error)")
    }
    print("Live: \(listURL.absoluteString)")
    exit(0)
}

import Foundation
import MuroKit

// muro-publish interactive <folder> [--upload]
//
// Publishes interactive wallpapers to their own section of the server, beside
// the live wallpapers (see `HostedInteractive` in MuroKit):
//
//   interactive.json                     the list, merged with the live one
//   interactive/<id>/<version>/<file>    each wallpaper's files
//
// <folder> holds one folder per wallpaper: index.html, thumb.jpg, still.jpg,
// any files the page uses, and a wallpaper.json naming it:
//
//   {"id": "interactive-muro-eclipse", "title": "Eclipse",
//    "author": "MrRockySL", "added": "2026-11-13", "order": 1}
//
// Every page and script is checked for anything reaching outside its own
// folder first; one that does is not published. Every wallpaper already live
// and not in <folder> is carried over untouched, and a list that cannot be
// read stops the publish rather than being taken for an empty one.
//
// The DEFAULT is a dry run: nothing leaves this Mac without --upload.

private struct SourceInfo: Decodable {
    var id: String
    var title: String
    var author: String?
    var added: String
    var order: Int?
}

private func contentType(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "html", "htm": return "text/html; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "json": return "application/json"
    case "svg": return "image/svg+xml"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "mp3": return "audio/mpeg"
    case "m4a": return "audio/mp4"
    case "mp4": return "video/mp4"
    case "wasm": return "application/wasm"
    case "txt", "glsl", "frag", "vert": return "text/plain; charset=utf-8"
    case "woff2": return "font/woff2"
    default: return "application/octet-stream"
    }
}

/// The live list, or nil when the server has none yet. Anything else that
/// stops it being read ends the publish.
private func fetchLiveList(_ url: URL) -> HostedInteractive.List? {
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
        die("could not read the live \(HostedInteractive.listName): \(error.localizedDescription). Nothing published.")
    case .success(let (status, data)):
        if status == 404 { return nil }
        guard status == 200 else { die("the live \(HostedInteractive.listName) answered HTTP \(status). Nothing published.") }
        guard let list = try? JSONDecoder().decode(HostedInteractive.List.self, from: data),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawItems = raw["wallpapers"] as? [Any],
              rawItems.count == list.wallpapers.count
        else {
            die("the live \(HostedInteractive.listName) has entries this muro-publish cannot read. Nothing published.")
        }
        return list
    }
}

func publishInteractive(_ arguments: [String]) -> Never {
    var upload = false
    var source: URL?
    for argument in arguments {
        switch argument {
        case "--upload": upload = true
        case "--dry-run": upload = false
        case "--help", "-h":
            print("usage: muro-publish interactive <folder> [--upload]")
            exit(0)
        default:
            if argument.hasPrefix("--") { die("unknown option \(argument)") }
            guard source == nil else { die("one folder only") }
            source = URL(fileURLWithPath: argument, isDirectory: true).resolvingSymlinksInPath()
        }
    }
    guard let source else { die("usage: muro-publish interactive <folder> [--upload]") }
    guard let config = R2Config.load() else { die("no R2 config at \(R2Config.configPath)") }
    guard let base = URL(string: config.publicBaseURL) else { die("publicBaseURL is not a URL") }

    // MARK: Read and check every wallpaper in the folder

    let manager = FileManager.default
    let names = ((try? manager.contentsOfDirectory(atPath: source.path)) ?? [])
        .filter { !$0.hasPrefix(".") }.sorted()
    var local: [(entry: HostedInteractive.Entry, home: URL)] = []
    var problems: [String] = []
    for name in names {
        let home = source.appendingPathComponent(name, isDirectory: true)
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: home.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
        guard let data = try? Data(contentsOf: home.appendingPathComponent(InteractiveWallpapers.infoName)),
              let info = try? JSONDecoder().decode(SourceInfo.self, from: data)
        else {
            problems.append("\(name): no readable \(InteractiveWallpapers.infoName)")
            continue
        }
        var files: [HostedInteractive.File] = []
        let prefix = home.pathComponents.count
        let walker = manager.enumerator(
            at: home, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().pathComponents.dropFirst(prefix).joined(separator: "/")
            if path == InteractiveWallpapers.infoName { continue }
            guard HostedInteractive.isSafePath(path) else {
                problems.append("\(name): file name not allowed (a-z 0-9 . _ - only): \(path)")
                continue
            }
            guard let bytes = try? Data(contentsOf: url) else {
                problems.append("\(name): cannot read \(path)")
                continue
            }
            files.append(.init(path: path, size: Int64(bytes.count), sha256: HostedInteractive.sha256(bytes)))
            let ext = url.pathExtension.lowercased()
            if ["html", "htm", "js", "mjs", "css", "svg"].contains(ext), let text = String(data: bytes, encoding: .utf8) {
                let outside = HostedInteractive.outsideReferences(in: text)
                if !outside.isEmpty {
                    problems.append("\(name)/\(path) reaches outside its folder: \(outside.prefix(6).joined(separator: ", "))")
                }
            }
        }
        files.sort { $0.path < $1.path }
        let entry = HostedInteractive.Entry(
            id: info.id, title: info.title, author: info.author, added: info.added,
            order: info.order, version: HostedInteractive.version(of: files), files: files
        )
        guard HostedInteractive.isUsable(entry) else {
            problems.append("\(name): not publishable (the id must start with \(InteractiveWallpapers.builtInPrefix), and it needs \(HostedInteractive.requiredFiles.joined(separator: ", ")))")
            continue
        }
        local.append((entry, home))
    }
    if !problems.isEmpty { die("nothing published:\n  " + problems.joined(separator: "\n  ")) }
    guard !local.isEmpty else { die("no wallpapers in \(source.path)") }

    // MARK: Merge with what is live

    let listURL = base.appendingPathComponent(HostedInteractive.listName)
    let live = fetchLiveList(listURL)
    if live == nil { print("No \(HostedInteractive.listName) on the server yet: this starts it.") }
    var merged = live?.wallpapers ?? []
    var added: [String] = [], updated: [String] = [], unchanged: [String] = []
    var toUpload: [(entry: HostedInteractive.Entry, home: URL)] = []
    for (incoming, home) in local {
        var entry = incoming
        if let index = merged.firstIndex(where: { $0.id == entry.id }) {
            // The day it first went up stays, whatever the folder says now.
            entry.added = merged[index].added
            if merged[index] == entry {
                unchanged.append(entry.title)
            } else {
                if merged[index].version != entry.version { toUpload.append((entry, home)) }
                merged[index] = entry
                updated.append(entry.title)
            }
        } else {
            merged.append(entry)
            added.append(entry.title)
            toUpload.append((entry, home))
        }
    }
    merged.sort { ($0.order ?? Int.max, $0.title) < ($1.order ?? Int.max, $1.title) }
    let carried = merged.count - local.count

    print("\(merged.count) interactive wallpapers (\(added.count) new, \(updated.count) updated, \(unchanged.count) unchanged, \(carried) carried over)")
    for entry in merged {
        let size = ByteCountFormatter.string(fromByteCount: entry.totalSize, countStyle: .file)
        print("  \(entry.order.map(String.init) ?? "-")  \(entry.title)  by \(entry.author ?? "?")  \(entry.files.count) files, \(size)  v\(entry.version)")
    }
    for (entry, _) in toUpload {
        for file in entry.files {
            print("  upload interactive/\(entry.id)/\(entry.version)/\(file.path)")
        }
    }
    print("  upload \(HostedInteractive.listName)")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let listData = try? encoder.encode(HostedInteractive.List(wallpapers: merged)) else {
        die("could not write the list")
    }
    let localCopy = source.appendingPathComponent(HostedInteractive.listName)

    guard upload else {
        print("Dry run: nothing uploaded. Run again with --upload.")
        exit(0)
    }

    // MARK: Upload: the files first, the list last

    do {
        for (entry, home) in toUpload {
            for file in entry.files {
                try r2Put(
                    file: home.appendingPathComponent(file.path),
                    key: "interactive/\(entry.id)/\(entry.version)/\(file.path)",
                    contentType: contentType(for: file.path),
                    cacheControl: "public, max-age=31536000, immutable",
                    config: config
                )
                print("  sent interactive/\(entry.id)/\(entry.version)/\(file.path)")
            }
        }
        try listData.write(to: localCopy, options: .atomic)
        try r2Put(
            file: localCopy, key: HostedInteractive.listName,
            contentType: "application/json", cacheControl: "public, max-age=60", config: config
        )
        print("  sent \(HostedInteractive.listName)")
    } catch {
        die("upload failed: \(error)")
    }
    print("Live: \(listURL.absoluteString)")
    exit(0)
}

import Foundation

/// One group of release-note lines. `name` is nil for notes written without
/// headings, which is most of them.
public struct ReleaseNoteSection: Sendable, Equatable, Identifiable {
    public var id: String { (name ?? "") + "\(lines.count)" + (lines.first ?? "") }
    public var name: String?
    public var lines: [String]

    public init(name: String?, lines: [String]) {
        self.name = name
        self.lines = lines
    }
}

/// A release as GitHub describes it.
///
/// This is the whole of what the app needs to tell someone a new Muro exists,
/// show them what changed, and hand them the download. It lives in MuroKit so
/// the parsing is tested rather than trusted: the notes are arbitrary text
/// written months from now, and the one thing this must never do is turn a
/// malformed release body into an empty or broken update prompt.
public struct ReleaseInfo: Sendable, Equatable {
    public var version: String
    public var title: String?
    public var page: URL
    /// The `.dmg` asset, when the release has one, so Download is one click
    /// rather than a trip through the releases page.
    public var downloadURL: URL?
    public var publishedAt: Date?
    public var notes: [ReleaseNoteSection]

    public init(
        version: String,
        title: String? = nil,
        page: URL,
        downloadURL: URL? = nil,
        publishedAt: Date? = nil,
        notes: [ReleaseNoteSection] = []
    ) {
        self.version = version
        self.title = title
        self.page = page
        self.downloadURL = downloadURL
        self.publishedAt = publishedAt
        self.notes = notes
    }

    public var isEmpty: Bool { notes.allSatisfy { $0.lines.isEmpty } }

    /// Build from the GitHub releases API payload. Returns nil rather than
    /// throwing: a shape we do not recognise means "no update to show", never
    /// an error in the user's face.
    public static func from(json: [String: Any]) -> ReleaseInfo? {
        guard let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init)
        else { return nil }

        let version = tag.lowercased().hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return nil }

        let assets = json["assets"] as? [[String: Any]] ?? []
        let download = assets
            .first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }

        var published: Date?
        if let raw = json["published_at"] as? String {
            published = ISO8601DateFormatter().date(from: raw)
        }

        // A release name that just repeats what the card already prints in
        // 36pt above it ("v3.0", "3.0", "Muro 3.0") is noise, not a subtitle.
        var title = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = title {
            let redundant = [tag, version, "muro \(version)", "muro \(tag)"]
            if name.isEmpty || redundant.contains(name.lowercased()) { title = nil }
        }

        return ReleaseInfo(
            version: version,
            title: title,
            page: page,
            downloadURL: download,
            publishedAt: published,
            notes: ReleaseNotes.parse(json["body"] as? String ?? "")
        )
    }
}

/// Turns a GitHub release body into something the What's New sheet can lay out.
///
/// Deliberately a small subset of Markdown. Release notes are headings and
/// bullets; anything cleverer is not worth carrying a parser for, and a wrong
/// guess about a rare construct would show the user a mangled line.
public enum ReleaseNotes {
    /// Enough to fill the sheet several times over. A release body has no size
    /// limit and this is drawn in a scroll view on the main thread.
    static let lineLimit = 60

    public static func parse(_ markdown: String) -> [ReleaseNoteSection] {
        var sections: [ReleaseNoteSection] = []
        var name: String?
        var lines: [String] = []
        var total = 0

        func flush() {
            if !lines.isEmpty { sections.append(ReleaseNoteSection(name: name, lines: lines)) }
            lines = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            if total >= lineLimit { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                flush()
                name = clean(line.drop { $0 == "#" })
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                if name?.isEmpty == true { name = nil }
                continue
            }

            // Horizontal rules, images, HTML, and the auto-appended
            // "Full Changelog" footer are chrome, not notes.
            if line.hasPrefix("---") || line.hasPrefix("***") { continue }
            if line.hasPrefix("!") || line.hasPrefix("<") { continue }
            if line.lowercased().contains("full changelog") { continue }

            var text = line
            for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count))
                break
            }
            // Numbered bullets: "1. Something".
            if let dot = text.firstIndex(of: "."),
               text[text.startIndex..<dot].allSatisfy(\.isNumber),
               text.distance(from: text.startIndex, to: dot) <= 2,
               text.index(after: dot) < text.endIndex {
                text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
            }

            let cleaned = clean(text)
            if cleaned.isEmpty { continue }
            lines.append(cleaned)
            total += 1
        }
        flush()
        return sections
    }

    /// Strip the emphasis markers, link syntax and stray backticks that would
    /// otherwise be read out literally in a label.
    private static func clean(_ text: some StringProtocol) -> String {
        var out = String(text)
        // [label](url) -> label
        while let open = out.firstIndex(of: "["),
              let close = out[open...].firstIndex(of: "]"),
              out.index(after: close) < out.endIndex,
              out[out.index(after: close)] == "(",
              let end = out[close...].firstIndex(of: ")") {
            let label = String(out[out.index(after: open)..<close])
            out.replaceSubrange(open...end, with: label)
        }
        out = out.replacingOccurrences(of: "**", with: "")
        out = out.replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(of: "__", with: "")
        return out.trimmingCharacters(in: .whitespaces)
    }
}

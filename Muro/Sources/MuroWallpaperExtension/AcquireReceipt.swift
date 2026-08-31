import Foundation

/// What macOS actually did the last time it asked Muro for a wallpaper.
///
/// The app cannot see inside this process, and it used to confirm a lock-screen
/// apply by re-reading the property list it had just written itself. That check
/// passes whether or not macOS ever came looking, so an apply that macOS
/// quietly ignored still reported success and left no trace anywhere.
///
/// `acquire` is macOS saying it accepted the choice, and a composited first
/// frame is the extension saying it could play it. Writing both down is the
/// only honest evidence the app can wait for.
///
/// One slot, overwritten each acquire. The app only ever asks "did a matching
/// acquire happen after I applied"; the history belongs in `extension.log`.
/// ISO 8601 on purpose: this file gets pasted into bug reports.
struct AcquireReceipt: Codable {
    var id: String
    var at: Date
    var ok: Bool
    var preview: Bool
    var detail: String

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("acquire-receipt.json")
    }

    static func record(id: String?, preview: Bool, ok: Bool, detail: String) {
        let receipt = AcquireReceipt(
            id: id ?? "",
            at: Date(),
            ok: ok,
            preview: preview,
            detail: detail
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(receipt) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

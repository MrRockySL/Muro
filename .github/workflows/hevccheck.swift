import AVFoundation
import Foundation

// The one thing only real Intel hardware can answer. Rosetta on an Apple
// silicon Mac still decodes on the Media Engine, so it never exercises Quick
// Sync. This pulls the live catalog and decodes the same HEVC the app plays.
func run() async throws {
    let catalogURL = URL(string: "https://cdn.murowallpaper.com/catalog.json")!
    let data = try Data(contentsOf: catalogURL)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let items = json["wallpapers"] as! [[String: Any]]

    guard let preview = items.compactMap({ $0["preview720"] as? String }).first,
          let url = URL(string: preview) else {
        print("no preview720 in the catalog"); exit(1)
    }
    print("decoding \(url.lastPathComponent)")

    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first,
          let desc = try await track.load(.formatDescriptions).first else {
        print("no video track"); exit(1)
    }
    let codec = CMFormatDescriptionGetMediaSubType(desc)
    let tag = withUnsafeBytes(of: codec.bigEndian) { String(bytes: $0, encoding: .ascii)! }
    print("codec: \(tag)")
    guard tag == "hvc1" || tag == "hev1" else {
        print("not HEVC, this did not test what we wanted"); exit(1)
    }

    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    let started = Date()
    let image = try gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600),
                                    actualTime: nil)
    let took = Date().timeIntervalSince(started)
    print("decoded \(image.width)x\(image.height) in \(String(format: "%.2f", took))s")
    guard image.width > 0, image.height > 0 else { print("empty frame"); exit(1) }
    print("HEVC decode works here")
}

let done = DispatchSemaphore(value: 0)
Task {
    do { try await run() } catch { print("FAILED: \(error)"); exit(1) }
    done.signal()
}
done.wait()

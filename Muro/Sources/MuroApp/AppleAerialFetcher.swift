import AppKit
import AVFoundation
import MuroKit

/// Takes a sharp picture of each of Apple's aerials and reads its real size,
/// length and resolution, once each, from Apple's own servers.
///
/// **Why.** The still macOS keeps for an aerial is 214 by 130 pixels, and a
/// gallery card is about 420 points wide, which is what made the first version
/// of the page look blurry. Apple has no bigger picture anywhere. So Muro reads
/// one frame out of the real video: the video's index and one keyframe, about
/// 1 to 4 MB and 1 to 3 seconds per aerial, never the whole file. The picture
/// is kept forever (`AppleAerialInfo`), so each aerial costs that once.
///
/// **Only what is looked at.** A card asks when it comes into view, and the
/// newest ask goes first, so the cards on screen sharpen before the ones that
/// scrolled past. Three at a time, which keeps a fast scroll from turning into
/// a hundred requests at once.
///
/// **The same moment as Apple's still.** Apple's still is not the first frame:
/// for New Zealand it is near the end, for Grand Canyon a third of the way in.
/// A sharp picture of a different moment would make every card change its
/// scene a second after it appeared, so a few moments are tried and the one
/// that looks most like Apple's still is kept.
@MainActor
final class AppleAerialFetcher: ObservableObject {
    static let shared = AppleAerialFetcher()

    /// Bumped when a picture or a fact lands, so the gallery and the detail
    /// view look again. A burst of landings redraws once, not once each.
    @Published private(set) var revision = 0

    /// Newest last: `pump` takes from the end.
    private var waiting: [AppleAerial] = []
    private var running: Set<String> = []
    /// Tried and failed in this launch. Tried again next launch, never in a
    /// loop while the network is down.
    private var failed: Set<String> = []
    private var sizesRequested = false
    private var sizesRunning: Set<String> = []
    private var redrawScheduled = false

    /// Six at a time. Three kept a screen of cards blurry for 5 to 10
    /// seconds the first time (owner, 2026-09-30); Apple's servers answer
    /// six small reads at once without slowing any of them.
    private static let maxRunning = 6

    // MARK: - Pictures

    func requestFrame(for aerial: AppleAerial) {
        let id = aerial.assetID
        // Pictures, the ones macOS draws and the screen savers have no video
        // to read a frame from; theirs is the card picture on Muro's server.
        guard aerial.kind == .video || ApplePreviews.isHosted(id),
              !AppleAerialInfo.hasFrame(assetID: id),
              !running.contains(id), !failed.contains(id)
        else { return }
        waiting.removeAll { $0.assetID == id }
        waiting.append(aerial)
        pump()
    }

    /// A card that scrolled away no longer needs to go first. One already
    /// being taken is left to finish, since most of its cost is spent.
    func cancelFrame(for aerial: AppleAerial) {
        waiting.removeAll { $0.assetID == aerial.assetID }
    }

    private func pump() {
        while running.count < Self.maxRunning, let next = waiting.popLast() {
            let id = next.assetID
            guard !AppleAerialInfo.hasFrame(assetID: id) else { continue }
            running.insert(id)
            Task.detached(priority: .utility) {
                let made = await AppleAerialFrame.make(for: next)
                await MainActor.run {
                    self.running.remove(id)
                    if !made { self.failed.insert(id) }
                    self.landed()
                    self.pump()
                }
            }
        }
    }

    /// Something about the pictures changed outside the fetcher, like a
    /// still picture being downloaded. Redraw the same way.
    func noteChanged() { landed() }

    private func landed() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.revision += 1
        }
    }

    // MARK: - Sizes

    /// The real size of every aerial, read once and kept, so the gallery never
    /// shows a guess. 164 small requests that carry no video, a few seconds
    /// in all, and only the first time the page is opened.
    func prefetchSizes(for aerials: [AppleAerial]) {
        guard !sizesRequested else { return }
        sizesRequested = true
        let missing = aerials.filter {
            Self.sizeIsAsked($0)
                && AppleAerialInfo.facts(assetID: $0.assetID, video: $0.videoURL)?.bytes == nil
        }
        readSizes(missing)
    }

    /// One aerial's size, straight away, for the detail view that shows it.
    func ensureSize(for aerial: AppleAerial) {
        guard Self.sizeIsAsked(aerial),
              AppleAerialInfo.facts(assetID: aerial.assetID, video: aerial.videoURL)?.bytes == nil
        else { return }
        readSizes([aerial])
    }

    /// Only a video on Apple's servers has a size to ask for. One already on
    /// the Mac is measured on disk, and a picture's size comes with it.
    private static func sizeIsAsked(_ aerial: AppleAerial) -> Bool {
        aerial.kind == .video && !aerial.isDownloaded
            && ["http", "https"].contains(aerial.videoURL.scheme ?? "")
    }

    private func readSizes(_ aerials: [AppleAerial]) {
        let todo = aerials.filter { !sizesRunning.contains($0.assetID) }
        guard !todo.isEmpty else { return }
        sizesRunning.formUnion(todo.map(\.assetID))
        Task.detached(priority: .utility) {
            let learned = await AppleAerialSizes.read(todo)
            AppleAerialInfo.record(learned)
            await MainActor.run {
                self.sizesRunning.subtract(todo.map(\.assetID))
                self.landed()
            }
        }
    }
}

// MARK: - Reading sizes

/// The size of each video, from the length Apple's server reports. A HEAD
/// request carries no video, so this is a few kilobytes for all 164.
enum AppleAerialSizes {
    static func read(_ aerials: [AppleAerial]) async -> [String: AppleAerialInfo.Facts] {
        var learned: [String: AppleAerialInfo.Facts] = [:]
        await withTaskGroup(of: (String, AppleAerialInfo.Facts?).self) { group in
            var queue = aerials[...]
            // Eight in flight is quick and polite to a server that is not ours.
            for _ in 0..<min(8, queue.count) {
                guard let aerial = queue.popFirst() else { break }
                group.addTask { (aerial.assetID, await size(of: aerial)) }
            }
            for await (id, facts) in group {
                if let facts { learned[id] = facts }
                if let aerial = queue.popFirst() {
                    group.addTask { (aerial.assetID, await size(of: aerial)) }
                }
            }
        }
        return learned
    }

    private static func size(of aerial: AppleAerial) async -> AppleAerialInfo.Facts? {
        var request = URLRequest(url: aerial.videoURL, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.expectedContentLength > 0
        else { return nil }
        return AppleAerialInfo.Facts(
            video: aerial.videoURL.absoluteString, bytes: http.expectedContentLength
        )
    }
}

// MARK: - Taking the picture

enum AppleAerialFrame {
    /// The moments tried, as parts of the video's length. Apple's still was
    /// found near each of these on the aerials measured on 2026-09-30.
    ///
    /// Four at most. Eight made a card that matched none of them cost about
    /// 7 MB and 3 seconds; four keep the worst case near 3 MB, and the best of
    /// them is still the one kept.
    private static let moments: [Double] = [0, 0.5, 0.9, 0.3]
    /// Closer than this to Apple's still is the same moment: 2 to 10 for the
    /// ones that matched, 20 and up for a different one.
    private static let sameMoment = 18.0
    /// A whole aerial's picture may not take longer than this. The network
    /// can hang without failing, and a card must not wait on it forever.
    private static let timeout: Double = 60

    /// Takes the picture and saves it, with what the video's header says.
    /// False when it could not, so the card keeps Apple's still for now.
    static func make(for aerial: AppleAerial) async -> Bool {
        if aerial.kind != .video {
            let made = await ApplePreviews.fetchCardPicture(assetID: aerial.assetID)
            if made {
                _ = ImageCache.load(
                    path: AppleAerialInfo.framePath(assetID: aerial.assetID),
                    maxPixels: ImageCache.gridPixels)
            }
            return made
        }
        return await withTimeout(timeout) { await take(aerial) } ?? false
    }

    private static func take(_ aerial: AppleAerial) async -> Bool {
        // Downloaded ones are read from the file, which costs nothing.
        let source = aerial.playablePath.map { URL(fileURLWithPath: $0) } ?? aerial.videoURL
        let asset = AVURLAsset(url: source)

        let duration: Double
        do {
            let length = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return false
            }
            let (natural, transform, rate) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate
            )
            let shown = natural.applying(transform)
            duration = length.seconds.isFinite ? length.seconds : 0
            AppleAerialInfo.record(AppleAerialInfo.Facts(
                video: aerial.videoURL.absoluteString,
                duration: duration > 0 ? duration : nil,
                width: Int(abs(shown.width).rounded()),
                height: Int(abs(shown.height).rounded()),
                fps: rate > 0 ? Double(rate).rounded() : nil
            ), assetID: aerial.assetID)
        } catch {
            return false
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        // The nearest keyframe, not the exact moment. An exact frame at 240 fps
        // means decoding up to a second of video to reach it, and over the
        // network, fetching it.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let reference = aerial.stillMatchesVideo
            ? aerial.thumbnailPath.flatMap(FrameSignature.init(path:))
            : nil
        var best: (image: CGImage, score: Double)?
        for moment in moments {
            let time = CMTime(seconds: duration * moment, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image,
                  let signature = FrameSignature(image)
            else { continue }
            // With Apple's still, closest to it. Without one, the brighter the
            // better: some aerials open on black.
            let score = reference.map { $0.distance(to: signature) }
                ?? max(0, 80 - signature.meanLuma)
            if best == nil || score < best!.score { best = (image, score) }
            if score < sameMoment || (reference == nil && score == 0) { break }
        }
        guard let best else { return false }

        let rep = NSBitmapImageRep(cgImage: best.image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return false }
        let destination = URL(fileURLWithPath: AppleAerialInfo.framePath(assetID: aerial.assetID))
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try jpeg.write(to: destination, options: .atomic)
        } catch {
            return false
        }
        // Decoded at card size before the cards hear about it, so each one
        // swaps to the sharp picture in the frame it redraws, with no gap.
        _ = ImageCache.load(path: destination.path, maxPixels: ImageCache.gridPixels)
        return true
    }
}

/// A picture shrunk to 24 by 16, for telling whether two pictures show the
/// same moment. Colour and layout survive at that size; detail does not, which
/// is the point, since one of the two is Apple's blurry still.
struct FrameSignature {
    private static let width = 24, height = 16
    private let rgb: [UInt8]

    init?(_ image: CGImage) {
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        let made: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: Self.width, height: Self.height,
                bitsPerComponent: 8, bytesPerRow: Self.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            // Filled and centred, the way a card shows it.
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let scale = max(CGFloat(Self.width) / width, CGFloat(Self.height) / height)
            let drawn = CGSize(width: width * scale, height: height * scale)
            context.draw(image, in: CGRect(
                x: (CGFloat(Self.width) - drawn.width) / 2,
                y: (CGFloat(Self.height) - drawn.height) / 2,
                width: drawn.width, height: drawn.height
            ))
            return true
        }
        guard made else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(Self.width * Self.height * 3)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            out.append(pixels[index])
            out.append(pixels[index + 1])
            out.append(pixels[index + 2])
        }
        rgb = out
    }

    init?(path: String) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self.init(image)
    }

    /// The average difference per colour channel, 0 to 255.
    func distance(to other: FrameSignature) -> Double {
        var total = 0
        for index in rgb.indices { total += abs(Int(rgb[index]) - Int(other.rgb[index])) }
        return Double(total) / Double(rgb.count)
    }

    var meanLuma: Double {
        var total = 0.0
        for index in stride(from: 0, to: rgb.count, by: 3) {
            total += 0.299 * Double(rgb[index]) + 0.587 * Double(rgb[index + 1])
                + 0.114 * Double(rgb[index + 2])
        }
        return total / Double(rgb.count / 3)
    }
}

/// Runs `work`, and gives up on it after `seconds`. The work is cancelled but
/// not waited for: AVFoundation does not always stop when asked, and the
/// caller must not be held by a download that hung.
func withTimeout<T: Sendable>(
    _ seconds: Double,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let settled = SettledFlag()
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let task = Task {
            let result = await work()
            if settled.claim() { continuation.resume(returning: result) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if settled.claim() {
                task.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

/// True for the first caller only.
private final class SettledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }
}

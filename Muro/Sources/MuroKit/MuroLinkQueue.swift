import Foundation

/// Where `muro://` links wait their turn.
///
/// A link is carried out alone: the one before it has finished before it
/// starts, and links run in the order they came. Two reasons.
///
/// Setting a lock screen or a screen saver takes a few seconds and ends by
/// saving a record. Two of them at once each saved the record the other had
/// not finished writing, so two links sent together left Muro believing one
/// display still had its old lock screen.
///
/// And the order is what the sender meant. `set` followed by `pause` has to
/// end paused, also when both arrive while Muro is still starting.
///
/// Any web page can send links, so the line has an end. A link that finds it
/// full is turned away, and one that repeats the link in front of it is
/// dropped, since carrying out the same link twice in a row changes nothing.
@MainActor
public final class MuroLinkQueue<Link: Equatable> {
    public enum Answer: Equatable {
        /// In the line.
        case taken
        /// The same link is already the last one waiting.
        case alreadyWaiting
        /// Too many are waiting.
        case full
    }

    /// How many links may wait. The one being carried out is not counted.
    public let limit: Int

    private let carryOut: @MainActor (Link) async -> Void
    private var waiting: [Link] = []
    private var started = false
    private var busy = false

    public init(limit: Int, carryOut: @escaping @MainActor (Link) async -> Void) {
        self.limit = limit
        self.carryOut = carryOut
    }

    /// Nothing is carried out before this. Muro calls it once it has
    /// started, so links that came while it was starting keep their order.
    public func start() {
        started = true
        next()
    }

    @discardableResult
    public func add(_ link: Link) -> Answer {
        if waiting.last == link { return .alreadyWaiting }
        guard waiting.count < limit else { return .full }
        waiting.append(link)
        next()
        return .taken
    }

    /// Nothing waiting and nothing being carried out.
    public var isEmpty: Bool { waiting.isEmpty && !busy }

    private func next() {
        guard started, !busy, !waiting.isEmpty else { return }
        busy = true
        let link = waiting.removeFirst()
        Task { @MainActor in
            await carryOut(link)
            busy = false
            next()
        }
    }
}

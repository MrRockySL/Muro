import SwiftUI
import MuroKit

struct MenuBarView: View {
    @EnvironmentObject var store: AppStore

    private var currentItem: WallpaperItem? {
        store.currentAppliedID.flatMap { store.item(id: $0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            transport
            speedRow
            if !store.recentItems.isEmpty { recents }
            placesSection
            Rectangle().fill(Color.muroInk.opacity(0.08)).frame(height: 1)
            menuButtons
        }
        .padding(16)
        .frame(width: 306)
        // The update row is reset by `StatusBarController.openPanel`, not from
        // here. This view is built once and reused, so an `onAppear` fires on
        // the first open of the panel and never again.
        //
        // No background here: StatusBarController hosts this in a fully
        // transparent panel whose container draws the single rounded
        // dark-glass card (blur + wash + border).
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        VStack(spacing: 6) {
            if let item = currentItem {
                ZStack(alignment: .bottomLeading) {
                    Color.black
                        .frame(height: 122)
                        .overlay(ThumbImage(item: item))
                        .clipped()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .center, endPoint: .bottom
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.muroInk)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(store.isPaused || store.desktopResting ? Color.muroSecondary : Color.muroGreen)
                                .frame(width: 5, height: 5)
                            Text(statusLine(item))
                                .font(.system(size: 8.5, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(Color.muroInk.opacity(0.75))
                        }
                    }
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("No wallpaper applied")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 70)
                    .glass(cornerRadius: 12)
            }
            if let version = store.latestRelease?.version {
                Button {
                    openWhatsNew(store)
                } label: {
                    HStack(spacing: 5) {
                        NotificationDot(size: 6)
                        Text("Muro \(version) available")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.muroAccent)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text("Version \(AppStore.appVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.muroSecondary)
            }
        }
    }

    private func statusLine(_ item: WallpaperItem) -> String {
        let displays = store.appliedDisplays(for: item.id).count
        let state = store.isPaused || store.desktopResting ? "PAUSED" : "PLAYING"
        // Look up the mode on a display actually showing this wallpaper —
        // the bare all-displays entry can be stale after per-display applies.
        let mode = store.displays
            .compactMap { store.config.assignment(forDisplayUUID: $0.id) }
            .first { $0.wallpaperID == item.id }?.mode
        let fps = mode == "efficient" ? 30 : standardFrameRate(item.fps)
        let base = "\(state) · \(displays) DISPLAY\(displays == 1 ? "" : "S") · \(fps) FPS"
        // While something is scheduling the wallpaper, its name matters more
        // than the frame rate does.
        if let schedule = store.runningScheduleName {
            return "\(state) · \(schedule.uppercased())"
        }
        return base
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 10) {
            transportButton("arrow.clockwise", enabled: currentItem != nil) {
                store.reapply()
            }
            transportButton("backward.end.fill", enabled: store.activePlaylist != nil) {
                store.advancePlaylist(forward: false)
            }
            Button {
                // Resting under Pause After is not a pause the person made, so
                // play starts it moving again rather than pausing it harder.
                if store.desktopResting, !store.isPaused {
                    store.replayDesktop?()
                } else {
                    store.setPaused(!store.isPaused)
                }
            } label: {
                Image(systemName: store.isPaused || store.desktopResting ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.muroOnInk)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.muroInk))
            }
            .buttonStyle(.plain)
            .disabled(currentItem == nil)
            transportButton("forward.end.fill", enabled: store.activePlaylist != nil) {
                store.advancePlaylist(forward: true)
            }
            transportButton("shuffle", enabled: store.activePlaylist != nil, active: store.activePlaylist?.shuffle == true) {
                if var playlist = store.activePlaylist {
                    playlist.shuffle.toggle()
                    store.updatePlaylist(playlist)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        _ systemName: String, enabled: Bool, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.muroAccent : Color.muroInk)
                .frame(width: 34, height: 34)
                .glassCapsule(fill: 0.08, stroke: 0.14)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: - Speed

    private var speedRow: some View {
        HStack(spacing: 2) {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5], id: \.self) { speed in
                let selected = abs(store.playbackSpeed - speed) < 0.01
                Text(speedLabel(speed))
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selected ? Color.muroOnInk : Color.muroInk.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background { if selected { Capsule().fill(Color.muroInk) } }
                    .contentShape(Capsule())
                    .onTapGesture { store.setPlaybackSpeed(speed) }
            }
        }
        .padding(3)
        .glassCapsule(fill: 0.07, stroke: 0.12)
    }

    // MARK: - Recents

    /// Recents in view at once. Four of 64 points with 6 between them fill
    /// the panel's 274 exactly; with 8 between them the row was wider than
    /// the panel and sat 3 points left of everything else.
    private static let recentsShown = 4

    /// A thumbnail and the gap after it.
    private static let recentsStride: CGFloat = 64 + 6

    @StateObject private var recentsScroller = RowScroller(stride: MenuBarView.recentsStride)
    @State private var hoveringRecents = false

    /// Every recent Muro keeps, not only the first four (issue #55). The row
    /// scrolls with a swipe, and while the pointer is on it arrows float over
    /// the ends that have more, the way the heart floats over a card. It goes
    /// back to the newest when the panel opens or a wallpaper is applied.
    private var recents: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RECENTS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.muroAccent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.recentItems) { item in
                        Color.black
                            .frame(width: 64, height: 38)
                            .overlay(ThumbImage(item: item))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.muroInk.opacity(0.12), lineWidth: 1)
                            )
                            .onTapGesture {
                                store.setWallpaper(item, mode: store.defaultMode(for: item))
                            }
                    }
                }
                .background(RowScrollerProbe(scroller: recentsScroller))
            }
            .frame(height: 38)
            .overlay(alignment: .leading) {
                if hoveringRecents, recentsScroller.canGoBack {
                    recentsArrow("chevron.left") { pageRecents(-1) }
                }
            }
            .overlay(alignment: .trailing) {
                if hoveringRecents, recentsScroller.canGoForward {
                    recentsArrow("chevron.right") { pageRecents(1) }
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: hoveringRecents)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: recentsScroller.canGoBack)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: recentsScroller.canGoForward)
            .onHover { hoveringRecents = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: store.recentIDs) { recentsScroller.scroll(to: 0, animated: false) }
        .onReceive(NotificationCenter.default.publisher(for: .muroMenuBarPanelOpening)) { _ in
            recentsScroller.scroll(to: 0, animated: false)
            // A panel closed under the pointer never heard it leave.
            hoveringRecents = false
        }
    }

    /// The next four along, lined up on a thumbnail, never past either end.
    private func pageRecents(_ direction: Int) {
        let current = (recentsScroller.offset / Self.recentsStride).rounded()
        let target = current + CGFloat(direction * Self.recentsShown)
        recentsScroller.scroll(to: target * Self.recentsStride, animated: true)
    }

    /// The heart's black wash and white glyph, smaller, so it reads on any
    /// thumbnail, the bright ones included.
    private func recentsArrow(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .transition(.scale(scale: 0.82).combined(with: .opacity))
    }

    // MARK: - Playlists & Automations

    /// One row per place, each playing a playlist or an automation of its own.
    /// The title says what the rows are for, because with nothing made yet
    /// every row reads Off.
    private var placesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PLAYLISTS & AUTOMATIONS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.muroAccent)
            VStack(spacing: 6) {
                ForEach(store.schedulePlaces) { place in
                    placeRow(place)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The place (Desktop, Lock screen, Screen saver) is always named in full;
    /// the playlist or automation it plays may be cut short with "...". The
    /// name's capped width used to squeeze the place instead, so a row read
    /// "Screen s..." (owner, 2026-10-05: the name can be cut, the place never).
    private func placeRow(_ place: SchedulePlace) -> some View {
        HStack {
            PlaceGlyph(place: place, size: 15)
                .opacity(0.85)
                .frame(width: 16)
            Text(place.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.muroInk)
                .fixedSize()
            Spacer()
            GlassDropdown(width: 230, arrowEdge: .bottom, options: { store.placeMenu(for: place) }) {
                HStack(spacing: 4) {
                    Text(store.nowPlayingName(on: place) ?? "Off")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(
                            store.nowPlaying[place] != nil ? Color.muroAccent : Color.muroSecondary
                        )
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.muroSecondary)
                }
                .frame(maxWidth: 150, alignment: .trailing)
            }
            // the room the place's name leaves, before the spacer takes any
            .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glass(cornerRadius: 12, fill: 0.06, stroke: 0.1)
    }

    // MARK: - Bottom menu

    private var menuButtons: some View {
        VStack(spacing: 2) {
            menuRow("Open Muro", icon: "macwindow") {
                StatusBarController.shared?.closePanel()
                showMainWindow()
            }
            menuRow("Settings", icon: "gearshape") {
                StatusBarController.shared?.closePanel()
                openSettingsWindow()
            }
            updateRow
            menuRow("Quit Muro", icon: "power", trailingText: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
    }

    /// Leading icons, so these read as part of the same panel as the Playlists
    /// and Automations rows above them rather than as a plain text list
    /// bolted underneath. Same size and opacity as those two use.
    private func menuRow(
        _ title: String, icon: String, badge: String? = nil,
        trailing: String? = nil, trailingText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muroInk.opacity(0.85))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.muroInk)
                    .fixedSize()
                Spacer(minLength: 6)
                if let badge {
                    // The accent capsule the app already uses for a count or a
                    // state, rather than a new shape invented for this. Small
                    // and tinted rather than solid: it is a flag saying there
                    // is something to find, not the action itself. Pressing
                    // the row is still what finds it.
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.muroAccent)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.muroAccent.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.30), lineWidth: 1))
                }
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.muroInk.opacity(0.8))
                }
                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.muroSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: - Update

    /// One row that answers rather than one that just does something.
    ///
    /// The whole point of pressing "Check for Updates" is to be told, so this
    /// row says what happened in place: checking, up to date, could not reach
    /// GitHub, or a version with a Download beside it. It shares
    /// `store.updateCheck` with the same button in Settings, so a check made
    /// in one is not forgotten by the other.
    @ViewBuilder private var updateRow: some View {
        switch store.updateCheck {
        case .idle:
            // The badge is read from `latestRelease`, not from this button
            // ever having been pressed. Muro already asks GitHub every six
            // hours and that check is silent, so without the badge the panel
            // would sit there offering a check while the app privately knew a
            // new version was out. The row still offers the check, because
            // being told is the point of pressing it.
            menuRow(
                "Check for Updates",
                icon: "arrow.triangle.2.circlepath",
                badge: store.latestRelease != nil ? "New Update Available" : nil
            ) {
                Task { await store.checkForUpdates(userInitiated: true) }
            }
        case .checking:
            updateStatusRow(icon: "arrow.triangle.2.circlepath", title: "Checking…") {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 16, height: 16)
            }
        case .upToDate:
            updateStatusRow(icon: "checkmark.circle", title: "Muro is up to date") {
                Text("v\(AppStore.appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.muroSecondary)
            }
        case .failed:
            // Tappable, because the usual reason is a network that has since
            // come back and the fix is to press it again.
            menuRow("Could not check. Try again", icon: "exclamationmark.triangle") {
                Task { await store.checkForUpdates(userInitiated: true) }
            }
        case let .available(version, _):
            downloadRow(version: version)
        }
    }

    /// The one row in this panel worth a second of attention, so it gets a
    /// filled accent pill rather than accent-coloured text. The whole row is
    /// the button; the pill is the affordance, not a separate target.
    private func downloadRow(version: String) -> some View {
        Button {
            StatusBarController.shared?.closePanel()
            store.downloadUpdate()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muroAccent)
                    .frame(width: 16)
                Text("Muro \(version) is available")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.muroInk)
                Spacer()
                Text("Download")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.muroOnAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.muroAccent))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    /// A row that reports instead of acting. Same shape as `menuRow`, without
    /// the button, so a state that is not tappable does not look tappable.
    private func updateStatusRow<Trailing: View>(
        icon: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.muroInk.opacity(0.85))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muroSecondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.muroInk.opacity(configuration.isPressed ? 0.12 : 0))
            )
    }
}

/// The recents row's own `NSScrollView`, read and moved directly.
///
/// SwiftUI tells a view where its scroll view is only from macOS 15 on, and
/// Muro runs on 14, where a geometry reader never hears the clip view move
/// (Home found the same). So the arrows ask the clip view whether there is
/// more either way, the way Home's banner watcher and the glass scroller do,
/// and move it themselves.
@MainActor
final class RowScroller: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    fileprivate weak var scrollView: NSScrollView?
    /// What a swipe settles on when it ends: a whole thumbnail, never half of
    /// one at either edge.
    let stride: CGFloat

    init(stride: CGFloat) {
        self.stride = stride
    }

    /// How far the row is scrolled, in points from its start.
    var offset: CGFloat { scrollView?.contentView.bounds.origin.x ?? 0 }

    private var maximum: CGFloat {
        guard let scrollView else { return 0 }
        let content = scrollView.documentView?.frame.width ?? 0
        return max(0, content - scrollView.contentView.bounds.width)
    }

    /// Moves to `x` points from the start, kept inside the row.
    func scroll(to x: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let target = NSPoint(x: min(max(x, 0), maximum), y: clip.bounds.origin.y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    scrollView.reflectScrolledClipView(clip)
                    self?.update()
                }
            }
        } else {
            clip.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clip)
            update()
        }
    }

    fileprivate func update() {
        let back = offset > 1
        let forward = offset < maximum - 1
        if back != canGoBack { canGoBack = back }
        if forward != canGoForward { canGoForward = forward }
    }

    fileprivate func settle() {
        let aligned = (offset / stride).rounded() * stride
        guard abs(aligned - offset) > 0.5 else { return }
        scroll(to: aligned, animated: true)
    }
}

/// Finds the `NSScrollView` around it for a `RowScroller`, and tells it when
/// the row moves, changes length or comes to rest after a swipe. A probe,
/// never a surface: it takes no clicks.
private struct RowScrollerProbe: NSViewRepresentable {
    let scroller: RowScroller

    func makeNSView(context: Context) -> Probe { Probe(scroller: scroller) }

    func updateNSView(_ nsView: Probe, context: Context) {
        scroller.update()
    }

    final class Probe: NSView {
        let scroller: RowScroller
        private var observers: [NSObjectProtocol] = []

        init(scroller: RowScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observers.isEmpty, window != nil else { return }
            var view = superview
            while let current = view {
                if let scrollView = current as? NSScrollView {
                    scroller.scrollView = scrollView
                    let clip = scrollView.contentView
                    clip.postsBoundsChangedNotifications = true
                    observers.append(NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.scroller.update() } })
                    observers.append(NotificationCenter.default.addObserver(
                        forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.scroller.settle() } })
                    if let document = scrollView.documentView {
                        document.postsFrameChangedNotifications = true
                        observers.append(NotificationCenter.default.addObserver(
                            forName: NSView.frameDidChangeNotification, object: document, queue: .main
                        ) { [weak self] _ in MainActor.assumeIsolated { self?.scroller.update() } })
                    }
                    scroller.update()
                    return
                }
                view = current.superview
            }
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}


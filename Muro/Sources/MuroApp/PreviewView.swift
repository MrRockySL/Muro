import SwiftUI
import MuroKit

/// Fetches the p720 preview loop for the detail view (cache-first). Tiny
/// files, so a full download-then-play beats progressive streaming: simpler,
/// loops seamlessly, and lands in the LRU cache for next time.
@MainActor
final class PreviewLoader: ObservableObject {
    enum State: Equatable { case idle, loading, ready(URL), failed }
    @Published var state: State = .idle
    private var currentID: String?

    func load(id: String, from remote: URL?) {
        guard currentID != id else { return }
        currentID = id
        guard let remote else { state = .idle; return }
        if let hit = PreviewCache.cachedURL(id: id) {
            state = .ready(hit)
            return
        }
        state = .loading
        Task { [weak self] in
            do {
                let url = try await PreviewCache.fetch(id: id, from: remote)
                guard let self, self.currentID == id else { return }
                self.state = .ready(url)
            } catch {
                guard let self, self.currentID == id else { return }
                self.state = .failed
            }
        }
    }
}

/// Full-window wallpaper preview with the floating glass pill bar and the
/// choose-display popover. Covers everything including the top bar.
struct PreviewView: View {
    @EnvironmentObject var store: AppStore
    let itemID: String

    @State private var showDisplayPopover = false
    @State private var customPauseAfter = false
    @StateObject private var loader = PreviewLoader()

    /// Live item — refreshes as downloads/likes/manifest change.
    private var item: WallpaperItem? { store.item(id: itemID) }

    var body: some View {
        if let item {
            ZStack(alignment: .bottom) {
                media(item)
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .center, endPoint: .bottom
                )
                .allowsHitTesting(false)
                pillBar(item)
                    .padding(.bottom, 26)
            }
            .ignoresSafeArea()
            .background(Color.muroBG)
        }
    }

    @ViewBuilder private func media(_ item: WallpaperItem) -> some View {
        GeometryReader { proxy in
            Group {
                if let url = store.videoURL(for: item, mode: store.previewMode) ??
                             store.videoURL(for: item, mode: "smooth") {
                    // Downloaded → the real master, full quality.
                    LoopingPlayerView(url: url)
                } else if item.id == BundledWallpaper.id,
                          let url = BundledWallpaper.videoURL {
                    // The bundled 4K is already on disk — never show it soft.
                    LoopingPlayerView(url: url)
                } else {
                    // Not downloaded → thumbnail immediately, p720 loop once
                    // fetched. Deliberately soft: it shows the motion while
                    // leaving a reason to pull the 4K master.
                    remotePreview(item)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    @ViewBuilder private func remotePreview(_ item: WallpaperItem) -> some View {
        ZStack {
            // Fills the whole window behind the loading p720, so it needs the
            // full-size decode rather than the grid-card one.
            ThumbImage(item: item, maxPixels: ImageCache.fullPixels)
            if case .ready(let url) = loader.state {
                LoopingPlayerView(url: url)
                    .transition(.opacity)
            } else if loader.state == .loading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.35)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: loader.state)
        .onAppear { loader.load(id: item.id, from: item.remote?.preview720) }
        .onChange(of: item.id) { _, _ in
            loader.load(id: item.id, from: item.remote?.preview720)
        }
    }

    // MARK: - Pill bar

    private func pillBar(_ item: WallpaperItem) -> some View {
        HStack(spacing: 14) {
            backButton
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(item.width)×\(item.height) · \(formatSize(item.sizeBytes)) · \(formatDuration(item.duration))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)

            if let url = store.videoURL(for: item, mode: "smooth") {
                ShareLink(item: url) {
                    // The forward arrow, not the box with an arrow out of it.
                    // The box is the system default and reads as generic
                    // chrome; this is the share glyph messaging apps settled
                    // on, and it is what the owner asked for (2026-08-30).
                    //
                    // Measured by the offscreen ink-bounds render used for the
                    // other bar icons: this glyph sits 0.4pt high in a 40pt
                    // circle, so it is pushed back down by that much.
                    barIcon("arrowshape.turn.up.right.fill", opticalYOffset: 0.4)
                }
                .buttonStyle(.plain)
            }

            if item.fps > 40 {
                fpsToggle(item)
            }

            if item.isDownloaded { pauseAfterPill(item) }

            HeartButton(item: item, size: 40)

            setButton(item)
                // Drawn in the window like every other menu, not in a popover.
                // A popover paints its own square grey sheet behind whatever
                // it is given, which is what made this the one panel in the
                // app that was a flat dark box (owner, 2026-08-24).
                .anchoredCard(isPresented: $showDisplayPopover, width: 340, align: .trailing) {
                    ChooseDisplayPopover(item: item)
                        .environmentObject(store)
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.9))
        )
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var backButton: some View {
        Button {
            store.previewItem = nil
        } label: {
            barIcon("chevron.left")
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    /// `opticalYOffset` nudges glyphs whose visual weight sits off the
    /// font-metric center (e.g. share's arrow) so they look centered.
    private func barIcon(_ systemName: String, opticalYOffset: CGFloat = 0) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .offset(y: opticalYOffset)
        }
        .frame(width: 40, height: 40)
    }

    // MARK: - Smooth / Efficient toggle

    private func fpsToggle(_ item: WallpaperItem) -> some View {
        HStack(spacing: 2) {
            fpsSegment("\(Int(item.fps))", mode: "smooth", hint: "Higher CPU")
            fpsSegment("30", mode: "efficient", hint: "Lower CPU")
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    private func fpsSegment(_ label: String, mode: String, hint: String) -> some View {
        let selected = store.previewMode == mode
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background { if selected { Capsule().fill(Color.white) } }
            .contentShape(Capsule())
            .onTapGesture { store.previewMode = mode }
            .help("\(label) fps · \(hint)")
    }

    // MARK: - Pause after (per wallpaper)

    /// The per wallpaper half of issue #3: one wallpaper can settle after ten
    /// seconds while everything else keeps playing. It shows the value in
    /// force either way, and says when that value is coming from Settings.
    private func pauseAfterPill(_ item: WallpaperItem) -> some View {
        let value = store.effectivePauseAfter(for: item)
        let overridden = store.hasPauseAfterOverride(item)
        // Shorter than the list in Settings on purpose: this menu opens over
        // the wallpaper itself, and any other time is one step away under
        // Custom. 0 is Never pause.
        let choices = [0, 10, 30, 60, 300, 3600]
        // Centred on the pill: it sits in the middle of the bottom bar, so a
        // menu hanging off either edge of it looks like a mistake.
        return GlassDropdown(width: 190, arrowEdge: .top, align: .center, options: {
            [MenuOption(title: "Use setting (\(SettingsView.pauseAfterLabel(store.pauseAfterSeconds)))",
                        checked: !overridden) {
                store.setPauseAfter(nil, for: item)
            }, .divider]
            + choices.map { seconds in
                MenuOption(
                    title: seconds == 0 ? "Never pause" : durationLabel(seconds),
                    checked: overridden && value == seconds
                ) { store.setPauseAfter(seconds == 0 ? -1 : seconds, for: item) }
            }
            // The list stops at an hour. Anything else this wallpaper wants
            // is set here, the same way Settings does it. Custom carries the
            // tick whenever the time is not one of the list's, which includes
            // a 2 or 15 minute time picked before the list was shortened.
            + [.divider, MenuOption(
                title: "Custom",
                checked: overridden && value > 0 && !choices.contains(value)
            ) { customPauseAfter = true }]
        }) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(overridden ? Color.muroAccent : .white.opacity(0.75))
                Text(value == 0 ? "Off" : durationLabel(value))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(overridden ? Color.muroAccent : .white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(
                overridden ? Color.muroAccent.opacity(0.4) : Color.white.opacity(0.14),
                lineWidth: 1
            ))
        }
        .anchoredCard(isPresented: $customPauseAfter, width: 300, align: .center) {
            CustomDurationPicker(seconds: Binding(
                get: { max(10, store.effectivePauseAfter(for: item)) },
                set: { store.setPauseAfter($0, for: item) }
            )) { customPauseAfter = false }
        }
        .help("Pause after: how long this wallpaper moves before holding on a frame")
    }

    // MARK: - Download / Set Wallpaper

    @ViewBuilder private func setButton(_ item: WallpaperItem) -> some View {
        if let progress = store.downloads[item.id] {
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 70)
                Text("\(Int(progress * 100))% of \(formatSize(item.sizeBytes))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        } else if !item.isDownloaded {
            // Preview and Download are ONE action wearing two words — both
            // pull the master. "Preview" is the smaller ask, and once someone
            // has seen the 4K they apply it; the deliberately soft p720
            // behind these buttons is what creates that appetite. Labels stay
            // plain (owner, 2026-07-19): the size already sits in the
            // subtitle, and the progress capsule shows "% of NN MB".
            HStack(spacing: 10) {
                glassButton("Download", systemName: "arrow.down") {
                    store.download(item)
                }
                capsuleButton("Preview", systemName: "play.fill") {
                    store.download(item)
                }
            }
        } else if store.generating.contains(item.id) {
            Text("Preparing 30 fps…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        } else if store.applyingLockScreen {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Setting lock screen…")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        } else if store.isApplied(item, surface: store.applySurface, target: .all) {
            Button {
                showDisplayPopover.toggle()   // re-target / change display
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    // Named in full here. The chip on a card has a corner to
                    // fit into and has to abbreviate; this bar has the room,
                    // and with four places a wallpaper can be in, which one it
                    // is in is the answer someone opened this for.
                    Text(store.appliedFullLabel(for: item.id) ?? "Applied")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.muroGreen)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.muroGreen.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else {
            capsuleButton("Set Wallpaper", systemName: nil) {
                showDisplayPopover.toggle()
            }
        }
    }

    private func capsuleButton(_ title: String, systemName: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.black)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }

    /// Secondary capsule, same shape as the primary but glass instead of
    /// solid white — for the quieter twin of a two-button pair.
    private func glassButton(_ title: String, systemName: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 11, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Choose display popover

/// Anchored above the Set Wallpaper button. Clicking "All" or a display
/// card is what actually applies the wallpaper; displays already showing
/// it get a green dot. Works with any number of connected displays.
struct ChooseDisplayPopover: View {
    /// Every button in this popover is exactly this size: the cards in the
    /// grid, a lone display's card, and the screen saver's All Screens card.
    /// They used to be three different widths, and an applied card grew taller
    /// than an unapplied one because a Remove pill is bigger than a line of
    /// grey text, so the whole popover moved when you applied a wallpaper
    /// (owner, 2026-09-10: "all the display buttons have to be the same size,
    /// 100% the same size").
    static let cardWidth: CGFloat = 148
    static let cardHeight: CGFloat = 88
    static let cardGap: CGFloat = 10
    /// Two cards across is what sets the card's width, and the tab row has to
    /// fit inside the same space. Measured with the real font at 11.5
    /// semibold: the four labels are 288pt of text and padding at 11, plus
    /// three gaps, against the 310pt these cards leave. See the tab row.
    static let pillPadding: CGFloat = 11
    static let pillGap: CGFloat = 3
    /// One animation for the whole popover, so the tab pill, the crossfade and
    /// a card turning green all move together instead of at three speeds.
    static let ease = Animation.spring(response: 0.34, dampingFraction: 0.86)

    @EnvironmentObject var store: AppStore
    let item: WallpaperItem
    @Namespace private var surfaceNS
    /// Shown when someone on macOS 14 or 15 picks Lockscreen or Both. The
    /// pills used to be simply disabled with a small "26+" badge, which says
    /// there is a rule without ever saying what it is.
    @State private var showLockRequirement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // No Spacers. A `Spacer` carries a default minimum length of its
            // own, and two of them plus the extra gaps added 22pt to a row
            // that had 13pt of room, which is what wrapped "Lockscreen" onto
            // two lines. The row centres itself against the card's width
            // instead, and every label is pinned to one line so this can never
            // be a silent wrap again.
            HStack(spacing: Self.pillGap) {
                ForEach(ApplySurface.allCases, id: \.self) { surface in
                    surfacePill(surface)
                }
            }
            .frame(maxWidth: .infinity)
            // The chooser stays laid out underneath so it keeps defining the
            // width and height. The popover must never resize: it is anchored
            // at the bottom, so a change of height moves the top edge and the
            // whole card appears to jump (owner, 2026-07-20).
            ZStack {
                chooser
                    .opacity(showLockRequirement ? 0 : 1)
                    .allowsHitTesting(!showLockRequirement)
                if showLockRequirement {
                    lockRequirementCard.transition(.opacity)
                }
            }
        }
        .padding(15)
        // No background of its own: `anchoredCard` draws it on the same glass
        // as every dropdown, with the same corner radius.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the lock screen actually needs, said plainly, in the app's own
    /// voice rather than as an error.
    private var lockRequirementCard: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle().fill(Color.muroAccent.opacity(0.14))
                Image(systemName: "lock.display")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.muroAccent)
            }
            .frame(width: 40, height: 40)

            Text("This needs macOS 26")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Text("The lock screen and the screen saver use a part of macOS that arrived in macOS 26. This Mac runs \(Self.osLabel), so Muro can set your desktop but not those.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(Self.ease) { showLockRequirement = false }
            } label: {
                Text("Set my desktop instead")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    /// "macOS 15.6", from the running system rather than a guess.
    private static var osLabel: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0
            ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    private var chooser: some View {
        let isScreenSaver = store.applySurface == .screensaver
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                // The screen saver is one setting for the whole Mac, so there
                // is no display to choose. Saying so is better than a picker
                // whose choice does not matter, and better than hiding the
                // card people are used to clicking.
                Text(isScreenSaver ? "Every display" : "Choose display")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                Spacer()
                if store.displays.count > 1, !isScreenSaver { allPill }
            }
            // The per-display chooser stays laid out underneath on the screen
            // saver tab as well, so it goes on defining the height. The popover
            // is anchored at its bottom edge, so a tab shorter than the others
            // would move the top edge and the whole card would jump on every
            // switch (owner, 2026-07-20).
            ZStack {
                displayChooser
                    .opacity(isScreenSaver ? 0 : 1)
                    .allowsHitTesting(!isScreenSaver)
                if isScreenSaver { screenSaverCard.transition(.opacity) }
            }
            .animation(Self.ease, value: isScreenSaver)
            .animation(Self.ease, value: store.currentAppliedID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One card per connected display, for the surfaces that can really be set
    /// per display.
    ///
    /// Rows of two, each row centred on the card, rather than a two column
    /// grid. A grid stretches its columns to whatever width it is given, which
    /// is what made a lone display's card a different size from a pair of
    /// them, and it leaves an odd last card hard against the left edge. Rows
    /// of fixed cards look the same at one display, at two, and at three,
    /// where the popover simply grows a row taller.
    private var displayRows: [[DisplayInfo]] {
        stride(from: 0, to: store.displays.count, by: 2).map { start in
            Array(store.displays[start..<min(start + 2, store.displays.count)])
        }
    }

    private var displayChooser: some View {
        VStack(spacing: Self.cardGap) {
            ForEach(Array(displayRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.cardGap) {
                    ForEach(row) { display in
                        displayCard(display)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// One card, never one per screen.
    ///
    /// A screen saver is a single setting for the whole Mac. macOS keeps it in
    /// `AllSpacesAndDisplays`, a node that carries no display name at all, and
    /// Apple's own settings have no per-display screen saver picker either.
    /// `LockScreenService.storeTargetKey` already forces every screen saver
    /// apply to "all", so a card per display was offering a choice that does
    /// not exist: one click lit every card green and gave each its own Remove
    /// button, for a single setting (owner, 2026-09-10).
    private var screenSaverCard: some View {
        let applied = store.isApplied(item, surface: .screensaver, target: .all)
        return Group {
            Button {
                if applied {
                    store.removeWallpaper(item, target: .all, surface: .screensaver)
                } else {
                    apply(.all)
                }
            } label: {
                cardLabel(
                    symbol: "display.2",
                    name: "All Screens",
                    sublabel: "Every display",
                    applied: applied
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                applied
                    ? "Remove \(item.title) from the screen saver"
                    : "Apply \(item.title) to the screen saver"
            )
        }
        .frame(maxWidth: .infinity)
    }

    /// The card chrome both choosers draw.
    ///
    /// The shape belongs to the button's label, not to the button. Hung
    /// outside it, the frame, padding and background drew a card while the
    /// button itself stayed the size of the icon and the name, so most of the
    /// card looked clickable and was not. A `contentShape` outside a button
    /// cannot fix that either: it shapes the view it is attached to, not the
    /// button's own hit region.
    private func cardLabel(
        symbol: String,
        name: String,
        sublabel: String,
        applied: Bool
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 21))
                .foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 5) {
                if applied {
                    Circle().fill(Color.muroGreen).frame(width: 5, height: 5)
                }
                Text(name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 8)
            if applied {
                Text("Remove")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(hex: 0xFF6B6B).opacity(0.13)))
                    .overlay(Capsule().strokeBorder(Color(hex: 0xFF6B6B).opacity(0.4), lineWidth: 1))
            } else {
                Text(sublabel)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.muroSecondary)
            }
        }
        // Fixed, not `maxWidth: .infinity` with padding. That is the whole of
        // "the same size": the frame is the card, and what is inside it can
        // change without the card changing.
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.glassSheen(0.12, 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
                applied ? Color.muroGreen.opacity(0.55) : Color.white.opacity(0.14),
                lineWidth: applied ? 1.5 : 1
            ))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Applies without dismissing — people with several displays apply to
    /// them one after another; clicking outside the popover closes it.
    private func apply(_ target: ApplyTarget) {
        store.setWallpaper(
            item,
            mode: store.previewMode,
            target: target,
            surface: store.applySurface
        )
    }

    private func surfacePill(_ surface: ApplySurface) -> some View {
        let selected = store.applySurface == surface
        let enabled = !surface.needsAppleExtension || store.lockScreenAvailable
        // Constant font weight: weight changes used to resize the labels and
        // make "Lockscreen" jump sideways when switching Both → Desktop.
        return Button {
            guard enabled else {
                // Not disabled any more. A dead button tells someone their
                // click failed; this tells them what the rule is.
                withAnimation(Self.ease) { showLockRequirement = true }
                return
            }
            withAnimation(Self.ease) {
                showLockRequirement = false
                store.applySurface = surface
            }
        } label: {
            Text(surface.rawValue)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? Color.black : Color.white.opacity(enabled ? 0.8 : 0.3))
                .padding(.horizontal, Self.pillPadding)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule().fill(Color.white)
                            .matchedGeometryEffect(id: "surface", in: surfaceNS)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !enabled {
                        Text("26+")
                            .font(.system(size: 6.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Color.muroAccent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.muroAccent.opacity(0.16)))
                            .offset(x: 8, y: -6)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Apply to \(surface.rawValue.lowercased())")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .help(enabled ? "" : "The lock screen and screen saver require macOS 26 or later")
    }

    private var allPill: some View {
        let appliedEverywhere = store.isApplied(item, surface: store.applySurface, target: .all)
        return Button {
            if appliedEverywhere {
                store.removeWallpaper(item, target: .all, surface: store.applySurface)
            } else {
                apply(.all)
            }
        } label: {
            Text(appliedEverywhere ? "Remove all" : "All displays")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(appliedEverywhere ? Color(hex: 0xFF6B6B) : .white)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(Capsule().fill(
                    appliedEverywhere
                        ? Color(hex: 0xFF6B6B).opacity(0.13)
                        : Color.white.opacity(0.12)
                ))
                .overlay(Capsule().strokeBorder(
                    appliedEverywhere
                        ? Color(hex: 0xFF6B6B).opacity(0.4)
                        : Color.white.opacity(0.18),
                    lineWidth: 1
                ))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appliedEverywhere ? "Remove from all displays" : "Apply to all displays")
    }

    private func displayCard(_ display: DisplayInfo) -> some View {
        let appliedHere = store.isApplied(
            item,
            surface: store.applySurface,
            target: .display(display.id)
        )
        return Button {
            if appliedHere {
                store.removeWallpaper(
                    item,
                    target: .display(display.id),
                    surface: store.applySurface
                )
            } else {
                apply(.display(display.id))
            }
        } label: {
            cardLabel(
                symbol: display.symbolName,
                name: display.displayName,
                sublabel: display.kindLabel,
                applied: appliedHere
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            appliedHere
                ? "Remove \(item.title) from \(display.displayName)"
                : "Apply \(item.title) to \(display.displayName)"
        )
    }
}

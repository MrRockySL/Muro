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
                .anchoredCard(isPresented: $showDisplayPopover, width: 330, align: .trailing) {
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
        // Centred on the pill: it sits in the middle of the bottom bar, so a
        // menu hanging off either edge of it looks like a mistake.
        return GlassDropdown(width: 190, arrowEdge: .top, align: .center, options: {
            [MenuOption(title: "Use setting (\(SettingsView.pauseAfterLabel(store.pauseAfterSeconds)))",
                        checked: !overridden) {
                store.setPauseAfter(nil, for: item)
            }, .divider]
            + SettingsView.pauseAfterChoices.map { seconds in
                MenuOption(
                    title: seconds == 0 ? "Never pause" : durationLabel(seconds),
                    checked: overridden && value == seconds
                ) { store.setPauseAfter(seconds == 0 ? -1 : seconds, for: item) }
            }
            // The list stops at an hour. Anything else this wallpaper wants
            // is set here, the same way Settings does it.
            + [.divider, MenuOption(title: "Custom") { customPauseAfter = true }]
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
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem
    @Namespace private var surfaceNS
    /// Shown when someone on macOS 14 or 15 picks Lockscreen or Both. The
    /// pills used to be simply disabled with a small "26+" badge, which says
    /// there is a rule without ever saying what it is.
    @State private var showLockRequirement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                Spacer()
                ForEach(ApplySurface.allCases, id: \.self) { surface in
                    surfacePill(surface)
                }
                Spacer()
            }
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
        .padding(18)
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

            Text("Lock screen needs macOS 26")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Text("Live lock screen wallpapers use a part of macOS that arrived in macOS 26. This Mac runs \(Self.osLabel), so Muro can set your desktop but not your lock screen.")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.easeOut(duration: 0.18)) { showLockRequirement = false }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose display")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                Spacer()
                if store.displays.count > 1 { allPill }
            }
            // One display has no second column to sit beside, so the grid
            // left it hard against the edge with the popover's whole width
            // empty next to it. On its own it is centred instead, and kept to
            // about the width it would have had in the grid so it does not
            // stretch into a banner.
            if store.displays.count == 1, let only = store.displays.first {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    displayCard(only).frame(maxWidth: 200)
                    Spacer(minLength: 0)
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(store.displays) { display in
                        displayCard(display)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let enabled = surface == .desktop || store.lockScreenAvailable
        // Constant font weight: weight changes used to resize the labels and
        // make "Lockscreen" jump sideways when switching Both → Desktop.
        return Button {
            guard enabled else {
                // Not disabled any more. A dead button tells someone their
                // click failed; this tells them what the rule is.
                withAnimation(.easeOut(duration: 0.18)) { showLockRequirement = true }
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                showLockRequirement = false
                store.applySurface = surface
            }
        } label: {
            Text(surface.rawValue)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(enabled ? 0.8 : 0.3))
                .padding(.horizontal, 14)
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
        .help(enabled ? "" : "Lock-screen live wallpapers require macOS 26 or later")
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
            Text(appliedEverywhere ? "Remove All" : "All")
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
            VStack(spacing: 6) {
                Image(systemName: display.symbolName)
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 5) {
                    if appliedHere {
                        Circle().fill(Color.muroGreen).frame(width: 5, height: 5)
                    }
                    Text(display.displayName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if appliedHere {
                    Text("Remove")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFF6B6B))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color(hex: 0xFF6B6B).opacity(0.13)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0xFF6B6B).opacity(0.4), lineWidth: 1))
                } else {
                    Text(display.kindLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.muroSecondary)
                }
            }
            // The card's shape belongs to the button's label, not to the
            // button. Hung outside it, the frame, padding and background drew
            // a card while the button itself stayed the size of the icon and
            // the name, so most of the card looked clickable and was not.
            // A `contentShape` outside a button cannot fix that either: it
            // shapes the view it is attached to, not the button's own hit
            // region.
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.glassSheen(0.12, 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    appliedHere ? Color.muroGreen.opacity(0.55) : Color.white.opacity(0.14),
                    lineWidth: appliedHere ? 1.5 : 1
                ))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            appliedHere
                ? "Remove \(item.title) from \(display.displayName)"
                : "Apply \(item.title) to \(display.displayName)"
        )
    }
}

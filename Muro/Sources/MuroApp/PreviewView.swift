import SwiftUI

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
            ThumbImage(item: item)
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
                    // Measured 2026-07-20 (offscreen ink-bounds render): the
                    // glyph is optically centered at 0; the old +1 sat 1pt low.
                    barIcon("square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }

            if item.fps > 40 {
                fpsToggle(item)
            }

            HeartButton(item: item, size: 40)

            setButton(item)
                .popover(isPresented: $showDisplayPopover, arrowEdge: .top) {
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
            fpsSegment("\(Int(item.fps))", mode: "smooth", hint: "~4% CPU")
            fpsSegment("30", mode: "efficient", hint: "~2% CPU")
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
                    Text("Applied")
                        .font(.system(size: 13, weight: .semibold))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                Spacer()
                ForEach(ApplySurface.allCases, id: \.self) { surface in
                    surfacePill(surface)
                }
                Spacer()
            }
            HStack {
                Text("Choose display")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                Spacer()
                if store.displays.count > 1 { allPill }
            }
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(store.displays) { display in
                    displayCard(display)
                }
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(Color(hex: 0x14171D))
        // Colors the popover chrome itself (arrow + any filler drawn during
        // resize) — without this the system paints those white.
        .presentationBackground(Color(hex: 0x14171D))
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
            withAnimation(.easeOut(duration: 0.16)) { store.applySurface = surface }
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
        .disabled(!enabled)
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
                Image(systemName: display.isMain ? "laptopcomputer" : "display")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 5) {
                    if appliedHere {
                        Circle().fill(Color.muroGreen).frame(width: 5, height: 5)
                    }
                    Text(display.name)
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
                    Text(display.isMain ? "Main" : "External")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.muroSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                appliedHere ? Color.muroGreen.opacity(0.55) : Color.white.opacity(0.1),
                lineWidth: appliedHere ? 1.5 : 1
            ))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel(
            appliedHere
                ? "Remove \(item.title) from \(display.name)"
                : "Apply \(item.title) to \(display.name)"
        )
    }
}

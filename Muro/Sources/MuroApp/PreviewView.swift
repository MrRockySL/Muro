import SwiftUI

/// Full-window wallpaper preview with the floating glass pill bar and the
/// choose-display popover. Covers everything including the top bar.
struct PreviewView: View {
    @EnvironmentObject var store: AppStore
    let itemID: String

    @State private var showDisplayPopover = false

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
                    LoopingPlayerView(url: url)
                } else {
                    ThumbImage(item: item)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
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
                    barIcon("square.and.arrow.up", opticalYOffset: 1)
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
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        } else if !item.isDownloaded {
            capsuleButton("Download", systemName: "arrow.down") {
                store.download(item)
            }
        } else if store.generating.contains(item.id) {
            Text("Preparing 30 fps…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        } else if store.isFullyApplied(item) {
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
    }

    /// Applies without dismissing — people with several displays apply to
    /// them one after another; clicking outside the popover closes it.
    private func apply(_ target: ApplyTarget) {
        store.setWallpaper(item, mode: store.previewMode, target: target)
    }

    private func surfacePill(_ surface: ApplySurface) -> some View {
        let selected = store.applySurface == surface
        let enabled = surface != .lockscreen   // lock screen arrives in Phase 4
        // Constant font weight: weight changes used to resize the labels and
        // make "Lockscreen" jump sideways when switching Both → Desktop.
        return Text(surface.rawValue)
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
                    Text("SOON")
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
            .onTapGesture {
                guard enabled else { return }
                withAnimation(.easeOut(duration: 0.16)) { store.applySurface = surface }
            }
            .help(enabled ? "" : "Lock screen live wallpapers arrive in a later update")
    }

    private var allPill: some View {
        Button {
            apply(.all)
        } label: {
            Text("All")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func displayCard(_ display: DisplayInfo) -> some View {
        let appliedHere = store.config.assignment(forDisplayUUID: display.id)?.wallpaperID == item.id
        return VStack(spacing: 6) {
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
                // Applied on this display → the action here is Remove.
                Button {
                    store.removeWallpaper(fromDisplay: display.id)
                } label: {
                    Text("Remove")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFF6B6B))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color(hex: 0xFF6B6B).opacity(0.13)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0xFF6B6B).opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Text(display.isMain ? "Main" : "External")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.muroSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    appliedHere ? Color.muroGreen.opacity(0.55) : Color.white.opacity(0.1),
                    lineWidth: appliedHere ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            // Tapping the card applies to this display; once applied, the
            // red Remove pill inside is the way to take it off again.
            if !appliedHere { apply(.display(display.id)) }
        }
    }
}

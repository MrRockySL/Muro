import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var pickPage = 0

    private var pickItems: [WallpaperItem] {
        let liked = store.likedItems
        let rest = store.items.filter { item in !liked.contains(where: { $0.id == item.id }) }
        return liked + rest
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                heroSelector
                    .padding(.top, 22)
                    .padding(.horizontal, 64)
                pickSection
                    .padding(.top, 44)
                    .padding(.horizontal, 64)
                    .padding(.bottom, 48)
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero

    @ViewBuilder private var hero: some View {
        if let item = store.heroItem {
            ZStack(alignment: .bottomLeading) {
                heroMedia(item)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.15), location: 0),
                        .init(color: .clear, location: 0.35),
                        .init(color: Color.muroBG.opacity(0.35), location: 0.72),
                        .init(color: Color.muroBG, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                heroContent(item)
                    .padding(.leading, 64)
                    .padding(.bottom, 44)
            }
            .frame(height: 560)
            .clipped()
        } else {
            emptyLibraryHero
        }
    }

    private func heroMedia(_ item: WallpaperItem) -> some View {
        GeometryReader { proxy in
            Group {
                if let url = store.videoURL(for: item, mode: "smooth") {
                    LoopingPlayerView(url: url)
                } else {
                    ThumbImage(item: item)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private func heroContent(_ item: WallpaperItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FEATURED")
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(Color.muroAccent)
            Text(item.title)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 10)
            HStack(spacing: 12) {
                Text(item.metaLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                FPSChip(text: item.fps > 40 ? "\(Int(item.fps)) FPS" : "\(item.resolutionLabel) · \(Int(item.fps))")
                let applied = store.appliedDisplays(for: item.id)
                if let first = applied.first {
                    AppliedChip(label: "APPLIED · " + (applied.count > 1 ? "ALL DISPLAYS" : first.chipLabel))
                }
            }
            .padding(.top, 14)
            HStack(spacing: 12) {
                Button {
                    store.openPreview(item)
                } label: {
                    HStack(spacing: 8) {
                        Text("View Wallpaper")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .glassCapsule(fill: 0.12, stroke: 0.2)
                }
                .buttonStyle(.plain)
                HeartButton(item: item, size: 44)
            }
            .padding(.top, 20)
        }
    }

    private var emptyLibraryHero: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42))
                .foregroundStyle(Color.muroSecondary)
            Text("Your library is empty")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text("Import your own videos with the + button, or browse Explore to download wallpapers.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muroSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 560)
    }

    // MARK: - Hero selector strip

    private var heroSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(store.items.prefix(10)) { item in
                    let active = store.heroItem?.id == item.id
                    Color.black
                        .frame(width: active ? 104 : 96, height: active ? 64 : 58)
                        .overlay(ThumbImage(item: item))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    active ? Color.white : Color.white.opacity(0.1),
                                    lineWidth: active ? 2 : 1
                                )
                        )
                        .onTapGesture { store.heroID = item.id }
                }
            }
            .frame(height: 64)
        }
    }

    // MARK: - Muro's Pick row

    private var pickSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Muro's Pick")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Hand-picked from your library")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.muroSecondary)
                }
                Spacer()
                pager
            }
            let page = pageItems
            HStack(spacing: 24) {
                ForEach(page) { item in
                    WallpaperCard(item: item)
                }
                if page.count < 3 {
                    ForEach(0..<(3 - page.count), id: \.self) { _ in Color.clear }
                }
            }
        }
    }

    private var pageCount: Int {
        max(1, (pickItems.count + 2) / 3)
    }

    private var pageItems: [WallpaperItem] {
        let start = pickPage * 3
        guard start < pickItems.count else { return [] }
        return Array(pickItems[start..<min(start + 3, pickItems.count)])
    }

    private var pager: some View {
        HStack(spacing: 8) {
            pagerButton(systemName: "chevron.left", enabled: pickPage > 0) { pickPage -= 1 }
            pagerButton(systemName: "chevron.right", enabled: pickPage < pageCount - 1) { pickPage += 1 }
        }
    }

    private func pagerButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .glassCapsule(fill: 0.08, stroke: 0.14)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

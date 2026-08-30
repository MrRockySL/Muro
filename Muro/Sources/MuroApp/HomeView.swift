import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var pickPage = 0
    @State private var dropPage = 0

    /// The most recent drop, which is the whole point of the row: it is the
    /// batch as published, and it stays put until a newer one is published.
    private var dropItems: [WallpaperItem] { store.latestDropItems }

    /// Twelve at random, redrawn each launch. The store owns the draw so it
    /// survives this view being rebuilt on every tab switch.
    private var pickItems: [WallpaperItem] { store.pickItems }

    var body: some View {
        // Same coloured surface Explore and Library sit on. Home used to be
        // flat `muroBG` on the theory that the hero is already a 4K video and
        // anything behind it is noise, but the hero is only the top 560pt:
        // everything under it, which is most of the page once you scroll, was
        // a flatter and darker grey than the other two tabs. No `GlassTray`
        // here, unlike those two, because the hero is deliberately full bleed
        // and a tray would inset it away from the window edge.
        ZStack {
            MuroPageBackground()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    heroSelector
                        .padding(.top, 22)
                        .padding(.horizontal, 64)
                    if !dropItems.isEmpty {
                        dropSection
                            .padding(.top, 44)
                            .padding(.horizontal, 64)
                    }
                    pickSection
                        .padding(.top, 44)
                        .padding(.horizontal, 64)
                        .padding(.bottom, 48)
                }
            }
            .ignoresSafeArea(edges: .top)
            // A drop that lands while the app is open replaces the row's
            // contents under whatever page the user had turned to, which would
            // otherwise leave them looking at a page that no longer exists.
            .onChange(of: dropItems.first?.id) { _, _ in dropPage = 0 }
        }
    }

    // MARK: - Hero

    @ViewBuilder private var hero: some View {
        if let item = store.heroItem {
            ZStack(alignment: .bottomLeading) {
                // The video and its scrim fade to nothing at the bottom edge,
                // so whatever the page background happens to be there shows
                // through and the hero has no edge at all.
                //
                // It used to fade to a colour instead, and that is what drew a
                // hard line across the window. A colour can only match a
                // background that is flat, and this one is not: the blooms sit
                // behind the hero's bottom edge and shift with the window
                // size, so there is no single value that is ever right.
                // Transparent matches everything, at every size, for free.
                ZStack {
                    heroMedia(item)
                    // Darkening only, for the title and buttons to read
                    // against. Black rather than a background colour, because
                    // this fades out with everything else.
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.15), location: 0),
                            .init(color: .clear, location: 0.35),
                            .init(color: .black.opacity(0.30), location: 0.75),
                            .init(color: .black.opacity(0.45), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                // Four stops rather than two: a straight ramp still reads as a
                // line where it begins, because the eye finds the point the
                // slope changes. This eases in and then falls away.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.50),
                            .init(color: .white.opacity(0.82), location: 0.70),
                            .init(color: .white.opacity(0.35), location: 0.88),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
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
                // The hero only ever plays local files: a downloaded master
                // or the bundled 4K. It never streams (owner, 2026-07-19).
                // It also stops while a full screen preview covers it, since
                // Home stays mounted underneath and two 4K decoders would
                // otherwise run at once.
                if let url = store.heroVideoURL(for: item) {
                    LoopingPlayerView(url: url, isActive: store.previewItem == nil)
                } else {
                    // Hero-sized, so it gets the full decode.
                    ThumbImage(item: item, maxPixels: ImageCache.fullPixels)
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
                ForEach(store.heroSelectorItems.prefix(10)) { item in
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

    // MARK: - Card rows

    /// The newest batch of wallpapers published, above the picks.
    ///
    /// The NEW badge on these cards is the same one Explore shows and behaves
    /// the same way: it marks what has arrived since this install last looked
    /// and fades after a launch or two. The row itself does not. It keeps
    /// showing this drop until a newer one is published, so it is still the
    /// place to find what is new long after the badges have gone.
    private var dropSection: some View {
        cardRow(
            title: "New Live Wallpapers",
            subtitle: "The latest wallpapers added to the catalog",
            items: dropItems,
            page: $dropPage
        )
    }

    /// The subtitle had to move with the row. It said hand-picked from your
    /// library while listing the whole catalog in array order, which was
    /// wrong twice over, and it would have stayed wrong now the row is a
    /// random draw.
    private var pickSection: some View {
        cardRow(
            title: "Muro's Pick",
            subtitle: "A different twelve every time you open Muro",
            items: pickItems,
            page: $pickPage
        )
    }

    /// One titled row of three cards with a pager. Both Home rows are the same
    /// shape, and were the same code written twice until there were two of
    /// them.
    private func cardRow(
        title: String,
        subtitle: String,
        items: [WallpaperItem],
        page: Binding<Int>
    ) -> some View {
        let count = max(1, (items.count + 2) / 3)
        let start = page.wrappedValue * 3
        let shown = start < items.count
            ? Array(items[start..<min(start + 3, items.count)])
            : []
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.muroSecondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    pagerButton(systemName: "chevron.left", enabled: page.wrappedValue > 0) {
                        page.wrappedValue -= 1
                    }
                    pagerButton(systemName: "chevron.right", enabled: page.wrappedValue < count - 1) {
                        page.wrappedValue += 1
                    }
                }
            }
            HStack(spacing: 24) {
                ForEach(shown) { item in
                    WallpaperCard(item: item)
                }
                // Keeps a short last page's cards the same width as a full
                // one's rather than letting three columns become one.
                if shown.count < 3 {
                    ForEach(0..<(3 - shown.count), id: \.self) { _ in Color.clear }
                }
            }
        }
    }

    /// The same glass bubble as the top bar's controls. Home had the last two
    /// flat 8% circles left in the app, and next to a lit bubble a flat one
    /// reads as a control that is switched off.
    private func pagerButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        GlassBubbleButton(systemName: systemName, size: 34, glyphScale: 0.33, action: action)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }
}

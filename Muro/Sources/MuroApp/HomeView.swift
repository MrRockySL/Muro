import SwiftUI
import MuroKit

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var pickPage = 0
    @State private var dropPage = 0

    /// Which way each row was last paged, so the cards leave towards the
    /// arrow that was pressed and the new ones arrive from the far side. Kept
    /// per row, because paging one row must not throw the other into reverse.
    /// Same idea as the Library's own `tabShift`.
    @State private var pickShift: CGFloat = 1
    @State private var dropShift: CGFloat = 1

    // The curve and the transition itself live in `Theme.swift` as
    // `.muroPage`, because every page change in the app now uses them.

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
                .background(alignment: .top) { heroGlow }
                .background(NoOverscroll())
                // Whether the banner is still behind the top bar, for the
                // light look's top bar: white over the banner, dark once the
                // page scrolls under it.
                .background(BannerUnderBarWatcher(threshold: heroHeight - 100) { under in
                    if store.heroUnderTopBar != under { store.heroUnderTopBar = under }
                })
            }
            .onDisappear { store.heroUnderTopBar = true }
            .ignoresSafeArea(edges: .top)
            // A drop that lands while the app is open replaces the row's
            // contents under whatever page the user had turned to, which would
            // otherwise leave them looking at a page that no longer exists.
            .onChange(of: dropItems.first?.id) { _, _ in dropPage = 0 }
        }
    }

    // MARK: - Hero

    /// 560, and 60 more on the light look, where the blend into the white
    /// page needs a little room below the words.
    private var heroHeight: CGFloat { Appearance.shared.isLight ? 620 : 560 }

    /// The light look only: the banner's own colours as a soft light behind
    /// its last strip and on the page just under it. See `HeroGlow`.
    @ViewBuilder private var heroGlow: some View {
        if Appearance.shared.isLight, let item = store.heroItem {
            HeroGlow(item: item)
                .frame(height: HeroGlow.above + HeroGlow.below)
                .padding(.top, heroHeight - HeroGlow.above)
                .allowsHitTesting(false)
        }
    }

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
                    //
                    // On the light look it sits behind the words only and is
                    // gone before the blend below them, so the wallpaper melts
                    // into the white page in its own colours, not through grey
                    // (owner, 2026-10-02). Any black left in the blend turns
                    // it into a grey band, so it ends above it.
                    LinearGradient(
                        stops: Appearance.shared.isLight ? [
                            .init(color: .black.opacity(0.15), location: 0),
                            .init(color: .clear, location: 0.30),
                            .init(color: .black.opacity(0.34), location: 0.55),
                            .init(color: .black.opacity(0.40), location: 0.74),
                            .init(color: .black.opacity(0.12), location: 0.84),
                            .init(color: .clear, location: 0.90)
                        ] : [
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
                //
                // On the light look the banner is a little taller and the words
                // sit where they always were, so the blend into the white page
                // happens just below them: no hard line and no white over the
                // title (owner, 2026-10-02). It fades over its last 124 points
                // into `HeroGlow`, the wallpaper's own colours, not into the
                // white itself: a dark picture faded straight into white goes
                // through grey, and that grey band read as a shade whatever its
                // length (owner, 2026-10-03).
                .mask(
                    LinearGradient(
                        stops: Appearance.shared.isLight ? [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.80),
                            .init(color: .white.opacity(0.70), location: 0.87),
                            .init(color: .white.opacity(0.30), location: 0.94),
                            .init(color: .clear, location: 1)
                        ] : [
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
                    // Over the playing wallpaper in every look, so its glass
                    // stays white like the rest of the banner.
                    .environment(\.muroOnMedia, true)
                    .padding(.leading, 64)
                    .padding(.bottom, 44 + heroHeight - 560)
            }
            .frame(height: heroHeight)
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
                    LoopingPlayerView(url: url, isActive: store.previewItem == nil && !store.powerPaused)
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
            // Over the playing wallpaper, so these keep the dark look's
            // colours whatever the look is (6.0).
            Text("FEATURED")
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(Color.muroAccentOnMedia)
            Text(item.title)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 10)
            HStack(spacing: 12) {
                Text(item.metaLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondaryOnMedia)
                FPSChip(text: item.fps > 40 ? "\(standardFrameRate(item.fps)) FPS" : "\(item.resolutionLabel) · \(standardFrameRate(item.fps))")
                if let label = store.appliedChipLabel(for: item.id) {
                    AppliedChip(label: "APPLIED · " + label)
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
                .foregroundStyle(Color.muroInk)
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
            page: $dropPage,
            shift: $dropShift
        )
    }

    /// The subtitle had to move with the row. It said hand-picked from your
    /// library while listing the whole catalog in array order, which was
    /// wrong twice over, and it would have stayed wrong now the row is a
    /// random draw.
    private var pickSection: some View {
        cardRow(
            title: "Muro's Pick",
            subtitle: "A different twelve every day",
            items: pickItems,
            page: $pickPage,
            shift: $pickShift
        )
    }

    /// One titled row of three cards with a pager. Both Home rows are the same
    /// shape, and were the same code written twice until there were two of
    /// them.
    private func cardRow(
        title: String,
        subtitle: String,
        items: [WallpaperItem],
        page: Binding<Int>,
        shift: Binding<CGFloat>
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
                        .foregroundStyle(Color.muroInk)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.muroSecondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    pagerButton(systemName: "chevron.left", enabled: page.wrappedValue > 0) {
                        // Direction first, outside the animation: the
                        // transition is built while the view re-renders, so it
                        // has to already know which way this page is going.
                        shift.wrappedValue = -1
                        withAnimation(.muroPage) { page.wrappedValue -= 1 }
                    }
                    pagerButton(systemName: "chevron.right", enabled: page.wrappedValue < count - 1) {
                        shift.wrappedValue = 1
                        withAnimation(.muroPage) { page.wrappedValue += 1 }
                    }
                }
            }
            // A ZStack rather than the bare HStack. A transition means both
            // pages exist for the moment it runs, and in the VStack they would
            // stack up and shove the rest of Home down the screen mid
            // animation. Overlaid, they pass through each other in place.
            ZStack {
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
                // The `.id` is what makes this a page change at all: without
                // it SwiftUI reuses the same three cards and just swaps their
                // images, which no transition can animate.
                .id(page.wrappedValue)
                .transition(.muroPage(shift: shift.wrappedValue))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// Stops Home from being pulled past its ends (owner, 2026-09-30). The hero
/// runs full bleed under the top bar, and a fast pull down slid it away from
/// the top of the window and showed the bare background above it. The page
/// scrolls exactly as before; it only no longer stretches.
///
/// A probe inside the scrolling content that finds the `NSScrollView` SwiftUI
/// made, like `ScrollViewFinder`, and never takes a click.
private struct NoOverscroll: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view {
                if let scroller = current as? NSScrollView {
                    scroller.verticalScrollElasticity = .none
                    return
                }
                view = current.superview
            }
        }
    }
}

/// Says whether Home's banner is still behind the top bar, from the
/// `NSScrollView` itself (owner, 2026-10-02).
///
/// A geometry reader inside the page never heard about scrolling on macOS:
/// the clip view moves, the content's frame does not. This watches the clip
/// view's bounds instead, like `NoOverscroll` finds the scroller, and reports
/// only when the answer changes. The bar's lower edge sits about 100 down, so
/// past the banner's height less 100 the page itself is behind the bar.
private struct BannerUnderBarWatcher: NSViewRepresentable {
    let threshold: CGFloat
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.threshold = threshold
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.threshold = threshold
        nsView.onChange = onChange
    }

    final class Probe: NSView {
        var threshold: CGFloat = 460
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?
        private var last: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observer == nil, window != nil else { return }
            var view = superview
            while let current = view {
                if let scroller = current as? NSScrollView {
                    let clip = scroller.contentView
                    clip.postsBoundsChangedNotifications = true
                    observer = NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
                    ) { [weak self, weak scroller] _ in
                        guard let scroller else { return }
                        self?.report(scroller)
                    }
                    report(scroller)
                    return
                }
                view = current.superview
            }
        }

        private func report(_ scroller: NSScrollView) {
            let clip = scroller.contentView
            let documentHeight = scroller.documentView?.frame.height ?? 0
            // How far the page has scrolled down, whichever way the document
            // view counts.
            let offset = clip.isFlipped
                ? clip.bounds.origin.y
                : documentHeight - clip.bounds.height - clip.bounds.origin.y
            let under = offset < threshold
            guard under != last else { return }
            last = under
            onChange?(under)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// The banner's own colours as a soft light on the white page, for the light
/// look (owner, 2026-10-03).
///
/// A dark wallpaper faded into white passes through grey on the way, however
/// long or short the fade, and that grey band is what read as a shade. This
/// lays a pale wash of the wallpaper's own colours behind the banner's last
/// strip and on the page just under it, one colour per column, so the picture
/// fades into its own light and that light into the page: green under a
/// jungle, peach under a warm room, pale blue under a rainy street. Grey only
/// where the picture itself is grey.
private struct HeroGlow: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem

    /// How far the wash reaches up behind the banner, and down onto the page.
    static let above: CGFloat = 150
    static let below: CGFloat = 130

    /// Bumped when a wallpaper's colours land, to draw them.
    @State private var landed = 0

    var body: some View {
        let colours = HeroGlowPalette.cached(item.id)
        let fold = Self.above / (Self.above + Self.below)
        ZStack {
            if let colours {
                LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        // Full strength where the banner ends, then gone over the page.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: fold),
                    .init(color: .white.opacity(0.55), location: fold + (1 - fold) * 0.35),
                    .init(color: .white.opacity(0.18), location: fold + (1 - fold) * 0.70),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .opacity(0.9)
        // The banner cuts straight to the next wallpaper, so this only softens
        // the change a little.
        .animation(.easeInOut(duration: 0.35), value: "\(item.id) \(colours != nil) \(landed)")
        .task(id: item.id) {
            guard HeroGlowPalette.cached(item.id) == nil,
                  let path = store.thumbnailPath(for: item) else { return }
            let colours = await Task.detached(priority: .utility) {
                HeroGlowPalette.colours(thumbnailPath: path)
            }.value
            guard let colours, !Task.isCancelled else { return }
            HeroGlowPalette.remember(colours, for: item.id)
            landed += 1
        }
    }
}

/// Reads a wallpaper's light colours from its thumbnail, for `HeroGlow`.
enum HeroGlowPalette {
    /// Wallpaper id to colours, left to right. Touched on the main thread only.
    private static var cache: [String: [Color]] = [:]

    static func cached(_ id: String) -> [Color]? { cache[id] }

    static func remember(_ colours: [Color], for id: String) { cache[id] = colours }

    /// The thumbnail shrunk to 24 by 14; per column, the mean colour of the
    /// lower half (where the banner meets the page), weighted towards the
    /// brighter pixels so leaves count and the black between them does not.
    /// Hue kept, saturation capped at 0.2 and brightness set to 0.96: light,
    /// not paint. Off the main thread.
    static func colours(thumbnailPath path: String) -> [Color]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 96,
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let width = 24, height = 14
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Row 0 of the buffer is the top of the picture.
        var means: [(Double, Double, Double)] = []
        for x in 0..<width {
            var r = 0.0, g = 0.0, b = 0.0, total = 0.0
            for y in (height / 2)..<height {
                for dx in -3...3 {
                    let column = min(width - 1, max(0, x + dx))
                    let i = (y * width + column) * 4
                    let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
                    let luma = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
                    let weight = luma * luma + 0.0004
                    r += pr * weight; g += pg * weight; b += pb * weight; total += weight
                }
            }
            means.append((r / total, g / total, b / total))
        }
        // A light blur across the columns, so the wash has no steps.
        let kernel = [1.0, 4.0, 6.0, 4.0, 1.0]
        return (0..<width).map { x in
            var r = 0.0, g = 0.0, b = 0.0
            for (k, w) in kernel.enumerated() {
                let m = means[min(width - 1, max(0, x + k - 2))]
                r += m.0 * w; g += m.1 * w; b += m.2 * w
            }
            let colour = NSColor(srgbRed: r / 16, green: g / 16, blue: b / 16, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return Color(hue: Double(hue), saturation: Double(min(saturation, 0.2)), brightness: 0.96)
        }
    }
}

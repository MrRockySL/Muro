import SwiftUI
import MuroKit

/// The Apple section: Apple's own aerial wallpapers, and next the screen
/// savers. Issue #7 for the aerials; the screen savers were asked for on
/// Reddit.
///
/// Its own section on purpose (owner, 2026-09-28): this is Apple's content,
/// brought in because the community asked for it, and it costs more to play
/// than Muro's own wallpapers. Home, Explore and the Library stay exactly as
/// they were.
///
/// Built as the same page the Library is: the coloured background, the inset
/// glass tray, one centred glass control for the two kinds, and under it a
/// smaller one for Apple's categories, in Apple's own order. Every aerial in
/// the chosen category is in the one grid, with no See more rows (owner,
/// 2026-09-08).
///
/// **Nothing here is downloaded to be shown.** macOS leaves a small still on
/// the Mac for every aerial it lists, so the grid paints at once. The sharp
/// picture of each card is then read out of the real video on Apple's server
/// (`AppleAerialFetcher`), once, and only for the cards that are looked at.
struct AppleGalleryView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var model = AppleAerialModel()
    @ObservedObject private var fetcher = AppleAerialFetcher.shared

    enum Kind: String, CaseIterable {
        case aerials, screenSavers
    }

    @AppStorage("appleSectionKind") private var kind: Kind = .aerials
    @State private var kindShift: CGFloat = 1
    @AppStorage("appleAerialCategory") private var category = "All"
    /// Which way the last category change went, so the grid leaves towards the
    /// pill you came from. Same reasoning as Explore's.
    @State private var categoryShift: CGFloat = 1

    private let gridColumns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    private var shown: [AppleAerial] {
        model.aerials(in: category, matching: store.searchText)
    }

    var body: some View {
        ZStack {
            MuroPageBackground()
            GlassTray {
                VStack(alignment: .leading, spacing: 0) {
                    kindRow
                        .padding(.horizontal, 40)
                        .padding(.top, 26)
                    Group {
                        switch kind {
                        case .aerials: aerialsPage
                        case .screenSavers: screenSaversPage
                        }
                    }
                    .id(kind)
                    .transition(.muroPage(shift: kindShift))
                }
                .animation(.muroPage, value: kind)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 88)
            .padding(.bottom, 20)
        }
        .onAppear { if !model.loaded { model.load() } }
        // Every time the section opens, until it is turned off in the card
        // itself (owner, 2026-09-30).
        .onAppear { if AppleNoticeCard.wanted { store.appleNoticeOpen = true } }
        // A category Apple no longer ships would leave the page filtered to
        // nothing with no lit pill to say why. Explore guards the same thing.
        .onChange(of: model.categories) { _, list in
            if category != "All", !list.isEmpty, !list.contains(category) { category = "All" }
        }
    }

    // MARK: - Aerials or screen savers

    private var kindRow: some View {
        ZStack {
            PillSegments(
                options: [
                    PillOption(Kind.aerials.rawValue, "Aerials", count: model.aerialCount),
                    PillOption(Kind.screenSavers.rawValue, "Screen Savers",
                               count: model.aerials == nil ? nil : model.screenSavers(matching: "").count)
                ],
                selection: Binding(
                    get: { kind.rawValue },
                    set: { raw in
                        guard let new = Kind(rawValue: raw), new != kind else { return }
                        kindShift = new == .screenSavers ? 1 : -1
                        kind = new
                    }
                ),
                height: 38,
                labelSize: 13
            )
            HStack(spacing: 8) {
                if store.searchActive { SearchField() }
                Spacer(minLength: 12)
            }
        }
        .frame(height: 48)
    }

    // MARK: - Aerials

    private var aerialsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            categoryRow
                .padding(.horizontal, 40)
                .padding(.top, 18)
            // A new scroll view for each category, so every category starts
            // at its top (owner, 2026-09-30). See Explore.
            ZStack {
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if shown.isEmpty {
                            emptyState
                        } else {
                            grid
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
                .scrollFade(top: 20, bottom: 46)
                .id(category)
                .transition(.muroPage(shift: categoryShift))
            }
            .animation(.muroPage, value: category)
        }
    }

    private var categoryOptions: [PillOption] {
        [PillOption("All", "All")] + model.categories.map { PillOption($0, $0) }
    }

    /// The Library's small switch, at the same size, so the page reads as two
    /// levels: what kind, then which of them.
    private var categorySegments: some View {
        PillSegments(
            options: categoryOptions,
            selection: Binding(
                get: { category },
                set: { new in
                    guard new != category else { return }
                    let order = categoryOptions.map(\.id)
                    if let from = order.firstIndex(of: category),
                       let to = order.firstIndex(of: new) {
                        categoryShift = to >= from ? 1 : -1
                    }
                    category = new
                }
            ),
            height: 30,
            labelSize: 12,
            horizontalPadding: 14
        )
        .fixedSize()
    }

    /// Apple's categories on the left, how many and how many are already on
    /// this Mac on the right. Seven pills fit beside the count on any window
    /// Muro opens at; a narrow one scrolls them sideways rather than wrapping.
    private var categoryRow: some View {
        HStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                categorySegments
                ScrollView(.horizontal, showsIndicators: false) {
                    categorySegments.padding(.horizontal, 2).padding(.vertical, 3)
                }
            }
            Spacer(minLength: 12)
            Text(countLine)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.muroSecondary)
                .lineLimit(1)
                .fixedSize()
            if downloadedCount > 0 { downloadedChip }
        }
        .frame(height: 40)
    }

    private var countLine: String {
        let count = shown.count
        let noun = count == 1 ? "wallpaper" : "wallpapers"
        if category == "All" { return "\(count) \(noun) from Apple" }
        return "\(count) \(noun) in \(category)"
    }

    /// Videos ready to play, and still pictures downloaded, on this page.
    private var downloadedCount: Int {
        model.aerials(in: "All", matching: "").filter { $0.isDownloaded || $0.hasMuroCopy }.count
    }

    /// Says how many are ready to play without a download, because on a fresh
    /// Mac that is one or two out of 162 and the difference is the whole point
    /// of the page.
    private var downloadedChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10.5, weight: .semibold))
            Text("\(downloadedCount) on this Mac")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Color.muroAccent)
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(Capsule().fill(Color.muroAccent.opacity(0.13)))
        .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.28), lineWidth: 1))
    }

    /// Each card asks for its sharp picture when it comes into view and stops
    /// asking when it leaves, so a fast scroll does not queue every aerial.
    /// `fetcher.revision` is read so the grid redraws when a picture or a real
    /// size lands; the card itself notices because its row changed.
    private var grid: some View {
        let _ = fetcher.revision
        return LazyVGrid(columns: gridColumns, spacing: 24) {
            ForEach(shown) { aerial in
                WallpaperCard(item: store.appleWallpaperItem(aerial), persistentTitle: true)
                    .onAppear { fetcher.requestFrame(for: aerial) }
                    .onDisappear { fetcher.cancelFrame(for: aerial) }
            }
        }
    }

    // MARK: - Screen savers

    /// Apple's eight screen savers, as Muro's own 4K recordings
    /// (`AppleScreenSaverVideos`): downloaded and played like an aerial, on
    /// the desktop, the lock screen and the screen saver separately (owner,
    /// 2026-09-30). The ones a person adds from the Library's import bar stay
    /// in the Library with the rest of what they import.
    private var screenSaversPage: some View {
        let savers = model.screenSavers(matching: store.searchText)
        return ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    // A search that matched none of the eight left a blank
                    // page with the tab still saying 8 (full check,
                    // 2026-10-01). It answers the way the aerials do.
                    if savers.isEmpty {
                        if model.loaded { noMatchesState(noun: "screen saver") } else { loadingState }
                    } else {
                        saverGrid(savers)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .scrollFade(top: 20, bottom: 46)
        }
        .padding(.top, 18)
    }

    private func saverGrid(_ items: [AppleAerial]) -> some View {
        let _ = fetcher.revision
        return LazyVGrid(columns: gridColumns, spacing: 24) {
            ForEach(items) { saver in
                WallpaperCard(item: store.appleWallpaperItem(saver), persistentTitle: true)
                    .onAppear { fetcher.requestFrame(for: saver) }
                    .onDisappear { fetcher.cancelFrame(for: saver) }
            }
        }
    }

    // MARK: - Empty states

    /// Three reasons this page can be empty, and each deserves its own answer.
    /// The first one is not a fault at all: a Mac that has never opened the
    /// wallpaper pane in System Settings has no aerial store yet.
    @ViewBuilder private var emptyState: some View {
        if !model.loaded {
            loadingState
        } else if model.aerials == nil {
            noStoreState
        } else {
            noMatchesState(noun: "aerial")
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.muroAccent)
            Text("Reading Apple's wallpapers…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.muroSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 84)
    }

    private var noStoreState: some View {
        VStack(spacing: 12) {
            emptyIcon("macwindow.badge.plus")
            Text("Apple's wallpapers are not on this Mac yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text("Open System Settings and look at Wallpaper once. macOS writes "
                 + "its list of aerials then, and Muro reads the same list.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            Button {
                model.load()
            } label: {
                Text("Look Again")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.muroAccent)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Capsule().fill(Color.muroAccent.opacity(0.13)))
                    .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func noMatchesState(noun: String) -> some View {
        VStack(spacing: 12) {
            emptyIcon("sparkle.magnifyingglass")
            Text("Nothing matches that")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(store.searchText.isEmpty
                 ? "Try another category."
                 : "No \(noun) called \(store.searchText). Try another word.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func emptyIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.muroAccent)
            .frame(width: 54, height: 54)
            .background(Circle().fill(.glassSheen(0.14, 0.05)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

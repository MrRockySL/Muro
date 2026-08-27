import SwiftUI

/// Explore, rebuilt in the 3.0 language (2026-08-24).
///
/// It used to sit straight on the window's flat black with its controls
/// scattered along one line: category chips crowded into the left corner and
/// two small dropdowns pushed to the right. Next to the redesigned Library it
/// read as a different app. It is now the same page the Library is: the
/// coloured background, the inset glass tray, one centred glass control for
/// the categories, and a second line for the filters that narrow them.
struct ExploreView: View {
    @EnvironmentObject var store: AppStore
    @State private var category = "All"
    @State private var resolution = "All"
    @State private var fps = "All"

    private let gridColumns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    /// Real values present in the catalog/library — the dropdowns only
    /// offer resolutions and frame rates that actually exist.
    private var resolutionOptions: [String] {
        let present = Set(store.items.map(\.resolutionLabel))
        return ["4K", "1440p", "1080p"].filter(present.contains)
    }

    private var fpsOptions: [String] {
        Set(store.items.map { "\(Int($0.fps.rounded()))" })
            .sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }
    }

    /// Newest publish first, so a drop lands at the top of the grid instead of
    /// behind however many wallpapers this user happens to have downloaded.
    /// The category tabs and the two filters narrow this order rather than
    /// replacing it, so a fresh batch is at the top of Cars as well as of All.
    private var filtered: [WallpaperItem] {
        store.newestFirstItems.filter { item in
            if category != "All", item.category != category { return false }
            if resolution != "All", item.resolutionLabel != resolution { return false }
            if fps != "All", "\(Int(item.fps.rounded()))" != fps { return false }
            if !store.searchText.isEmpty,
               !item.title.localizedCaseInsensitiveContains(store.searchText),
               !item.category.localizedCaseInsensitiveContains(store.searchText) {
                return false
            }
            return true
        }
    }

    private var narrowed: Bool { resolution != "All" || fps != "All" }

    /// Changing any of the three re-makes the grid, which is what gives the
    /// crossfade something to fade between. Search is left out on purpose: it
    /// filters on every keystroke and should not restart an animation each
    /// time.
    private var filterKey: String { "\(category)|\(resolution)|\(fps)" }

    var body: some View {
        ZStack {
            MuroPageBackground()
            GlassTray {
                VStack(alignment: .leading, spacing: 0) {
                    categoryRow
                        .padding(.horizontal, 40)
                        .padding(.top, 30)
                    filterRow
                        .padding(.horizontal, 40)
                        .padding(.top, 14)
                    ScrollView(.vertical, showsIndicators: false) {
                        Group {
                            if filtered.isEmpty {
                                emptyState
                            } else {
                                grid
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 22)
                        .padding(.bottom, 40)
                        .id(filterKey)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    .scrollFade(top: 22, bottom: 46)
                    .animation(.easeOut(duration: 0.24), value: filterKey)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 88)
            .padding(.bottom, 20)
        }
        // A category the catalog no longer has would leave the page filtered
        // to nothing, with no lit segment to say why.
        .onChange(of: store.categories) { _, list in
            if category != "All", !list.contains(category) { category = "All" }
        }
    }

    // MARK: - Categories

    private var categoryOptions: [PillOption] {
        [PillOption("All", "All")] + store.categories.map { PillOption($0, $0) }
    }

    private var categorySegments: some View {
        PillSegments(
            options: categoryOptions,
            selection: $category,
            height: 42,
            labelSize: 13.5,
            horizontalPadding: 16
        )
    }

    /// Centred like the Library's tabs. A library has four tabs and always
    /// fits; a catalog can grow a category at any time, so the row falls back
    /// to scrolling sideways rather than pushing its ends under the tray's
    /// edges.
    private var categoryRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                categorySegments
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                categorySegments.padding(.horizontal, 2).padding(.vertical, 3)
            }
        }
        .frame(height: 58)
    }

    // MARK: - Filters

    private var filterRow: some View {
        HStack(spacing: 10) {
            if store.searchActive {
                SearchField()
            } else {
                Text(countLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
            }
            Spacer(minLength: 12)
            if narrowed { clearFilters }
            FilterDropdown(
                title: "Resolution",
                value: resolution,
                width: 190,
                options: { pickOptions(all: resolutionOptions, selection: resolution) { resolution = $0 } }
            )
            FilterDropdown(
                title: "FPS",
                value: fps,
                width: 160,
                options: { pickOptions(all: fpsOptions, selection: fps) { fps = $0 } }
            )
        }
        .frame(height: 44)
        .animation(.easeOut(duration: 0.18), value: narrowed)
    }

    private var countLine: String {
        let count = filtered.count
        let noun = count == 1 ? "wallpaper" : "wallpapers"
        if category == "All" { return "\(count) \(noun)" }
        return "\(count) \(noun) in \(category)"
    }

    private var clearFilters: some View {
        Button {
            resolution = "All"
            fps = "All"
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("Clear filters")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Color.muroAccent)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Capsule().fill(Color.muroAccent.opacity(0.13)))
            .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private func pickOptions(
        all: [String], selection: String, choose: @escaping (String) -> Void
    ) -> [MenuOption] {
        (["All"] + all).map { value in
            MenuOption(title: value, checked: selection == value) { choose(value) }
        }
    }

    // MARK: - Grid

    /// Cards carry the Library's trash button rather than a right-click menu.
    /// A wallpaper you downloaded can be sent away from here the same way it
    /// can from the Library, through the same confirmation, and the menu that
    /// used to be the only route to it is gone (owner, 2026-08-24).
    private var grid: some View {
        LazyVGrid(columns: gridColumns, spacing: 24) {
            ForEach(filtered) { item in
                WallpaperCard(item: item, persistentTitle: true, showsDelete: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.muroAccent)
                .frame(width: 54, height: 54)
                .background(Circle().fill(.glassSheen(0.14, 0.05)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            Text("Nothing matches that")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(store.searchText.isEmpty
                 ? "Try another category, or widen the resolution and frame rate."
                 : "No wallpaper called \(store.searchText). Try another word.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

/// A filter that opens a glass menu. Bigger than the pair Explore used to
/// carry (the owner asked for both the bubbles and the segments above them to
/// grow), and split into a grey name and a white value so the current setting
/// is the part you read.
struct FilterDropdown: View {
    var title: String
    var value: String
    var width: CGFloat = 190
    var options: () -> [MenuOption]

    @State private var hovering = false

    private var set: Bool { value != "All" }

    var body: some View {
        // Both of these sit at the right edge of the page, so the menu hangs
        // from their right edge. Anchored on the left it opened wider than the
        // pill and crossed the tray's edge.
        GlassDropdown(width: width, align: .trailing, options: options) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(set ? Color.muroAccent : .white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 18)
            .frame(height: 42)
            .background(Capsule().fill(.glassSheen(hovering ? 0.14 : 0.10, hovering ? 0.06 : 0.045)))
            .overlay(
                Capsule().strokeBorder(
                    set ? Color.muroAccent.opacity(0.35) : Color.white.opacity(hovering ? 0.2 : 0.13),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.16), value: hovering)
        }
    }
}

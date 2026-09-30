import SwiftUI
import MuroKit
import UniformTypeIdentifiers

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
    @State private var screenSavers: [AppleAerial] = []

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
                    PillOption(Kind.aerials.rawValue, "Aerials", count: model.aerials?.count),
                    PillOption(Kind.screenSavers.rawValue, "Screen Savers",
                               count: AppleScreenSavers.cached().count)
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

    private var downloadedCount: Int {
        (model.aerials ?? []).filter(\.isDownloaded).count
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
                WallpaperCard(item: aerial.wallpaperItem, persistentTitle: true)
                    .onAppear { fetcher.requestFrame(for: aerial) }
                    .onDisappear { fetcher.cancelFrame(for: aerial) }
            }
        }
    }

    // MARK: - Screen savers

    /// Apple's own screen savers, then the ones installed on this Mac, with a
    /// card for adding one. Only macOS runs these, so each is set the same
    /// way as Apple's pictures: see `AppleScreenSavers`.
    private var screenSaversPage: some View {
        ZStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    saverSection(
                        "APPLE", items: savers(in: AppleScreenSavers.appleGroup), adding: false)
                    saverSection(
                        "YOURS", items: savers(in: AppleScreenSavers.installedGroup), adding: true)
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .scrollFade(top: 20, bottom: 46)
        }
        .padding(.top, 18)
        .onAppear { screenSavers = AppleScreenSavers.refresh() }
    }

    private func savers(in group: String) -> [AppleAerial] {
        screenSavers.filter { saver in
            saver.category == group
                && (store.searchText.isEmpty || saver.name.localizedCaseInsensitiveContains(store.searchText))
        }
    }

    private func saverSection(_ title: String, items: [AppleAerial], adding: Bool) -> some View {
        let _ = fetcher.revision
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title, trailing: items.isEmpty ? nil : "\(items.count)")
            LazyVGrid(columns: gridColumns, spacing: 24) {
                ForEach(items) { saver in
                    WallpaperCard(item: saver.wallpaperItem, persistentTitle: true)
                        .onAppear { fetcher.requestFrame(for: saver) }
                }
                if adding { AddScreenSaverCard { addScreenSaver() } }
            }
        }
    }

    /// Copies a `.saver` into `~/Library/Screen Savers`, where macOS itself
    /// looks for them, so it works from System Settings too.
    private func addScreenSaver() {
        let panel = NSOpenPanel()
        panel.title = "Add a Screen Saver"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType("com.apple.screen-saver") ?? .bundle]
        guard panel.runModal() == .OK else { return }
        let folder = AppleScreenSavers.installedFolders[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in panel.urls where url.pathExtension == "saver" {
            let target = folder.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                store.importError = "\(url.lastPathComponent) could not be added. \(error.localizedDescription)"
            }
        }
        screenSavers = AppleScreenSavers.refresh()
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
            noMatchesState
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

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            emptyIcon("sparkle.magnifyingglass")
            Text("Nothing matches that")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(store.searchText.isEmpty
                 ? "Try another category."
                 : "No aerial called \(store.searchText). Try another word.")
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

/// The last card under Yours: a `.saver` file becomes a screen saver here.
/// The same shape as a wallpaper card, so the grid stays even.
private struct AddScreenSaverCard: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                VStack(spacing: 10) {
                    PlusBubble(size: 46, hovering: hovering)
                    Text("Add Screen Saver")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("A .saver file, like XScreenSaver")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.muroSecondary)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.glassSheen(hovering ? 0.08 : 0.05, hovering ? 0.035 : 0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.16 : 0.1), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onTapGesture(perform: action)
    }
}

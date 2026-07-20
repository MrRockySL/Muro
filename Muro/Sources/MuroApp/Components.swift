import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Image loading

enum ImageCache {
    static let cache = NSCache<NSString, NSImage>()

    static func image(path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// Local thumbnail from disk, or streamed catalog thumbnail for
/// not-yet-downloaded wallpapers.
struct ThumbImage: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem

    var body: some View {
        if let path = store.thumbnailPath(for: item), let image = ImageCache.image(path: path) {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let url = item.remote?.thumbnail {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.04)
                }
            }
        } else {
            Color.white.opacity(0.04)
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var store: AppStore
    @Namespace private var navNS

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                logo
                Spacer()
                actions
            }
            navPill
        }
        .padding(.leading, 92)   // clear of the traffic lights
        .padding(.trailing, 40)
        .padding(.top, 22)
    }

    private var logo: some View {
        HStack(spacing: 10) {
            MuroMark(cornerRadius: 8)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("Muro")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                CreditLink(text: "made by \(Credits.name)")
            }
        }
    }

    private var navPill: some View {
        HStack(spacing: 2) {
            ForEach(AppStore.Tab.allCases) { tab in
                let selected = store.tab == tab
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background {
                        if selected {
                            Capsule().fill(Color.white)
                                .matchedGeometryEffect(id: "navTab", in: navNS)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        store.switchTab(tab)
                        store.previewItem = nil
                    }
            }
        }
        .padding(5)
        .glassCapsule(fill: 0.08, stroke: 0.14)
        .animation(.easeOut(duration: 0.22), value: store.tab)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            IconCircleButton(systemName: "magnifyingglass") {
                store.searchActive.toggle()
                if store.searchActive, store.tab == .home { store.switchTab(.explore) }
                if !store.searchActive { store.searchText = "" }
            }
            ImportButton()
            IconCircleButton(systemName: "gearshape") {
                openSettingsWindow()
            }
        }
    }
}

/// The + button: file importer for the user's own videos.
struct ImportButton: View {
    @EnvironmentObject var store: AppStore
    @State private var showImporter = false

    var body: some View {
        IconCircleButton(systemName: "plus") { showImporter = true }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { store.importFiles(urls) }
            }
    }
}

@MainActor
func openSettingsWindow() {
    // Environment openWindow isn't reachable from plain helpers; the
    // Settings scene registers this callback at launch. Activate first —
    // when called from the (non-activating) menu bar panel the app isn't
    // active and the window would open behind others.
    NSApp.activate(ignoringOtherApps: true)
    SettingsWindowOpener.shared.open?()
}

@MainActor
final class SettingsWindowOpener {
    static let shared = SettingsWindowOpener()
    var open: (() -> Void)?
}

struct IconCircleButton: View {
    let systemName: String
    var size: CGFloat = 38
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.37, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassCapsule(fill: 0.08, stroke: 0.14)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Styled dropdown menus
// Replaces default NSMenu/`Menu` everywhere so every dropdown matches the
// app's dark rounded-glass look (owner feedback round 3).

struct MenuOption: Identifiable {
    let id = UUID()
    var title: String
    var checked = false
    var destructive = false
    var isDivider = false
    var action: () -> Void = {}

    static let divider = MenuOption(title: "", isDivider: true)
}

/// The rows themselves — used by GlassDropdown and by ad-hoc popovers
/// (e.g. the playlist right-click menu).
struct GlassMenuList: View {
    var width: CGFloat = 180
    var options: [MenuOption]
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(options) { option in
                if option.isDivider {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                } else {
                    GlassMenuRow(option: option, dismiss: dismiss)
                }
            }
        }
        .padding(5)
        .frame(width: width)
        .background(Color(hex: 0x14171D))
    }
}

private struct GlassMenuRow: View {
    let option: MenuOption
    var dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            dismiss()
            option.action()
        } label: {
            HStack(spacing: 8) {
                Text(option.title)
                    .font(.system(size: 12.5, weight: option.checked ? .semibold : .regular))
                    .foregroundStyle(option.destructive ? Color(hex: 0xFF6B6B) : .white)
                Spacer(minLength: 12)
                if option.checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.muroAccent)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A button that opens a GlassMenuList popover. Options are built lazily on
/// open so checkmarks always reflect current state.
struct GlassDropdown<Label: View>: View {
    var width: CGFloat = 170
    var arrowEdge: Edge = .bottom
    var options: () -> [MenuOption]
    @ViewBuilder var label: () -> Label

    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: arrowEdge) {
            GlassMenuList(width: width, options: options()) { open = false }
        }
    }
}

/// White-pill capsule segmented control (same language as the preview's
/// fps toggle) — replaces the stock segmented picker in Settings.
struct CapsuleSegments: View {
    var options: [(label: String, tag: String)]
    @Binding var selection: String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.tag) { option in
                let selected = selection == option.tag
                Text(option.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5.5)
                    .background {
                        if selected {
                            Capsule().fill(Color.white)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.16)) { selection = option.tag }
                    }
            }
        }
        .padding(3)
        .glassCapsule(fill: 0.07, stroke: 0.12)
    }
}

// MARK: - Right-click catcher

/// Invisible overlay that intercepts only right-clicks; left clicks and
/// hovers pass straight through to the SwiftUI views underneath.
struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.onRightClick = onRightClick
    }

    final class RightClickView: NSView {
        var onRightClick: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type,
                  type == .rightMouseDown || type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick()
        }
    }
}

// MARK: - Chips

struct AppliedChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.muroGreen).frame(width: 5.5, height: 5.5)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.95))
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Color.muroGreen.opacity(0.5), lineWidth: 1))
    }
}

struct FPSChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    }
}

struct NewBadge: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 9, weight: .bold))
            .tracking(1)
            .foregroundStyle(Color.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.muroAccent))
    }
}

struct HeartButton: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem
    var size: CGFloat = 30

    var body: some View {
        Button {
            store.toggleLike(item)
        } label: {
            Image(systemName: item.liked ? "heart.fill" : "heart")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(item.liked ? Color(hex: 0xFF6B6B) : .white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .disabled(!item.isDownloaded)
        .opacity(item.isDownloaded || item.liked ? 1 : 0.4)
    }
}

// MARK: - Wallpaper card

struct WallpaperCard: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem
    var persistentTitle = false

    @State private var hovering = false
    @State private var showMenu = false

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(ThumbImage(item: item))
            .overlay(alignment: .bottom) { titleOverlay }
            .overlay(alignment: .topLeading) { topLeadingChip }
            .overlay(alignment: .topTrailing) { topTrailingControls }
            .overlay(alignment: .bottomTrailing) { downloadState }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { store.openPreview(item) }
            .overlay { if removableDownload { RightClickCatcher { showMenu = true } } }
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                GlassMenuList(width: 200, options: [
                    MenuOption(
                        title: "Remove Download (\(formatSize(item.sizeBytes)))",
                        destructive: true
                    ) { store.removeDownload(item) }
                ]) { showMenu = false }
            }
    }

    /// Manual space control (owner decision 2026-07-18): only catalog
    /// wallpapers that aren't applied or in a playlist can be removed —
    /// user imports have no remote copy to re-download.
    private var removableDownload: Bool {
        item.isDownloaded && item.remote != nil
            && !store.protectedWallpaperIDs.contains(item.id)
    }

    @ViewBuilder private var titleOverlay: some View {
        if persistentTitle || hovering {
            VStack(alignment: .leading, spacing: 2) {
                if hovering && !persistentTitle {
                    Text(item.category.uppercased())
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Color.muroAccent)
                }
                Text(item.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 14)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }

    @ViewBuilder private var topLeadingChip: some View {
        let applied = store.appliedDisplays(for: item.id)
        if let first = applied.first {
            AppliedChip(label: applied.count > 1 ? "ALL DISPLAYS" : first.chipLabel)
                .padding(12)
        } else if store.isNew(item) {
            NewBadge().padding(12)
        }
    }

    @ViewBuilder private var topTrailingControls: some View {
        if item.liked || (hovering && item.isDownloaded) {
            HeartButton(item: item).padding(12)
        }
    }

    @ViewBuilder private var downloadState: some View {
        if let progress = store.downloads[item.id] {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(.white)
                .padding(12)
        } else if !item.isDownloaded {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.4)))
                .padding(12)
        }
    }
}

// MARK: - Credit link

/// Tiny "made by …" credit chip; opens the GitHub profile. Monospaced on a
/// dark capsule so it stays readable over bright hero videos.
struct CreditLink: View {
    var text: String
    var size: CGFloat = 8
    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(hovering ? Color.muroAccent : Color.white.opacity(0.78))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.38)))
            .overlay(
                Capsule().strokeBorder(
                    hovering ? Color.muroAccent.opacity(0.45) : Color.white.opacity(0.14),
                    lineWidth: 1
                )
            )
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture { NSWorkspace.shared.open(Credits.url) }
            .help("github.com/\(Credits.name)")
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Search field

struct SearchField: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.muroSecondary)
            TextField("Search wallpapers…", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 260)
        .glassCapsule(fill: 0.08, stroke: 0.14)
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Image loading

/// Bounded, downsampled thumbnail cache.
///
/// Thumbnails are 1280 px JPEGs. Loading them whole, as `NSImage(contentsOfFile:)`
/// does, keeps a 3.7 MB bitmap alive per wallpaper, and the cache had no size
/// limit at all, so scrolling the full catalog could hold hundreds of
/// megabytes in an app that promises to stay under 150.
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// A grid card is roughly 420 points wide, so 900 pixels covers it on a
    /// Retina display and nothing beyond that is ever drawn.
    static let gridPixels = 900
    /// For the two places a thumbnail is shown huge: the Home hero when it has
    /// no video to play, and the full window preview behind a loading p720.
    static let fullPixels = 2400

    private static func key(path: String, maxPixels: Int) -> NSString {
        "\(path)#\(maxPixels)" as NSString
    }

    /// Synchronous hit only. Lets a view paint in the very same frame when the
    /// picture is already in memory, with no blank flash.
    static func cached(path: String, maxPixels: Int) -> NSImage? {
        cache.object(forKey: key(path: path, maxPixels: maxPixels))
    }

    /// Decodes at reduced size through ImageIO, so only the pixels that will
    /// actually be drawn are ever allocated. Call this off the main thread.
    static func load(path: String, maxPixels: Int) -> NSImage? {
        if let hit = cached(path: path, maxPixels: maxPixels) { return hit }
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil
        ), let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary) else { return nil }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        cache.setObject(
            image,
            forKey: key(path: path, maxPixels: maxPixels),
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return image
    }
}

/// Local thumbnail from disk, or streamed catalog thumbnail for
/// not-yet-downloaded wallpapers.
///
/// The decode happens off the main thread. Doing it inside `body`, as this
/// used to, meant every card opened and decoded a JPEG while the grid was
/// being scrolled.
struct ThumbImage: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem
    var maxPixels: Int = ImageCache.gridPixels

    @State private var image: NSImage?

    var body: some View {
        let path = store.thumbnailPath(for: item)
        let ready = image ?? path.flatMap { ImageCache.cached(path: $0, maxPixels: maxPixels) }
        // The size comes from `Color.clear`, not from the picture.
        //
        // `scaledToFill` reports whatever size is needed to COVER what it was
        // offered, and that can be far larger than the offer. A timeline window
        // is about sixteen to one and a thumbnail is sixteen to nine, so a
        // full-width window 44 points tall asked for a picture 396 points tall.
        // Clipping the drawing hid it, but nothing clipped the layout, so the
        // picture's hit region reached a couple of hundred points above the
        // timeline and quietly swallowed every click in the wallpaper grid
        // overhead. Taking the size from a flexible view and clipping the
        // picture inside it keeps the whole thing the size it was offered.
        Color.clear
            .overlay {
                if let ready {
                    Image(nsImage: ready).resizable().scaledToFill()
                } else if path == nil, let url = item.remote?.thumbnail {
                    AsyncImage(url: url) { phase in
                        if let remote = phase.image {
                            remote.resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.04)
                        }
                    }
                } else {
                    Color.white.opacity(0.04)
                }
            }
            .clipped()
            // Decoration only. Whatever it sits in owns the click.
            .allowsHitTesting(false)
            .task(id: path) { await load(path: path) }
    }

    private func load(path: String?) async {
        guard let path else {
            image = nil
            return
        }
        if let hit = ImageCache.cached(path: path, maxPixels: maxPixels) {
            image = hit
            return
        }
        let pixels = maxPixels
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageCache.load(path: path, maxPixels: pixels)
        }.value
        // A scrolled-away card may have been reused for another wallpaper
        // while this was decoding.
        guard path == store.thumbnailPath(for: item) else { return }
        image = loaded
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

    /// Search, What's New, import and settings.
    ///
    /// All four are the Library's import bubble: same glass, same accent
    /// light, same lift under the pointer and dip on the press. They used to
    /// be flat 8% circles with a grey SF Symbol in them, which is the one
    /// piece of 2.0 chrome the 3.0 pages had left standing.
    private var actions: some View {
        HStack(spacing: 12) {
            GlassBubbleButton(
                systemName: "magnifyingglass",
                glyphScale: 0.42,
                active: store.searchActive,
                help: "Search wallpapers"
            ) {
                store.searchActive.toggle()
                if store.searchActive, store.tab == .home { store.switchTab(.explore) }
                if !store.searchActive { store.searchText = "" }
            }
            whatsNew
            ImportButton()
            GlassBubbleButton(
                systemName: "gearshape",
                glyphScale: 0.44,
                turns: true,
                help: "Settings"
            ) {
                openSettingsWindow()
            }
        }
    }
}

extension TopBar {
    /// What's New, and the two ways an update announces itself: a dot on the
    /// button that stays until the sheet is opened, and a bubble under it that
    /// says so in words, once per version.
    ///
    /// The bubble is an overlay with a fixed height reservation rather than a
    /// popover: a popover would steal the click, dim the window behind it, and
    /// bring back the grey system chrome this release spent a day removing.
    fileprivate var whatsNew: some View {
        let update = store.updateAvailable != nil
        return GlassBubbleButton(
            systemName: "sparkles",
            glyphScale: 0.44,
            active: store.whatsNewOpen,
            badged: update,
            help: update ? "A new version of Muro is available" : "What's New in Muro"
        ) {
            store.whatsNewOpen = true
            store.markUpdateSeen()
        }
        .overlay(alignment: .top) {
            UpdateCallout(visible: store.updateCalloutVisible) {
                store.whatsNewOpen = true
                store.markUpdateSeen()
            } dismiss: {
                store.markUpdateSeen()
            }
            // Hangs below the bubble, over the page. Zero-height frame so it
            // cannot widen the top bar and push the nav pill off centre.
            .offset(y: 46)
            .frame(width: 0, height: 0, alignment: .top)
        }
    }
}

/// "New update available", in a small glass bubble with a pointer, under the
/// What's New button.
struct UpdateCallout: View {
    var visible: Bool
    var open: () -> Void
    var dismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color.muroAccent.opacity(0.9))
                .frame(width: 14, height: 7)
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("New update available")
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.75)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(Color.muroAccent.opacity(hovering ? 0.98 : 0.9))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: Color.muroAccent.opacity(0.45), radius: 14, y: 5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.86, anchor: .top)
        .offset(y: visible ? 0 : -6)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: visible)
        .allowsHitTesting(visible)
    }
}

/// The callout's pointer.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The + button: file importer for the user's own videos. The same bubble as
/// the Library's drop zone, so importing looks like one gesture wherever it
/// is offered.
struct ImportButton: View {
    @EnvironmentObject var store: AppStore
    var size: CGFloat = 42

    @State private var showImporter = false
    @State private var hovering = false

    var body: some View {
        Button { showImporter = true } label: {
            // White here, accent in the Library. Same bubble, but the top bar
            // is chrome and the Library's is the page's own call to action.
            PlusGlyph(span: size * 0.36, thickness: size * 0.054, colour: .white)
                .shadow(color: Color.white.opacity(0.45), radius: hovering ? 5 : 3)
        }
        .buttonStyle(BubbleButtonStyle(size: size, hovering: hovering, active: false, tint: .white))
        .onHover { hovering = $0 }
        .help("Import your own video")
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { store.importFiles(urls) }
        }
    }
}

/// Muro's two `Window` scenes, by the titles SwiftUI gives them.
enum MuroWindow {
    static let gallery = "Muro"
    static let settings = "Muro Settings"
}

@MainActor
func window(titled title: String) -> NSWindow? {
    NSApp.windows.first { $0.title == title }
}

/// The gallery window itself. `Window("Muro", id: "main")` is a SwiftUI scene,
/// and closing it only orders it out, so it can always be brought back.
@MainActor
var mainWindow: NSWindow? { window(titled: MuroWindow.gallery) }

/// Bring the gallery forward. Three places needed the same three lines, and
/// the app delegate now needs them too when the Dock icon or Spotlight asks
/// for a window that is only ordered out.
@MainActor
func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    mainWindow?.makeKeyAndOrderFront(nil)
}

/// Make a window's yellow button put it away rather than minimise it.
///
/// A minimised window is a different thing from an app icon, and the Dock
/// treats it that way: `.accessory` hides the icon, it does not hide a
/// minimised window. So with "Show Dock icon" switched off, minimising left a
/// lone Muro thumbnail parked beside the Trash with no app icon to belong to,
/// and nothing obvious to do about it.
///
/// Muro lives in the menu bar. Putting a window away should put it away, and
/// the menu bar is how the gallery comes back, exactly like the red button.
/// The button is left enabled and yellow rather than removing
/// `.miniaturizable`, because a dead greyed-out button reads as broken.
///
/// **Every window scene has to ask for this.** Doing only the gallery left
/// Settings minimising into the Dock exactly as before, which is how the first
/// version of this shipped.
@MainActor
func makeMinimiseHideTheWindow(titled title: String) {
    guard let button = window(titled: title)?.standardWindowButton(.miniaturizeButton)
    else { return }
    button.target = WindowButtonTarget.shared
    button.action = #selector(WindowButtonTarget.hideWindow(_:))
}

/// Owns the retargeted button action. A plain function cannot be a `#selector`
/// target, and a button does not retain its target, so this has to outlive it.
@MainActor
final class WindowButtonTarget: NSObject {
    static let shared = WindowButtonTarget()

    /// The sender is the button, so it knows its own window. One target can
    /// serve every window rather than one per scene.
    @objc func hideWindow(_ sender: Any?) {
        (sender as? NSView)?.window?.orderOut(nil)
    }
}

/// Bring the gallery forward and open What's New on it. The menu bar and
/// Settings both point their "update available" line here, so there is one
/// place in the app where an update is read about and downloaded.
@MainActor
func openWhatsNew(_ store: AppStore) {
    StatusBarController.shared?.closePanel()
    showMainWindow()
    store.whatsNewOpen = true
    store.markUpdateSeen()
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
                        .fill(Color.white.opacity(0.09))
                        .frame(height: 1)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                } else {
                    GlassMenuRow(option: option, dismiss: dismiss)
                }
            }
        }
        .padding(7)
        .frame(width: width)
        .glassCard()
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
                    .font(.system(size: 12.5, weight: option.checked ? .semibold : .medium))
                    .foregroundStyle(option.destructive ? Color.muroDanger : .white.opacity(0.92))
                Spacer(minLength: 12)
                if option.checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.muroAccent)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        option.destructive
                            ? Color.muroDanger.opacity(hovering ? 0.12 : 0)
                            : Color.white.opacity(hovering || option.checked ? 0.10 : 0)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A button that opens a GlassMenuList popover. Options are built lazily on
/// open so checkmarks always reflect current state.
struct GlassDropdown<Label: View>: View {
    var width: CGFloat = 170
    /// Kept for the menu bar panel, which opens its menus in a panel of their
    /// own. Inside a window the menu places itself.
    var arrowEdge: Edge = .bottom
    /// Which edge of the menu lines up with this control. See `MenuAlign`.
    var align: MenuAlign = .leading
    var options: () -> [MenuOption]
    @ViewBuilder var label: () -> Label

    var body: some View {
        MenuButton(width: width, align: align, options: options, label: label)
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
                // Monitors name themselves, and some of them are wordy. One
                // line whatever they are called.
                .lineLimit(1)
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

/// Bottom-right twin of `HeartButton`: same 30 pt circle, same black wash,
/// opposite corner. It shares that corner with the download icon, which is
/// only ever shown while a wallpaper is NOT downloaded, and delete only ever
/// applies once it is, so the two can never be on a card at the same time.
///
/// The black wash stays under the red on hover. A tint alone would leave the
/// glyph sitting on whatever the thumbnail happens to be, and half these
/// wallpapers are bright.
struct DeleteButton: View {
    var size: CGFloat = 30
    var action: () -> Void

    @State private var hovering = false

    private static let danger = Color(hex: 0xFF6B6B)

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(hovering ? Self.danger : .white)
                .frame(width: size, height: size)
                .background(
                    ZStack {
                        Circle().fill(Color.black.opacity(0.4))
                        Circle().fill(Self.danger.opacity(hovering ? 0.22 : 0))
                    }
                )
                .overlay(
                    Circle().strokeBorder(
                        Self.danger.opacity(hovering ? 0.45 : 0), lineWidth: 1
                    )
                )
                .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Delete wallpaper")
    }
}

/// The accent tick used wherever wallpapers are picked: the playlist editor,
/// the automation editor, and Library select mode.
struct SelectionTick: View {
    let isSelected: Bool
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(isSelected ? Color.muroAccent : Color.black.opacity(0.45))
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Color.black)
            } else {
                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Wallpaper card

struct WallpaperCard: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem
    var persistentTitle = false
    /// Library only. Explore and Home show wallpapers you may not own yet,
    /// where a trash can would be meaningless.
    var showsDelete = false
    /// Select mode: the card stops opening the preview and starts toggling a
    /// checkmark instead. `nil` means the grid is not in select mode at all.
    var selection: Binding<Set<String>>?

    @State private var hovering = false

    /// The two hover controls rise and spring into place rather than blinking
    /// on. Deliberately quicker than the card's own 1.015 hover scale, so the
    /// control lands before the card has finished settling under it.
    private static let controlPop = Animation.spring(response: 0.22, dampingFraction: 0.72)

    private static let popIn: AnyTransition = .scale(scale: 0.82)
        .combined(with: .opacity)
        .combined(with: .offset(y: 4))

    private var isSelected: Bool { selection?.wrappedValue.contains(item.id) ?? false }
    private var selecting: Bool { selection != nil }

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(ThumbImage(item: item))
            .overlay { if selecting && isSelected { Color.muroAccent.opacity(0.14) } }
            .overlay(alignment: .bottom) { titleOverlay }
            .overlay(alignment: .topLeading) { topLeadingChip }
            .overlay(alignment: .topTrailing) {
                topTrailingControls.animation(Self.controlPop, value: hovering)
            }
            .overlay(alignment: .bottomTrailing) {
                bottomTrailingControls.animation(Self.controlPop, value: hovering)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.muroAccent.opacity(0.85) : Color.white.opacity(0.07),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                if let selection {
                    if isSelected { selection.wrappedValue.remove(item.id) }
                    else { selection.wrappedValue.insert(item.id) }
                } else {
                    store.openPreview(item)
                }
            }
            .glassContextMenu(width: 210) { selecting ? [] : menuOptions }
    }

    /// Outside the Library a wallpaper is usually only about reclaiming space
    /// on something that stays a download away, so the menu says Remove
    /// Download.
    ///
    /// The Library itself has no menu at all. Every card there already carries
    /// a trash button, and a right-click offering the same delete is a second
    /// way to do a thing that is already one click away (owner, 2026-08-24).
    ///
    /// The exception is a video the user imported themselves. It appears in
    /// Explore alongside the catalog, but there is no copy of it anywhere to
    /// download again, so "Remove Download" would be a lie. It gets the Delete
    /// wording wherever it is shown outside the Library.
    private var menuOptions: [MenuOption] {
        guard item.isDownloaded, !showsDelete else { return [] }
        if item.remote == nil {
            return [MenuOption(
                title: "Delete Wallpaper (\(formatSize(item.sizeBytes)))",
                destructive: true
            ) { store.requestDelete([item]) }]
        }
        if removableDownload {
            return [MenuOption(
                title: "Remove Download (\(formatSize(item.sizeBytes)))",
                destructive: true
            ) { store.removeDownload(item) }]
        }
        return []
    }

    /// Manual space control (owner decision 2026-07-18): outside the Library
    /// only catalog wallpapers that aren't applied or in a playlist offer
    /// this, because it is framed as freeing space rather than losing
    /// anything. Imports are handled by the Delete branch above.
    private var removableDownload: Bool {
        item.remote != nil && !store.protectedWallpaperIDs.contains(item.id)
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
            // Room kept for the trash button whether or not it is showing, so
            // a long title never reflows the moment the pointer arrives.
            .padding(.trailing, showsDelete ? 34 : 0)
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
        if let label = store.appliedChipLabel(for: item.id) {
            AppliedChip(label: label)
                .padding(12)
        } else if store.isNew(item) {
            NewBadge().padding(12)
        }
    }

    @ViewBuilder private var topTrailingControls: some View {
        if selecting {
            SelectionTick(isSelected: isSelected).padding(12)
        } else if item.liked {
            HeartButton(item: item).padding(12)
        } else if hovering && item.isDownloaded {
            HeartButton(item: item).padding(12).transition(Self.popIn)
        }
    }

    /// One corner, one control. The progress ring and the download arrow
    /// belong to a wallpaper that is not here yet; the trash belongs to one
    /// that is. Writing them as a single chain is what makes that exclusive.
    @ViewBuilder private var bottomTrailingControls: some View {
        if selecting {
            EmptyView()
        } else if let progress = store.downloads[item.id] {
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
        } else if showsDelete && hovering {
            DeleteButton { store.requestDelete([item]) }
                .padding(12)
                .transition(Self.popIn)
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

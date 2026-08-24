import SwiftUI
import UniformTypeIdentifiers
import MuroKit

struct LibraryView: View {
    @EnvironmentObject var store: AppStore

    enum LibTab: String, CaseIterable {
        case all = "All", liked = "Liked", playlists = "Playlists", automations = "Automations"
    }

    @State private var tab: LibTab = .all
    @State private var dropTargeted = false
    @State private var hoveringDrop = false
    @State private var pressingDrop = false
    @State private var editorTarget: PlaylistEditorTarget?
    @State private var automationTarget: AutomationEditorTarget?
    @State private var selecting = false
    @State private var selected: Set<String> = []

    private let gridColumns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    /// Playlists and automations are wide cards, two to a row.
    private let cardColumns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    private var searched: [WallpaperItem] {
        store.localItems.filter { item in
            store.searchText.isEmpty
                || item.title.localizedCaseInsensitiveContains(store.searchText)
                || item.category.localizedCaseInsensitiveContains(store.searchText)
        }
    }

    var body: some View {
        ZStack {
            MuroPageBackground()
            GlassTray {
                VStack(alignment: .leading, spacing: 0) {
                    tabsRow
                        .padding(.horizontal, 40)
                        .padding(.top, 34)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 22) {
                            switch tab {
                            case .all:
                                if !selecting { dropZone }
                                grid(items: searched)
                            case .liked:
                                grid(items: searched.filter(\.liked))
                            case .playlists:
                                playlistsGrid
                            case .automations:
                                automationsGrid
                            }
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 22)
                        .padding(.bottom, 40)
                        // Each tab is its own view, so SwiftUI crossfades
                        // them instead of swapping the contents of one.
                        .id(tab)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    .scrollFade(top: 22, bottom: 46)
                    .animation(.easeOut(duration: 0.24), value: tab)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 88)
            .padding(.bottom, 20)
        }
        .overlay(alignment: .bottom) {
            if selecting && !selected.isEmpty { batchBar.padding(.bottom, 40) }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: selected.isEmpty)
        .animation(.easeOut(duration: 0.18), value: selecting)
        // Esc is the way out of every other mode in the app, so it is the way
        // out of this one.
        .onExitCommand { endSelecting() }
        .onChange(of: tab) { _, new in
            if new != .all && new != .liked { endSelecting() }
        }
        // After a batch delete the ids are gone but the set is not, which
        // would leave the bar counting wallpapers that no longer exist.
        .onChange(of: store.localItems.count) { _, _ in
            guard selecting else { return }
            let alive = Set(store.localItems.map(\.id))
            selected.formIntersection(alive)
        }
        .sheet(item: $editorTarget) { target in
            PlaylistEditorView(target: target)
                .environmentObject(store)
        }
        .sheet(item: $automationTarget) { target in
            AutomationEditorView(target: target)
                .environmentObject(store)
        }
    }

    // MARK: - Tabs

    /// The four tabs are one glass capsule, centred in the tray. They used to
    /// be four separate pills jammed into the left corner, which made the
    /// library look like a toolbar rather than a place.
    private var tabsRow: some View {
        ZStack {
            PillSegments(
                options: [
                    PillOption(LibTab.all.rawValue, "All", count: store.localItems.count),
                    PillOption(LibTab.liked.rawValue, "Liked", count: store.likedItems.count),
                    PillOption(LibTab.playlists.rawValue, "Playlists", count: store.playlists.count),
                    PillOption(LibTab.automations.rawValue, "Automations", count: store.automations.count)
                ],
                selection: Binding(
                    get: { tab.rawValue },
                    set: { raw in if let new = LibTab(rawValue: raw) { tab = new } }
                ),
                height: 38,
                labelSize: 13
            )
            HStack(spacing: 8) {
                if store.searchActive { SearchField() }
                Spacer(minLength: 12)
                if selecting { selectAllButton }
                if tab == .all || tab == .liked { selectPill }
            }
        }
        .frame(height: 48)
    }

    // MARK: - Select mode

    private var visibleItems: [WallpaperItem] {
        tab == .liked ? searched.filter(\.liked) : searched
    }

    private var selectedItems: [WallpaperItem] {
        visibleItems.filter { selected.contains($0.id) }
    }

    private func endSelecting() {
        selecting = false
        selected = []
    }

    private var selectPill: some View {
        Button {
            if selecting { endSelecting() } else { selecting = true }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selecting ? "xmark" : "checkmark.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(selecting ? "Done" : "Select")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(selecting ? Color.black : Color.white.opacity(0.88))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background {
                if selecting {
                    Capsule().fill(Color.white)
                } else {
                    Capsule().fill(.glassSheen(0.10, 0.045))
                }
            }
            .overlay {
                if !selecting { Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
    }

    private var selectAllButton: some View {
        let all = Set(visibleItems.map(\.id))
        let everything = !all.isEmpty && selected.isSuperset(of: all)
        return Button(everything ? "Select None" : "Select All") {
            selected = everything ? [] : all
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Color.muroAccent)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color.muroAccent.opacity(0.13)))
        .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.28), lineWidth: 1))
    }

    /// Floating bar, deliberately not a row in the layout: it appears over the
    /// grid without pushing anything, the way the pill bar does in the preview.
    private var batchBar: some View {
        HStack(spacing: 14) {
            Text("\(selected.count) selected")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 18)
            Button("Clear") { selected = [] }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.muroSecondary)
                .lineLimit(1)
                .fixedSize()
            Button {
                store.requestDelete(selectedItems)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Delete")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundStyle(Color.muroDanger)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.muroDanger.opacity(0.15)))
                .overlay(Capsule().strokeBorder(Color.muroDanger.opacity(0.42), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        // The bar sizes itself and nothing else gets a say. It floats over
        // the grid, so there is no reason for it to negotiate a width, and
        // when it did it settled on one too small to spell "Delete".
        .fixedSize()
        .liquidGlass(cornerRadius: 99, tint: 0.3, stroke: 0.16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Import drop zone

    /// The dashed rectangle is gone. A glass bubble with accent light behind
    /// the "+" says "put something here" without drawing a border that looks
    /// like a placeholder someone forgot to style.
    private var dropZone: some View {
        // Lit when a file is over it OR when the pointer is on it, because
        // the two mean the same thing to the person doing it.
        let lit = dropTargeted || hoveringDrop
        return HStack(spacing: 20) {
            PlusBubble(size: 56, hovering: lit, pressed: pressingDrop)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.importStatus ?? "Drop videos here, or click to import")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("MP4, MOV and M4V supported")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.muroSecondary)
            }
            Spacer(minLength: 12)
            if store.importStatus != nil {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 100)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.glassSheen(lit ? 0.12 : 0.075, lit ? 0.05 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    dropTargeted ? Color.muroAccent.opacity(0.65)
                        : Color.white.opacity(lit ? 0.2 : 0.12),
                    lineWidth: dropTargeted ? 1.5 : 1
                )
        )
        .shadow(color: dropTargeted ? Color.muroAccent.opacity(0.22) : .clear, radius: 16, y: 4)
        .scaleEffect(pressingDrop ? 0.994 : 1)
        .animation(.easeOut(duration: 0.18), value: lit)
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: pressingDrop)
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onHover { hoveringDrop = $0 }
        // A plain tap gesture gives no press state at all, and the file panel
        // takes a beat to appear, so the click read as a dead click.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressingDrop = true }
                .onEnded { value in
                    pressingDrop = false
                    let travel = abs(value.translation.width) + abs(value.translation.height)
                    if travel < 6 { pickFiles() }
                }
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            store.importFiles(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }
        let storeRef = store
        group.notify(queue: .main) {
            Task { @MainActor in storeRef.importFiles(urls) }
        }
        return found
    }

    // MARK: - Wallpaper grid

    private func grid(items: [WallpaperItem]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 24) {
            ForEach(items) { item in
                WallpaperCard(
                    item: item,
                    persistentTitle: true,
                    showsDelete: !selecting,
                    selection: selecting ? $selected : nil
                )
            }
        }
    }

    // MARK: - Playlists

    private var playlistsGrid: some View {
        LazyVGrid(columns: cardColumns, spacing: 24) {
            ForEach(store.playlists) { playlist in
                PlaylistCard(playlist: playlist) {
                    editorTarget = .edit(playlist)
                }
            }
            NewThingCard(
                title: "New Playlist",
                subtitle: "Pick wallpapers and cycle them on a schedule",
                height: 200
            ) { editorTarget = .new }
        }
    }

    // MARK: - Automations

    private var automationsGrid: some View {
        LazyVGrid(columns: cardColumns, spacing: 24) {
            ForEach(store.automations) { automation in
                AutomationCard(automation: automation) {
                    automationTarget = .edit(automation)
                }
            }
            NewThingCard(
                title: "New Automation",
                subtitle: "Give each wallpaper its own time of day, or its own length",
                height: 216
            ) { automationTarget = .new }
        }
    }
}

/// The "add one" card in the playlist and automation grids. It is the drop
/// zone's bubble at card size, so the three ways of creating something in the
/// Library look like the same gesture.
struct NewThingCard: View {
    var title: String
    var subtitle: String
    var height: CGFloat
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 12) {
            PlusBubble(size: 60, hovering: hovering)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.glassSheen(hovering ? 0.08 : 0.05, hovering ? 0.035 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.16 : 0.1), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onTapGesture(perform: action)
    }
}

// MARK: - Playlist card

struct PlaylistCard: View {
    @EnvironmentObject var store: AppStore
    let playlist: Playlist
    var onEdit: () -> Void = {}

    @State private var hovering = false

    private var isActive: Bool { store.activePlaylistID == playlist.id }

    private var thumbs: [WallpaperItem] {
        playlist.wallpaperIDs.compactMap { store.item(id: $0) }
    }

    private var intervalText: String {
        switch playlist.intervalMinutes {
        case ..<60: return "Every \(playlist.intervalMinutes) min"
        case 60: return "Every hour"
        default: return "Every \(playlist.intervalMinutes / 60) hr"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(playlist.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if isActive { PlayingChip() }
                Spacer(minLength: 8)
                GlassPlayButton(playing: isActive) {
                    isActive ? store.stopPlaylist() : store.startPlaylist(playlist)
                }
            }
            // Three facts, three chips. The old single sentence ran them
            // together and none of them could be read at a glance.
            HStack(spacing: 8) {
                MetaChip(systemImage: "rectangle.stack", text: "\(playlist.wallpaperIDs.count) wallpapers")
                MetaChip(systemImage: "clock", text: intervalText)
                MetaChip(systemImage: "shuffle", text: playlist.shuffle ? "Shuffle on" : "Shuffle off")
            }
            .padding(.top, 11)
            Spacer(minLength: 8)
            ThumbStrip(items: thumbs)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 200)
        .glassPanel(active: isActive, top: hovering ? 0.085 : 0.065)
        .scaleEffect(hovering ? 1.006 : 1)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onHover { hovering = $0 }
        .onTapGesture { onEdit() }
        // Custom right-click menu in the app's glass style instead of the
        // stock macOS context menu.
        .glassContextMenu(width: 190) { menuOptions }
    }

    private var menuOptions: [MenuOption] {
        [
            MenuOption(title: isActive ? "Stop" : "Play") {
                isActive ? store.stopPlaylist() : store.startPlaylist(playlist)
            },
            MenuOption(title: "Edit Playlist") { onEdit() },
            MenuOption(title: playlist.shuffle ? "Shuffle Off" : "Shuffle On") {
                var updated = playlist
                updated.shuffle.toggle()
                store.updatePlaylist(updated)
            },
            .divider,
            MenuOption(title: "Delete Playlist", destructive: true) {
                store.deletePlaylist(playlist)
            }
        ]
    }
}

/// The row of covers along the bottom of a card.
struct ThumbStrip: View {
    let items: [WallpaperItem]
    var height: CGFloat = 81

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, item in
                cover(item, overflow: nil)
            }
            if items.count > 3 {
                cover(items[3], overflow: items.count - 3)
            }
            if items.count < 4 {
                ForEach(items.count..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                }
            }
        }
    }

    private func cover(_ item: WallpaperItem, overflow: Int?) -> some View {
        Color.black
            .overlay(ThumbImage(item: item, maxPixels: 360))
            .overlay {
                if let overflow {
                    ZStack {
                        Color.black.opacity(0.55)
                        Text("+\(overflow)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

// MARK: - Automation card

/// The same card as `PlaylistCard`, because an automation is the same idea
/// with a richer schedule. What it adds is the schedule made visible: a clock
/// automation draws the day, a timer automation stamps each step's length on
/// its own cover.
struct AutomationCard: View {
    @EnvironmentObject var store: AppStore
    let automation: Automation
    var onEdit: () -> Void = {}

    @State private var hovering = false

    private var isActive: Bool { store.activeAutomationID == automation.id }

    private var thumbs: [WallpaperItem] {
        automation.steps.compactMap { store.item(id: $0.wallpaperID) }
    }

    private var chips: [MetaChip] {
        let count = automation.steps.count
        let wallpapers = MetaChip(
            systemImage: "rectangle.stack",
            text: "\(count) wallpaper\(count == 1 ? "" : "s")"
        )
        switch automation.mode {
        case .timer:
            return [wallpapers, MetaChip(systemImage: "arrow.triangle.2.circlepath",
                                         text: "\(durationLabel(automation.cycleSeconds)) cycle")]
        case .clock:
            let gaps = automation.uncoveredWindows
            return [
                wallpapers,
                gaps.isEmpty
                    ? MetaChip(systemImage: "checkmark.circle", text: "Covers the whole day")
                    : MetaChip(systemImage: "exclamationmark.triangle",
                               text: "\(gaps.count) gap\(gaps.count == 1 ? "" : "s")",
                               tint: Color.muroWarn)
            ]
        }
    }

    /// While a clock automation runs, what it is showing now is more useful
    /// than what it will show later.
    private var nowLine: String? {
        guard isActive, automation.mode == .clock,
              let step = automation.clockStep(at: AutomationScheduler.minuteOfDay()),
              let item = store.item(id: step.wallpaperID)
        else { return nil }
        return "Now: \(item.title) until \(clockLabel(step.end))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Text(automation.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                MetaChip(
                    systemImage: automation.mode == .clock ? "clock" : "timer",
                    text: automation.mode == .clock ? "CLOCK" : "TIMER",
                    tint: Color.muroAccent
                )
                if isActive { PlayingChip() }
                Spacer(minLength: 8)
                GlassPlayButton(playing: isActive, enabled: !automation.steps.isEmpty) {
                    isActive ? store.stopAutomation() : store.startAutomation(automation)
                }
            }
            HStack(spacing: 8) { ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in chip } }
                .padding(.top, 11)
            Spacer(minLength: 8)
            schedule
            if let nowLine {
                Text(nowLine)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.muroAccent.opacity(0.95))
                    .lineLimit(1)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 216)
        .glassPanel(active: isActive, top: hovering ? 0.085 : 0.065)
        .scaleEffect(hovering ? 1.006 : 1)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onHover { hovering = $0 }
        .onTapGesture { onEdit() }
        .glassContextMenu(width: 200) { menuOptions }
    }

    @ViewBuilder private var schedule: some View {
        switch automation.mode {
        case .clock:
            DayTimelineStrip(automation: automation, height: 40)
                .padding(.bottom, nowLine == nil ? 12 : 0)
        case .timer:
            HStack(spacing: 10) {
                ForEach(Array(automation.steps.prefix(4).enumerated()), id: \.offset) { index, step in
                    timerStep(step, index: index)
                }
                if automation.steps.isEmpty {
                    Text("No wallpapers in this automation yet")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.muroSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 81)
                }
            }
            .padding(.bottom, nowLine == nil ? 12 : 0)
        }
    }

    private func timerStep(_ step: Automation.Step, index: Int) -> some View {
        Color.black
            .overlay {
                if let item = store.item(id: step.wallpaperID) {
                    ThumbImage(item: item, maxPixels: 360)
                }
            }
            .overlay(alignment: .topLeading) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .padding(8)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(durationLabel(step.duration))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 8)
                    .frame(height: 19)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .padding(8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 81)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }

    private var menuOptions: [MenuOption] {
        [
            MenuOption(title: isActive ? "Stop" : "Play") {
                isActive ? store.stopAutomation() : store.startAutomation(automation)
            },
            MenuOption(title: "Edit Automation") { onEdit() },
            .divider,
            MenuOption(title: "Delete Automation", destructive: true) {
                store.deleteAutomation(automation)
            }
        ]
    }
}

// MARK: - Playlist editor

enum PlaylistEditorTarget: Identifiable {
    case new
    case edit(Playlist)

    var id: String {
        if case .edit(let playlist) = self { return playlist.id }
        return "new"
    }
}

/// Create/edit sheet: name, which wallpapers, how often, shuffle. The schedule
/// used to live as one dropdown in the footer; it is a section of its own now,
/// because how often a playlist changes is the whole point of having one.
struct PlaylistEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: PlaylistEditorTarget

    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var intervalMinutes = 30
    @State private var shuffle = false
    @State private var loaded = false
    @State private var showCustomInterval = false
    /// Whether the bar is sitting on "Custom". Kept separately from the value
    /// because pressing Custom has to move the white pill straight away, and
    /// at that moment the interval is still whatever preset it was.
    @State private var customSelected = false
    @State private var segmentFrames: [String: CGRect] = [:]

    /// The intervals with their own segment. Anything else is "Custom".
    private static let presets = [15, 30, 60, 180]

    /// Short enough to stay on one line. "Every 15 min" wrapped and made that
    /// one segment taller than the bar around it.
    private static func shortLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr"
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty && !selected.isEmpty && nameProblem == nil }

    /// Two playlists called "New Playlist" are impossible to tell apart in the
    /// menu bar, in the apply panel and in the Library itself, so the name has
    /// to be its own. Compared without case or surrounding spaces, because
    /// "new playlist " reads as the same name to a person.
    private var nameProblem: String? {
        let name = trimmedName
        guard !name.isEmpty else { return nil }
        let existing = store.playlists.map { (id: $0.id, name: $0.name) }
        return nameIsTaken(name, in: existing, excluding: editingID)
            ? "Name already in use" : nil
    }

    private var editingID: String? {
        if case .edit(let playlist) = target { return playlist.id }
        return nil
    }

    private var intervalIsCustom: Bool {
        customSelected || !Self.presets.contains(intervalMinutes)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: isNew ? "New Playlist" : "Edit Playlist") { dismiss() }
                .padding(.horizontal, 26)
                .padding(.top, 26)
            GlassTextField(
                label: "NAME", placeholder: "Playlist name",
                text: $name, problem: nameProblem
            )
            .padding(.horizontal, 26)
            .padding(.top, 20)

            SectionLabel("CHANGE WALLPAPER EVERY")
                .padding(.horizontal, 26)
                .padding(.top, 22)
            HStack(spacing: 14) {
                PillSegments(
                    options: Self.presets.map { PillOption("\($0)", Self.shortLabel($0)) }
                        + [PillOption("custom", "Custom")],
                    selection: Binding(
                        get: { intervalIsCustom ? "custom" : "\(intervalMinutes)" },
                        set: { raw in
                            if let minutes = Int(raw) {
                                intervalMinutes = minutes
                                customSelected = false
                            } else {
                                // The pill moves the moment Custom is pressed,
                                // not when a value comes back from the card.
                                // Otherwise the bar reads "3 hr" while the
                                // custom picker is open in front of it.
                                customSelected = true
                                showCustomInterval = true
                            }
                        }
                    ),
                    height: 34,
                    labelSize: 12,
                    horizontalPadding: 15,
                    onSegmentFrames: { segmentFrames = $0 }
                )
                // The card hangs off the Custom segment, not off the whole
                // bar. Anchored to the bar it opened under "15 min", a long
                // way from the thing that was pressed.
                .overlay(alignment: .topLeading) {
                    let slot = segmentFrames["custom"] ?? .zero
                    Color.clear
                        .frame(width: max(slot.width, 1), height: max(slot.height, 1))
                        .anchoredCard(isPresented: $showCustomInterval, width: 272, align: .center) {
                            CustomIntervalPicker(minutes: $intervalMinutes) {
                                showCustomInterval = false
                            }
                        }
                        .padding(.leading, slot.minX)
                        .padding(.top, slot.minY)
                        // Measuring only. Without this the clear box sits on
                        // top of the segment it is measuring and swallows the
                        // press that is supposed to open the card.
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
                shuffleToggle
            }
            .padding(.horizontal, 26)
            .padding(.top, 10)

            HStack(spacing: 10) {
                SectionLabel("CHOOSE WALLPAPERS")
                Spacer()
                Text("\(selected.count) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                selectAllButton
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)

            // Our own scroller. A library that runs past the bottom of the
            // grid has to say so, and AppKit's own indicator is either absent
            // or the wide grey legacy one. See `GlassScrollView`.
            GlassScrollView(fadeTop: 14, fadeBottom: 24) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.localItems) { item in
                        PickerTile(
                            item: item,
                            selected: selected.contains(item.id),
                            titleSize: 11
                        ) {
                            if selected.contains(item.id) { selected.remove(item.id) }
                            else { selected.insert(item.id) }
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }

            SheetFooter {
                Text(summaryLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
            } actions: {
                if !isNew {
                    DangerPill(title: "Delete") {
                        if case .edit(let playlist) = target { store.deletePlaylist(playlist) }
                        dismiss()
                    }
                }
                GhostPill(title: "Cancel") { dismiss() }
                PrimaryPill(title: isNew ? "Create Playlist" : "Save", enabled: canSave) { save() }
            }
        }
        .frame(width: 700, height: 600)
        .sheetSurface()
        .menuHost()
        .onAppear(perform: load)
    }

    private var summaryLine: String {
        let count = selected.count
        return "\(count) wallpaper\(count == 1 ? "" : "s")  ·  \(intervalLabel(intervalMinutes).lowercased())  ·  shuffle \(shuffle ? "on" : "off")"
    }

    private var shuffleToggle: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { shuffle.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(shuffle ? Color.muroAccent : Color.white.opacity(0.6))
                Text("Shuffle")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(shuffle ? 0.95 : 0.75))
                MiniSwitch(on: shuffle)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Capsule().fill(shuffle ? Color.muroAccent.opacity(0.14) : Color.white.opacity(0.06)))
            .overlay(
                Capsule().strokeBorder(
                    shuffle ? Color.muroAccent.opacity(0.34) : Color.white.opacity(0.12),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var selectAllButton: some View {
        let allSelected = selected.count == store.localItems.count && !store.localItems.isEmpty
        return Button(allSelected ? "Select None" : "Select All") {
            selected = allSelected ? [] : Set(store.localItems.map(\.id))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.muroAccent)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(Color.muroAccent.opacity(0.13)))
        .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.28), lineWidth: 1))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new:
            // "New Playlist 2", not a second "New Playlist". The warning below
            // is there for names typed by hand; a default that walks straight
            // into it would be the app's own fault.
            name = uniqueName(base: "New Playlist", taken: store.playlists.map(\.name))
        case .edit(let playlist):
            name = playlist.name
            selected = Set(playlist.wallpaperIDs)
            intervalMinutes = playlist.intervalMinutes
            shuffle = playlist.shuffle
        }
    }

    private func intervalLabel(_ minutes: Int) -> String {
        minutes < 60
            ? "Every \(minutes) min"
            : (minutes % 60 == 0 ? "Every \(minutes / 60) hr" : "Every \(minutes / 60) hr \(minutes % 60) min")
    }

    private func save() {
        // Keep library order so the cycle order is predictable.
        let ordered = store.localItems.map(\.id).filter(selected.contains)
        switch target {
        case .new:
            store.addPlaylist(Playlist(
                name: trimmedName,
                wallpaperIDs: ordered,
                intervalMinutes: intervalMinutes,
                shuffle: shuffle
            ))
        case .edit(let original):
            var updated = original
            updated.name = trimmedName
            updated.wallpaperIDs = ordered
            updated.intervalMinutes = intervalMinutes
            updated.shuffle = shuffle
            store.updatePlaylist(updated)
        }
        dismiss()
    }
}

/// Any interval the five segments do not cover.
struct CustomIntervalPicker: View {
    @Binding var minutes: Int
    var done: () -> Void

    @State private var amount = 45
    @State private var unit = "1"     // 1 = minutes, 60 = hours

    private var resolved: Int { min(max(amount * (Int(unit) ?? 1), 1), 24 * 60) }

    var body: some View {
        CustomValueCard(
            title: "Custom interval",
            amount: $amount,
            applyLabel: "Every \(resolved < 60 ? "\(resolved) min" : "\(resolved / 60) hr")"
        ) {
            PillSegments(
                options: [PillOption("1", "min"), PillOption("60", "hr")],
                selection: $unit,
                height: 32,
                labelSize: 12,
                horizontalPadding: 16
            )
        } apply: {
            minutes = resolved
            done()
        }
        .onAppear {
            if minutes % 60 == 0 && minutes >= 60 { amount = minutes / 60; unit = "60" }
            else { amount = minutes; unit = "1" }
        }
    }
}

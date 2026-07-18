import SwiftUI
import UniformTypeIdentifiers
import MuroKit

struct LibraryView: View {
    @EnvironmentObject var store: AppStore

    enum LibTab: String, CaseIterable {
        case all = "All", liked = "Liked", playlists = "Playlists"
    }

    @State private var tab: LibTab = .all
    @State private var dropTargeted = false
    @State private var editorTarget: PlaylistEditorTarget?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 24),
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if store.searchActive { SearchField() }
                tabPill(.all, count: store.localItems.count)
                tabPill(.liked, count: store.likedItems.count)
                tabPill(.playlists, count: store.playlists.count)
                Spacer()
            }
            .padding(.horizontal, 64)
            .padding(.top, 96)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .all:
                        dropZone
                        grid(items: searched)
                    case .liked:
                        grid(items: searched.filter(\.liked))
                    case .playlists:
                        playlistsGrid
                    }
                }
                .padding(.horizontal, 64)
                .padding(.top, 20)
                .padding(.bottom, 48)
            }
            .topFade()
        }
        .sheet(item: $editorTarget) { target in
            PlaylistEditorView(target: target)
                .environmentObject(store)
        }
    }

    private func tabPill(_ value: LibTab, count: Int) -> some View {
        let selected = tab == value
        return Button {
            tab = value
        } label: {
            HStack(spacing: 7) {
                Text(value.rawValue)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.black.opacity(0.5) : Color.muroAccent.opacity(0.9))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 7.5)
            .background {
                Capsule().fill(selected ? Color.white : Color.white.opacity(0.07))
            }
            .overlay {
                if !selected {
                    Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Import drop zone

    private var dropZone: some View {
        HStack(spacing: 16) {
            CircledPlus()
            VStack(alignment: .leading, spacing: 3) {
                Text(store.importStatus ?? "Drop videos here or click to import")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("MP4 & MOV · converts to HEVC automatically · audio removed · originals untouched")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.muroSecondary)
            }
            Spacer()
            if store.importStatus != nil {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 88)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.muroAccent.opacity(dropTargeted ? 0.1 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.muroAccent.opacity(dropTargeted ? 0.7 : 0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 7])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { pickFiles() }
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
                WallpaperCard(item: item, persistentTitle: true)
            }
        }
    }

    // MARK: - Playlists

    private var playlistsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)],
            spacing: 24
        ) {
            ForEach(store.playlists) { playlist in
                PlaylistCard(playlist: playlist) {
                    editorTarget = .edit(playlist)
                }
            }
            newPlaylistCard
        }
    }

    private var newPlaylistCard: some View {
        VStack(spacing: 10) {
            CircledPlus()
            Text("New Playlist")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.white)
            Text("Pick wallpapers and cycle them on a schedule")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.muroSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 176)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.muroAccent.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.muroAccent.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 7]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { editorTarget = .new }
    }
}

/// The accent "+" in a circle, optically centered (SF symbol baseline
/// metrics leave the raw glyph sitting a hair high).
struct CircledPlus: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.muroAccent.opacity(0.14))
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.muroAccent)
                .offset(y: 0.5)
        }
        .frame(width: 44, height: 44)
    }
}

struct PlaylistCard: View {
    @EnvironmentObject var store: AppStore
    let playlist: Playlist
    var onEdit: () -> Void = {}

    @State private var showMenu = false

    private var isActive: Bool { store.activePlaylistID == playlist.id }

    private var thumbs: [WallpaperItem] {
        playlist.wallpaperIDs.compactMap { store.item(id: $0) }
    }

    private var metaLine: String {
        let interval: String
        switch playlist.intervalMinutes {
        case ..<60: interval = "Every \(playlist.intervalMinutes) min"
        case 60: interval = "Every hour"
        default: interval = "Every \(playlist.intervalMinutes / 60) hr"
        }
        return "\(playlist.wallpaperIDs.count) wallpapers · \(interval) · Shuffle \(playlist.shuffle ? "on" : "off")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(playlist.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                if isActive {
                    HStack(spacing: 5) {
                        Circle().fill(Color.muroGreen).frame(width: 5.5, height: 5.5)
                        Text("PLAYING")
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
                Spacer()
                playButton
            }
            Text(metaLine)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.muroSecondary)
                .padding(.top, 7)
            thumbStrip
                .padding(.top, 16)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 176)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isActive ? Color.muroAccent.opacity(0.55) : Color.white.opacity(0.1),
                    lineWidth: isActive ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { onEdit() }
        // Custom right-click menu in the app's glass style instead of the
        // stock macOS context menu.
        .overlay(RightClickCatcher { showMenu = true })
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            GlassMenuList(width: 190, options: menuOptions) { showMenu = false }
        }
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

    private var playButton: some View {
        Button {
            isActive ? store.stopPlaylist() : store.startPlaylist(playlist)
        } label: {
            Image(systemName: isActive ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : Color.white)
                .frame(width: 40, height: 40)
                .background {
                    Circle().fill(isActive ? Color.white : Color.white.opacity(0.1))
                }
                .overlay {
                    if !isActive {
                        Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var thumbStrip: some View {
        HStack(spacing: 10) {
            ForEach(thumbs.prefix(3)) { item in
                Color.black
                    .frame(width: 120, height: 68)
                    .overlay(ThumbImage(item: item))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if thumbs.count > 3 {
                Color.black
                    .frame(width: 120, height: 68)
                    .overlay(ThumbImage(item: thumbs[3]))
                    .overlay(Color.black.opacity(0.55))
                    .overlay(
                        Text("+\(thumbs.count - 3)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
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

/// Create/edit sheet: name (rename), pick exactly which library wallpapers
/// are in the playlist, interval and shuffle. Delete lives here too.
struct PlaylistEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: PlaylistEditorTarget

    @State private var name = ""
    @State private var selected: Set<String> = []
    @State private var intervalMinutes = 30
    @State private var shuffle = false
    @State private var loaded = false

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty && !selected.isEmpty }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
            nameField
                .padding(.horizontal, 24)
                .padding(.top, 16)
            HStack {
                Text("CHOOSE WALLPAPERS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Color.muroAccent)
                Spacer()
                Text("\(selected.count) selected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                selectAllButton
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.localItems) { item in
                        tile(item)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .topFade(16)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color.white.opacity(0.03))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
        }
        .frame(width: 640, height: 580)
        .background(Color.muroBG)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new:
            name = "New Playlist"
        case .edit(let playlist):
            name = playlist.name
            selected = Set(playlist.wallpaperIDs)
            intervalMinutes = playlist.intervalMinutes
            shuffle = playlist.shuffle
        }
    }

    private var header: some View {
        HStack {
            Text(isNew ? "New Playlist" : "Edit Playlist")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var nameField: some View {
        TextField("Playlist name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glass(cornerRadius: 10, fill: 0.06, stroke: 0.12)
    }

    private var selectAllButton: some View {
        let allSelected = selected.count == store.localItems.count && !store.localItems.isEmpty
        return Button(allSelected ? "Select None" : "Select All") {
            selected = allSelected ? [] : Set(store.localItems.map(\.id))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.muroAccent)
    }

    private func tile(_ item: WallpaperItem) -> some View {
        let isSelected = selected.contains(item.id)
        return Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(ThumbImage(item: item))
            .overlay(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center, endPoint: .bottom
                )
            )
            .overlay(alignment: .bottomLeading) {
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(isSelected ? Color.muroAccent : Color.black.opacity(0.45))
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.black)
                    } else {
                        Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    }
                }
                .frame(width: 20, height: 20)
                .padding(7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.muroAccent.opacity(0.8) : Color.white.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
            }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            GlassDropdown(width: 130, options: {
                [15, 30, 60, 180].map { minutes in
                    MenuOption(
                        title: intervalLabel(minutes),
                        checked: intervalMinutes == minutes
                    ) { intervalMinutes = minutes }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(intervalLabel(intervalMinutes))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .glassCapsule(fill: 0.07, stroke: 0.12)
            }
            HStack(spacing: 7) {
                Text("Shuffle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Toggle("", isOn: $shuffle)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Color.muroAccent)
                    .labelsHidden()
            }
            Spacer()
            if !isNew {
                Button {
                    if case .edit(let playlist) = target { store.deletePlaylist(playlist) }
                    dismiss()
                } label: {
                    Text("Delete")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFF6B6B))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color(hex: 0xFF6B6B).opacity(0.13)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0xFF6B6B).opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                save()
            } label: {
                Text(isNew ? "Create Playlist" : "Save")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.4)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func intervalLabel(_ minutes: Int) -> String {
        minutes < 60 ? "Every \(minutes) min" : "Every \(minutes / 60) hr"
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

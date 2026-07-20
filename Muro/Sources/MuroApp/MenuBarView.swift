import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var store: AppStore

    private var currentItem: WallpaperItem? {
        store.currentAppliedID.flatMap { store.item(id: $0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            transport
            speedRow
            if !store.recentItems.isEmpty { recents }
            playlistsRow
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            menuButtons
        }
        .padding(16)
        .frame(width: 306)
        // No background here: StatusBarController hosts this in a fully
        // transparent panel whose container draws the single rounded
        // dark-glass card (blur + wash + border).
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        VStack(spacing: 6) {
            if let item = currentItem {
                ZStack(alignment: .bottomLeading) {
                    Color.black
                        .frame(height: 122)
                        .overlay(ThumbImage(item: item))
                        .clipped()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .center, endPoint: .bottom
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(store.isPaused ? Color.muroSecondary : Color.muroGreen)
                                .frame(width: 5, height: 5)
                            Text(statusLine(item))
                                .font(.system(size: 8.5, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("No wallpaper applied")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 70)
                    .glass(cornerRadius: 12)
            }
            if let update = store.updateAvailable {
                Button {
                    StatusBarController.shared?.closePanel()
                    NSWorkspace.shared.open(update)
                } label: {
                    Text("Update available ↗")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.muroAccent)
                }
                .buttonStyle(.plain)
            } else {
                Text("Version \(AppStore.appVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.muroSecondary)
            }
        }
    }

    private func statusLine(_ item: WallpaperItem) -> String {
        let displays = store.appliedDisplays(for: item.id).count
        let state = store.isPaused ? "PAUSED" : "PLAYING"
        // Look up the mode on a display actually showing this wallpaper —
        // the bare all-displays entry can be stale after per-display applies.
        let mode = store.displays
            .compactMap { store.config.assignment(forDisplayUUID: $0.id) }
            .first { $0.wallpaperID == item.id }?.mode
        let fps = mode == "efficient" ? 30 : Int(item.fps)
        return "\(state) · \(displays) DISPLAY\(displays == 1 ? "" : "S") · \(fps) FPS"
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 10) {
            transportButton("arrow.clockwise", enabled: currentItem != nil) {
                store.reapply()
            }
            transportButton("backward.end.fill", enabled: store.activePlaylist != nil) {
                store.advancePlaylist(forward: false)
            }
            Button {
                store.setPaused(!store.isPaused)
            } label: {
                Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(currentItem == nil)
            transportButton("forward.end.fill", enabled: store.activePlaylist != nil) {
                store.advancePlaylist(forward: true)
            }
            transportButton("shuffle", enabled: store.activePlaylist != nil, active: store.activePlaylist?.shuffle == true) {
                if var playlist = store.activePlaylist {
                    playlist.shuffle.toggle()
                    store.updatePlaylist(playlist)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(
        _ systemName: String, enabled: Bool, active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.muroAccent : .white)
                .frame(width: 34, height: 34)
                .glassCapsule(fill: 0.08, stroke: 0.14)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: - Speed

    private var speedRow: some View {
        HStack(spacing: 2) {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5], id: \.self) { speed in
                let selected = abs(store.playbackSpeed - speed) < 0.01
                Text(speedLabel(speed))
                    .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background { if selected { Capsule().fill(Color.white) } }
                    .contentShape(Capsule())
                    .onTapGesture { store.setPlaybackSpeed(speed) }
            }
        }
        .padding(3)
        .glassCapsule(fill: 0.07, stroke: 0.12)
    }

    // MARK: - Recents

    private var recents: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RECENTS")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.muroAccent)
            HStack(spacing: 8) {
                ForEach(store.recentItems.prefix(4)) { item in
                    Color.black
                        .frame(width: 64, height: 38)
                        .overlay(ThumbImage(item: item))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .onTapGesture {
                            store.setWallpaper(item, mode: store.defaultMode(for: item))
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Playlists

    private var playlistsRow: some View {
        HStack {
            Image(systemName: "list.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
            Text("Playlists")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            GlassDropdown(width: 190, arrowEdge: .bottom, options: playlistOptions) {
                HStack(spacing: 4) {
                    Text(store.activePlaylist?.name ?? "Off")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(store.activePlaylist != nil ? Color.muroAccent : Color.muroSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.muroSecondary)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glass(cornerRadius: 12, fill: 0.06, stroke: 0.1)
    }

    private func playlistOptions() -> [MenuOption] {
        guard !store.playlists.isEmpty else {
            return [MenuOption(title: "No playlists yet. Create one in Library.")]
        }
        return store.playlists.map { playlist in
            MenuOption(title: playlist.name, checked: store.activePlaylistID == playlist.id) {
                store.activePlaylistID == playlist.id
                    ? store.stopPlaylist()
                    : store.startPlaylist(playlist)
            }
        }
    }

    // MARK: - Bottom menu

    private var menuButtons: some View {
        VStack(spacing: 2) {
            menuRow("Open Muro") {
                StatusBarController.shared?.closePanel()
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.title == "Muro" {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            menuRow("Settings") {
                StatusBarController.shared?.closePanel()
                openSettingsWindow()
            }
            menuRow("Quit Muro", trailingText: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
    }

    private func menuRow(
        _ title: String, trailing: String? = nil, trailingText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                Spacer()
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.muroSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0))
            )
    }
}


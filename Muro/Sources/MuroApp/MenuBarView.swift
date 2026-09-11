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
            automationsRow
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            menuButtons
        }
        .padding(16)
        .frame(width: 306)
        // The update row is reset by `StatusBarController.openPanel`, not from
        // here. This view is built once and reused, so an `onAppear` fires on
        // the first open of the panel and never again.
        //
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
            if let version = store.latestRelease?.version {
                Button {
                    openWhatsNew(store)
                } label: {
                    HStack(spacing: 5) {
                        NotificationDot(size: 6)
                        Text("Muro \(version) available")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.muroAccent)
                    }
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
        let base = "\(state) · \(displays) DISPLAY\(displays == 1 ? "" : "S") · \(fps) FPS"
        // While something is scheduling the wallpaper, its name matters more
        // than the frame rate does.
        if let schedule = store.runningScheduleName {
            return "\(state) · \(schedule.uppercased())"
        }
        return base
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
        return [MenuOption(title: "Off", checked: store.activePlaylistID == nil) {
            store.stopPlaylist()
        }, .divider] + store.playlists.map { playlist in
            MenuOption(title: playlist.name, checked: store.activePlaylistID == playlist.id) {
                store.activePlaylistID == playlist.id
                    ? store.stopPlaylist()
                    : store.startPlaylist(playlist)
            }
        }
    }

    // MARK: - Automations

    private var automationsRow: some View {
        HStack {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
            Text("Automations")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            GlassDropdown(width: 190, arrowEdge: .bottom, options: automationOptions) {
                HStack(spacing: 4) {
                    Text(store.activeAutomation?.name ?? "Off")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(store.activeAutomation != nil ? Color.muroAccent : Color.muroSecondary)
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

    private func automationOptions() -> [MenuOption] {
        guard !store.automations.isEmpty else {
            return [MenuOption(title: "No automations yet. Create one in Library.")]
        }
        var options = [MenuOption(title: "Off", checked: store.activeAutomationID == nil) {
            store.stopAutomation()
        }, .divider]
        options += store.automations.map { automation in
            MenuOption(
                title: automation.name,
                checked: store.activeAutomationID == automation.id
            ) {
                store.activeAutomationID == automation.id
                    ? store.stopAutomation()
                    : store.startAutomation(automation)
            }
        }
        return options
    }

    // MARK: - Bottom menu

    private var menuButtons: some View {
        VStack(spacing: 2) {
            menuRow("Open Muro", icon: "macwindow") {
                StatusBarController.shared?.closePanel()
                showMainWindow()
            }
            menuRow("Settings", icon: "gearshape") {
                StatusBarController.shared?.closePanel()
                openSettingsWindow()
            }
            updateRow
            menuRow("Quit Muro", icon: "power", trailingText: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
    }

    /// Leading icons, so these read as part of the same panel as the Playlists
    /// and Automations rows above them rather than as a plain text list
    /// bolted underneath. Same size and opacity as those two use.
    private func menuRow(
        _ title: String, icon: String, badge: String? = nil,
        trailing: String? = nil, trailingText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .fixedSize()
                Spacer(minLength: 6)
                if let badge {
                    // The accent capsule the app already uses for a count or a
                    // state, rather than a new shape invented for this. Small
                    // and tinted rather than solid: it is a flag saying there
                    // is something to find, not the action itself. Pressing
                    // the row is still what finds it.
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.muroAccent)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.muroAccent.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.30), lineWidth: 1))
                }
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

    // MARK: - Update

    /// One row that answers rather than one that just does something.
    ///
    /// The whole point of pressing "Check for Updates" is to be told, so this
    /// row says what happened in place: checking, up to date, could not reach
    /// GitHub, or a version with a Download beside it. It shares
    /// `store.updateCheck` with the same button in Settings, so a check made
    /// in one is not forgotten by the other.
    @ViewBuilder private var updateRow: some View {
        switch store.updateCheck {
        case .idle:
            // The badge is read from `latestRelease`, not from this button
            // ever having been pressed. Muro already asks GitHub every six
            // hours and that check is silent, so without the badge the panel
            // would sit there offering a check while the app privately knew a
            // new version was out. The row still offers the check, because
            // being told is the point of pressing it.
            menuRow(
                "Check for Updates",
                icon: "arrow.triangle.2.circlepath",
                badge: store.latestRelease != nil ? "New Update Available" : nil
            ) {
                Task { await store.checkForUpdates(userInitiated: true) }
            }
        case .checking:
            updateStatusRow(icon: "arrow.triangle.2.circlepath", title: "Checking…") {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 16, height: 16)
            }
        case .upToDate:
            updateStatusRow(icon: "checkmark.circle", title: "Muro is up to date") {
                Text("v\(AppStore.appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.muroSecondary)
            }
        case .failed:
            // Tappable, because the usual reason is a network that has since
            // come back and the fix is to press it again.
            menuRow("Could not check. Try again", icon: "exclamationmark.triangle") {
                Task { await store.checkForUpdates(userInitiated: true) }
            }
        case let .available(version, _):
            downloadRow(version: version)
        }
    }

    /// The one row in this panel worth a second of attention, so it gets a
    /// filled accent pill rather than accent-coloured text. The whole row is
    /// the button; the pill is the affordance, not a separate target.
    private func downloadRow(version: String) -> some View {
        Button {
            StatusBarController.shared?.closePanel()
            store.downloadUpdate()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muroAccent)
                    .frame(width: 16)
                Text("Muro \(version) is available")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Text("Download")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.muroAccent))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    /// A row that reports instead of acting. Same shape as `menuRow`, without
    /// the button, so a state that is not tappable does not look tappable.
    private func updateStatusRow<Trailing: View>(
        icon: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muroSecondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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


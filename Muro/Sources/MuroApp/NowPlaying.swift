import SwiftUI
import MuroKit

/// The three places a playlist or an automation can play. Each place plays
/// one at a time, and any playlist or automation can be put on any of them,
/// or on several at once.
///
/// Playlists and automations used to be started from their own cards and
/// always played on the desktop. They have no place of their own now: the
/// place is chosen where they are played, in the Now Playing bar in Library
/// and in the same three rows in the menu bar.
enum SchedulePlace: String, CaseIterable, Identifiable {
    case desktop, lockScreen, screenSaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .lockScreen: return "Lock screen"
        case .screenSaver: return "Screen saver"
        }
    }

    /// For the grey words beside a playlist in the lists, which have to fit
    /// beside its name: "On lock + saver".
    var shortTitle: String {
        switch self {
        case .desktop: return "desktop"
        case .lockScreen: return "lock"
        case .screenSaver: return "saver"
        }
    }
}

/// A playlist or an automation, the two things a place can play.
enum ScheduleRef: Hashable {
    case playlist(String)
    case automation(String)
}

extension AppStore {
    /// "PLAYING ON DESKTOP", for the chip on a card. Nil when it is playing
    /// nowhere.
    func playingLabel(for schedule: ScheduleRef) -> String? {
        let playing = places(playing: schedule)
        guard !playing.isEmpty else { return nil }
        if playing.count == SchedulePlace.allCases.count { return "PLAYING EVERYWHERE" }
        return "PLAYING ON " + playing.map { $0.title.uppercased() }.joined(separator: " + ")
    }

    /// What a place's row says it is playing.
    func nowPlayingName(on place: SchedulePlace) -> String? {
        nowPlaying[place].flatMap { name(of: $0) }
    }

    /// The list a place's row opens: Off, then every playlist, then every
    /// automation. The one playing here is ticked, and picking it again stops
    /// it. One playing somewhere else says where, in short words, and one
    /// playing on every place says Everywhere, like the card's chip.
    func placeMenu(for place: SchedulePlace) -> [MenuOption] {
        var options = [MenuOption(title: "Off", checked: nowPlaying[place] == nil) { [weak self] in
            self?.stopPlaying(on: place)
        }]
        guard !playlists.isEmpty || !automations.isEmpty else {
            options.append(.divider)
            options.append(MenuOption(title: "No playlists or automations yet"))
            return options
        }
        func option(_ schedule: ScheduleRef, title: String) -> MenuOption {
            let here = nowPlaying[place] == schedule
            let playing = places(playing: schedule)
            let elsewhere = playing.filter { $0 != place }
            let everywhere = schedulePlaces.count > 1 && playing.count == schedulePlaces.count
            return MenuOption(
                title: title,
                checked: here,
                detail: everywhere
                    ? "Everywhere"
                    : (elsewhere.isEmpty ? nil : "On " + elsewhere.map(\.shortTitle).joined(separator: " + "))
            ) { [weak self] in
                here ? self?.stopPlaying(on: place) : self?.play(schedule, on: place)
            }
        }
        if !playlists.isEmpty {
            options.append(.divider)
            options.append(.header("PLAYLISTS"))
            options += playlists.map { option(.playlist($0.id), title: $0.name) }
        }
        if !automations.isEmpty {
            options.append(.divider)
            options.append(.header("AUTOMATIONS"))
            options += automations.map { option(.automation($0.id), title: $0.name) }
        }
        return options
    }
}

/// The Now Playing bar at the top of Playlists & Automations: one tile per
/// place, each opening the same list as its row in the menu bar.
struct NowPlayingBar: View {
    @EnvironmentObject var store: AppStore

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("NOW PLAYING")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.schedulePlaces) { place in
                    NowPlayingTile(place: place)
                }
            }
        }
    }
}

private struct NowPlayingTile: View {
    @EnvironmentObject var store: AppStore
    let place: SchedulePlace

    @State private var hovering = false

    var body: some View {
        GlassDropdown(width: 250, options: { store.placeMenu(for: place) }) {
            HStack(spacing: 12) {
                // The top bar's white glass bubble, glyph glow included, so
                // the three places read as the app's own controls.
                PlaceGlyph(place: place, size: 17)
                    .shadow(color: .white.opacity(0.45), radius: 3)
                    .bubbleSurface(size: 34, tint: .white)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.title.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.muroSecondary)
                    Text(store.nowPlayingName(on: place) ?? "Off")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            store.nowPlaying[place] == nil ? Color.muroSecondary : Color.muroInk
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.muroSecondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.muroInk.opacity(hovering ? 0.085 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.muroInk.opacity(hovering ? 0.18 : 0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.16), value: hovering)
        }
    }
}

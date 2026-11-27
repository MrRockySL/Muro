import SwiftUI
import MuroKit

/// One dot of a live wallpaper with colours: its original, or one of its
/// other colours. `id` is the live wallpaper that colour is.
struct ColorMember: Identifiable, Equatable {
    let id: String
    let key: String
    /// In the chosen language.
    let name: String
    let color: Color
    let isOriginal: Bool
}

/// Colour options in the app (owner, 2026-11-27: "original plus 3 for
/// each"): a few live wallpapers in three more colours, from their own list on
/// the server (`HostedColors`), so only a Muro that knows them sees them.
///
/// Explore lists only the originals, each with a COLORS label, and a Colors
/// section after Static. The page shows the colours as dots above its bar,
/// and in the Set Wallpaper panel. Each colour is a live wallpaper of its own,
/// downloaded and set like any other, so every place and every display keeps
/// its own colour, and removing one removes only that colour.
extension AppStore {

    // MARK: - The list

    /// Where their list is read: beside the catalog, or the `colorsListURL`
    /// default when it is set for testing, the way `catalogURL` can be.
    var hostedColorsListURL: URL? {
        let override = UserDefaults.standard.string(forKey: "colorsListURL") ?? ""
        return URL(string: override)
            ?? URL(string: catalogURLString).map(HostedColors.listURL(catalogURL:))
    }

    /// Reads the list again, at the same moments as the catalog. Offline, or
    /// with a list that cannot be read, the last one read stays.
    func refreshHostedColors() async {
        guard let listURL = hostedColorsListURL,
              let list = try? await HostedColors.fetchList(from: listURL)
        else { return }
        guard list != hostedColors else { return }
        hostedColors = list
        try? HostedColors.saveLocalList(list, root: root)
        objectWillChange.send()
    }

    // MARK: - Families

    /// The family a wallpaper belongs to, original or colour, while its
    /// original is in the catalog.
    func colorFamily(of id: String) -> HostedColors.Family? {
        guard let family = colorFamilies[HostedColors.familyID(of: id)] else { return nil }
        if let key = HostedColors.parse(id)?.key, !family.colors.contains(where: { $0.key == key }) {
            return nil
        }
        return family
    }

    /// Whether any live wallpaper has colours, which is when Explore shows
    /// its Colors section.
    var hasColorOptions: Bool { !colorFamilies.isEmpty }

    /// A family's dots, the original first and then its colours in the
    /// list's order. Empty for a wallpaper without colours.
    func colorMembers(of id: String) -> [ColorMember] {
        guard let family = colorFamily(of: id) else { return [] }
        return [member(family.original, id: family.id, isOriginal: true)]
            + family.colors.map {
                member($0.swatch, id: HostedColors.id(family: family.id, key: $0.key), isOriginal: false)
            }
    }

    /// The dot this wallpaper is, when it has colours.
    func colorMember(for id: String) -> ColorMember? {
        colorMembers(of: id).first { $0.id == id }
    }

    private func member(_ swatch: HostedColors.Swatch, id: String, isOriginal: Bool) -> ColorMember {
        ColorMember(
            id: id, key: swatch.key,
            name: L(swatch.name, ctx: "color"),
            color: Color(hexString: swatch.hex) ?? .white,
            isOriginal: isOriginal
        )
    }

    /// The Colors section's order for these items: the list's own order,
    /// pinned first, then newest first (`HostedColors.sorted`).
    func colorOrder(_ items: [WallpaperItem]) -> [WallpaperItem] {
        let rank = Dictionary(
            HostedColors.sorted(Array(colorFamilies.values)).enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: - On the page

    /// A dot on the page or in the panel: the page turns that colour at
    /// once, and its bar and panel are for that colour.
    func showColor(_ id: String) {
        guard previewItem?.id != id, let colour = item(id: id) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { previewItem = colour }
    }

    /// Fetches every other colour's 720p preview while the page is open, so a
    /// dot changes the page at once. They are small, and kept in the same
    /// preview cache as every other.
    func prefetchColorPreviews(for id: String) {
        for member in colorMembers(of: id) where member.id != id {
            guard let colour = item(id: member.id), !colour.isDownloaded,
                  let remote = colour.remote?.preview720,
                  PreviewCache.cachedURL(id: member.id) == nil
            else { continue }
            let memberID = member.id
            Task.detached(priority: .utility) {
                _ = try? await PreviewCache.fetch(id: memberID, from: remote)
            }
        }
    }

    /// Set Wallpaper on a colour not downloaded yet, from the panel's dots:
    /// downloaded first, with the same progress as Download, then set exactly
    /// as if it had been.
    func applyColorAfterDownload(
        _ item: WallpaperItem, mode: String, target: ApplyTarget,
        surface: ApplySurface?, fromSchedule: Bool
    ) {
        guard let remote = item.remote, downloads[item.id] == nil else { return }
        let id = item.id
        let root = self.root
        downloads[id] = 0
        Task {
            do {
                try await downloadRemoteWallpaper(remote, root: root) { progress in
                    Task { @MainActor in
                        guard AppStore.shared.downloads[id] != nil else { return }
                        AppStore.shared.downloads[id] = progress
                    }
                }
            } catch {
                downloads[id] = nil
                applyError = error.localizedDescription
                return
            }
            downloads[id] = nil
            reloadFromDisk()
            recomputeSize()
            guard let downloaded = self.item(id: id), downloaded.local != nil else { return }
            setWallpaper(downloaded, mode: mode, target: target, surface: surface, fromSchedule: fromSchedule)
        }
    }

    /// The other colour of this wallpaper on one place and display, for the
    /// panel's "Blue now". Nil when this colour is there, or none of them is.
    func appliedOtherColor(of item: WallpaperItem, surface: ApplySurface, target: ApplyTarget) -> ColorMember? {
        let place: ApplySurface = surface == .all ? .desktop : surface
        for member in colorMembers(of: item.id) where member.id != item.id {
            guard let other = self.item(id: member.id) else { continue }
            if isApplied(other, surface: place, target: target) { return member }
        }
        return nil
    }
}

extension Color {
    /// "#RRGGBB", as the colours list writes it.
    init?(hexString: String) {
        guard HostedColors.isHex(hexString), let value = UInt32(hexString.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(hex: value)
    }
}

// MARK: - Views

/// A colour's dot (design, 2026-11-27): the colour, a soft light from the top
/// and a fine light rim, so a dark colour still reads on the dark glass.
struct ColorSwatchDot: View {
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().fill(LinearGradient(
                colors: [.white.opacity(0.22), .white.opacity(0)],
                startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)
            )))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
            .frame(width: size, height: size)
    }
}

/// Marks a live wallpaper with colours on its card, wherever cards are shown
/// (owner, 2026-11-27): its own colours as small dots, the original first,
/// then COLORS. The same small dark tag as `StaticBadge`.
struct ColorsBadge: View {
    let colors: [Color]

    var body: some View {
        HStack(spacing: 5.5) {
            HStack(spacing: -2.4) {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Circle()
                        .fill(color)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.75))
                        .frame(width: 8.5, height: 8.5)
                        .zIndex(Double(colors.count - index))
                }
            }
            Text(L("COLORS"))
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.9)
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.leading, 6)
        .padding(.trailing, 9.5)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

/// Which colour a wallpaper is, under its name, with its dot: "Sword in Blue
/// Flowers" with "Red" under it in the Library, on Home and in the menu bar
/// (design, 2026-11-27).
struct ColorNameLine: View {
    let member: ColorMember
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: size * 0.45) {
            Circle()
                .fill(member.color)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75))
                .frame(width: size * 0.64, height: size * 0.64)
            Text(member.name)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
        }
    }
}

/// The colour dots on a live wallpaper's page, above its bar (design,
/// 2026-11-27): the original first, the one showing ringed, and its name
/// beside them. Pointing at a dot names that colour; clicking it turns the
/// whole page that colour.
struct ColorDotsBar: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem
    @State private var hovered: String?

    var body: some View {
        let members = store.colorMembers(of: item.id)
        let named = members.first { $0.id == (hovered ?? item.id) } ?? members.first
        HStack(spacing: 8) {
            ForEach(members) { member in
                Button {
                    store.showColor(member.id)
                } label: {
                    ZStack {
                        if member.id == item.id {
                            Circle().strokeBorder(Color.white, lineWidth: 2)
                        }
                        ColorSwatchDot(color: member.color, size: 22)
                    }
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = member.id } else if hovered == member.id { hovered = nil }
                }
                .help(member.name)
                .accessibilityLabel(member.name)
                .accessibilityValue(member.id == item.id ? L("Selected") : L("Not selected"))
            }
            // Every name laid out underneath, so the bar is as wide as its
            // longest and never changes size under the pointer.
            ZStack(alignment: .leading) {
                ForEach(members) { member in nameLabel(member).hidden() }
                if let named { nameLabel(named) }
            }
            .padding(.leading, 4)
        }
        .padding(.leading, 8)
        .padding(.trailing, 18)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.28)))
        .appleGlass(Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func nameLabel(_ member: ColorMember) -> some View {
        HStack(spacing: 6) {
            Text(member.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if member.isOriginal {
                Text(L("Original"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The same dots at the top of the Set Wallpaper panel (design, 2026-11-27),
/// so one colour can go on one place and another on the next without
/// closing it.
struct ColorPanelRow: View {
    @EnvironmentObject var store: AppStore
    let item: WallpaperItem

    var body: some View {
        let members = store.colorMembers(of: item.id)
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text(L("Color"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                HStack(spacing: 4) {
                    ForEach(members) { member in
                        Button {
                            store.showColor(member.id)
                        } label: {
                            ZStack {
                                if member.id == item.id {
                                    Circle().strokeBorder(Color.muroInk, lineWidth: 2)
                                }
                                ColorSwatchDot(color: member.color, size: 18)
                            }
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(member.name)
                        .accessibilityLabel(member.name)
                        .accessibilityValue(member.id == item.id ? L("Selected") : L("Not selected"))
                    }
                }
                Text(members.first { $0.id == item.id }?.name ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.muroInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(Color.muroInk.opacity(0.08))
                .frame(height: 1)
        }
    }
}

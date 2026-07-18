import SwiftUI

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

    private var filtered: [WallpaperItem] {
        store.items.filter { item in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow
                .padding(.horizontal, 64)
                .padding(.top, 96)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: gridColumns, spacing: 24) {
                    ForEach(filtered) { item in
                        WallpaperCard(item: item)
                    }
                }
                .padding(.horizontal, 64)
                .padding(.top, 22)
                .padding(.bottom, 48)
            }
            .topFade()
        }
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            if store.searchActive { SearchField() }
            ForEach(["All"] + store.categories, id: \.self) { name in
                FilterChip(label: name, selected: category == name) { category = name }
            }
            Spacer()
            GlassDropdown(width: 150, options: {
                pickOptions(all: resolutionOptions, selection: resolution) { resolution = $0 }
            }) {
                dropLabel("Resolution · \(resolution)")
            }
            GlassDropdown(width: 130, options: {
                pickOptions(all: fpsOptions, selection: fps) { fps = $0 }
            }) {
                dropLabel(fps == "All" ? "FPS · All" : "FPS · \(fps)")
            }
        }
    }

    private func pickOptions(
        all: [String], selection: String, choose: @escaping (String) -> Void
    ) -> [MenuOption] {
        (["All"] + all).map { value in
            MenuOption(title: value, checked: selection == value) { choose(value) }
        }
    }

    private func dropLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7.5)
        .glassCapsule(fill: 0.07, stroke: 0.12)
    }
}

struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, 15)
                .padding(.vertical, 7.5)
                .background {
                    if selected {
                        Capsule().fill(Color.white)
                    } else {
                        Capsule().fill(Color.white.opacity(0.07))
                    }
                }
                .overlay {
                    if !selected {
                        Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

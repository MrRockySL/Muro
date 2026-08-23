import SwiftUI
import MuroKit

/// One delete, waiting for an answer. Every place that can delete a wallpaper
/// raises one of these rather than deleting on the spot, so the wording, the
/// keyboard handling and the look are the same wherever it came from.
struct DeleteRequest: Identifiable, Equatable {
    let id = UUID()
    var items: [WallpaperItem]

    static func == (lhs: DeleteRequest, rhs: DeleteRequest) -> Bool { lhs.id == rhs.id }
}

/// Muro's own confirmation, in the app's dark glass rather than a system
/// alert. macOS alerts are light, square and centred on the screen, which is
/// the one place in the app the user would meet a control that looks nothing
/// like the rest of it.
struct ConfirmDeleteView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: DeleteRequest

    private static let danger = Color(hex: 0xFF6B6B)

    private var items: [WallpaperItem] { request.items }
    private var personal: [WallpaperItem] { items.filter { $0.remote == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(Self.danger.opacity(0.14))
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Self.danger)
                }
                .frame(width: 40, height: 40)
                Text(title)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }

            thumbStrip
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(line.isWarning ? Self.danger.opacity(0.95) : Color.muroSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 16)

            HStack(spacing: 10) {
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .glassCapsule(fill: 0.09, stroke: 0.15)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    store.deleteWallpapers(items)
                    dismiss()
                } label: {
                    Text(items.count > 1 ? "Delete \(items.count)" : "Delete")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Self.danger.opacity(0.9)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: 440)
        .background(Color.muroBG)
        .preferredColorScheme(.dark)
    }

    // MARK: - Thumbnails

    /// Seeing the thing you are about to destroy is the whole reason this is
    /// a sheet and not a line of text.
    @ViewBuilder private var thumbStrip: some View {
        HStack(spacing: 8) {
            ForEach(items.prefix(4)) { item in
                Color.black
                    .frame(width: items.count == 1 ? 392 : 96, height: items.count == 1 ? 108 : 54)
                    .overlay(ThumbImage(item: item))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            if items.count > 4 {
                Text("+\(items.count - 4)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.muroSecondary)
                    .frame(width: 44, height: 54)
            }
        }
    }

    // MARK: - Words

    private var title: String {
        items.count == 1 ? "Delete this wallpaper?" : "Delete \(items.count) wallpapers?"
    }

    private struct Line {
        var text: String
        var isWarning: Bool
    }

    private var lines: [Line] {
        var out: [Line] = []
        if let only = items.first, items.count == 1 {
            if only.remote == nil {
                out.append(Line(
                    text: "\(only.title) is your own video. It is not in the online catalog, so this cannot be undone.",
                    isWarning: true
                ))
            } else {
                out.append(Line(
                    text: "\(only.title) will be removed from this Mac. You can download it again from Explore any time.",
                    isWarning: false
                ))
            }
        } else {
            var text = "\(items.count) wallpapers will be removed."
            if !personal.isEmpty {
                text += personal.count == 1
                    ? " 1 of them is your own video and cannot be re-downloaded."
                    : " \(personal.count) of them are your own videos and cannot be re-downloaded."
            }
            out.append(Line(text: text, isWarning: !personal.isEmpty))
        }
        if let playing = playingLine { out.append(Line(text: playing, isWarning: false)) }
        if lockScreenAffected {
            out.append(Line(
                text: "Your lock screen goes back to the wallpaper you had before Muro.",
                isWarning: false
            ))
        }
        return out
    }

    /// "It is playing on MacBook right now. Your desktop will be cleared."
    private var playingLine: String? {
        let applied = items.filter { !store.appliedDisplays(for: $0.id).isEmpty }
        guard let first = applied.first else { return nil }
        let subject = applied.count == 1 && items.count == 1 ? "It is" : "\(applied.count) of them are"
        let displays = store.appliedDisplays(for: first.id)
        let count = store.displays.count
        let where_: String
        if displays.count > 1 || (applied.count > 1 && count > 1) {
            where_ = "on your displays"
        } else if let display = displays.first {
            where_ = "on \(friendly(display))"
        } else {
            where_ = "on your desktop"
        }
        return "\(subject) playing \(where_) right now. Your desktop will be cleared."
    }

    private var lockScreenAffected: Bool {
        guard let lockID = store.lockScreenWallpaperID else { return false }
        return items.contains { $0.id == lockID }
    }

    private func friendly(_ display: DisplayInfo) -> String {
        display.name.localizedCaseInsensitiveContains("built-in") ? "MacBook" : display.name
    }
}

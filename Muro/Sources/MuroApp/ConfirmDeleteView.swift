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
            header
            thumbStrip
                .padding(.top, 20)
            if !notices.isEmpty {
                HStack(spacing: 8) {
                    ForEach(notices, id: \.self) { noticeChip($0) }
                }
                .padding(.top, 16)
            }
            buttons
                .padding(.top, 24)
        }
        .padding(26)
        .frame(width: 440)
        // Every other sheet in Muro is built on this, and this one was the
        // only place painting itself flat `muroBG`. That single line is most
        // of why it looked like it came from a different app.
        .sheetSurface()
        .preferredColorScheme(.dark)
    }

    /// Icon, question, and one line of consequence. The line used to be three
    /// stacked sentences below the thumbnails, which read as a list to skim
    /// past rather than a warning to weigh, and pushed the buttons so far down
    /// that the thing being deleted had scrolled out of mind by the time you
    /// reached them.
    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle().fill(Self.danger.opacity(0.14))
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Self.danger)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(permanent ? Self.danger.opacity(0.95) : Color.muroSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
            Spacer(minLength: 0)
        }
    }

    private var buttons: some View {
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
    }

    /// Amber, not red. Red is the delete button, and a warning that shouts as
    /// loudly as the action makes neither of them mean anything. These say
    /// "this one is in use", which is a reason to look again, not a danger.
    ///
    /// Shaped like `AppliedChip`, which is the app's existing way of marking a
    /// wallpaper's state, so it is a vocabulary the user has already met on
    /// the Home hero rather than a new one invented for this sheet.
    private func noticeChip(_ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.muroWarn).frame(width: 5.5, height: 5.5)
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.muroWarn.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.muroWarn.opacity(0.26), lineWidth: 1))
    }

    // MARK: - Thumbnails

    /// Seeing the thing you are about to destroy is the whole reason this is
    /// a sheet and not a line of text.
    /// Sized to the 388pt of content this sheet actually has, which the old
    /// numbers were not: four 96pt thumbnails with an overflow count beside
    /// them came to 440pt inside a 392pt space, so a five wallpaper delete ran
    /// off both edges. Three plus the counter fits with room to spare.
    ///
    /// A single wallpaper gets a real 16:9 frame rather than the old 3.6:1
    /// letterbox, which cut the top and bottom off the one picture the sheet
    /// exists to show you.
    @ViewBuilder private var thumbStrip: some View {
        let overflow = items.count > 4
        let visible = Array(items.prefix(overflow ? 3 : 4))
        let single = items.count == 1
        let radius: CGFloat = single ? 14 : 9
        HStack(spacing: 8) {
            ForEach(visible) { item in
                Color.black
                    .frame(width: single ? 388 : 91, height: single ? 218 : 51)
                    .overlay(ThumbImage(item: item))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            if overflow {
                Text("+\(items.count - 3)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.muroSecondary)
                    .frame(width: 44, height: 51)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.glassSheen(0.08, 0.03))
                    )
            }
        }
    }

    // MARK: - Words

    private var title: String {
        items.count == 1 ? "Delete this wallpaper?" : "Delete \(items.count) wallpapers?"
    }

    /// At least one of these cannot be got back.
    private var permanent: Bool { !personal.isEmpty }

    /// One line, and only ever about the single thing a person actually needs
    /// to decide with: can I get this back?
    ///
    /// The wallpaper titles came out of it. They were being read aloud in a
    /// sentence directly under a picture of the same wallpaper, which is the
    /// thumbnail's job and it does it better.
    private var subtitle: String {
        if personal.isEmpty {
            return items.count == 1
                ? "You can download it again any time."
                : "You can download them again any time."
        }
        if personal.count == items.count {
            return items.count == 1
                ? "This is your own video. Deleting it is permanent."
                : "These are your own videos. Deleting them is permanent."
        }
        return personal.count == 1
            ? "1 is your own video, and that one is permanent."
            : "\(personal.count) are your own videos, and those are permanent."
    }

    /// What is currently in use, as chips rather than sentences. Two lines of
    /// prose became two short labels, which is the whole point: state is
    /// something you glance at, not something you read.
    private var notices: [String] {
        var out: [String] = []
        if let playing = playingNotice { out.append(playing) }
        if lockScreenAffected { out.append("LOCK SCREEN") }
        return out
    }

    /// Naming the display only when there is exactly one wallpaper on exactly
    /// one screen. It also sidesteps a real bug in the sentence this replaced:
    /// deleting three wallpapers with one of them playing produced "1 of them
    /// are playing", because the count and the verb were chosen separately.
    /// A label with no verb in it cannot disagree with itself.
    private var playingNotice: String? {
        let applied = items.filter { !store.appliedDisplays(for: $0.id).isEmpty }
        guard let first = applied.first else { return nil }
        let displays = store.appliedDisplays(for: first.id)
        if applied.count == 1, displays.count == 1, let display = displays.first {
            return "PLAYING ON \(friendly(display).uppercased())"
        }
        return "PLAYING NOW"
    }

    private var lockScreenAffected: Bool {
        guard let lockID = store.lockScreenWallpaperID else { return false }
        return items.contains { $0.id == lockID }
    }

    private func friendly(_ display: DisplayInfo) -> String {
        display.displayName
    }
}

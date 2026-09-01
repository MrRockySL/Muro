import SwiftUI
import AppKit
import MuroKit

// MARK: - The notes themselves

/// One change: what it is, and one line saying what that means.
struct WhatsNewEntry: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
}

/// Entries are grouped so a release reads as two short lists rather than one
/// long one. The tint is the group's own colour, worn by its bubble, so New
/// and Fixed are told apart at a glance instead of by reading two identical
/// grey captions.
struct WhatsNewSection: Identifiable {
    let id = UUID()
    var name: String
    var tint: Color
    var entries: [WhatsNewEntry]
}

struct WhatsNewRelease: Identifiable {
    var id: String { version }
    var version: String
    /// Free text, so a release can say "September 2026" or nothing at all.
    var date: String?
    var headline: String
    var sections: [WhatsNewSection]

    var isEmpty: Bool { sections.allSatisfy { $0.entries.isEmpty } }
}

/// The release notes shown in the sheet.
///
/// Data, never layout: the sheet draws whatever is here, so writing the next
/// release is editing this one list.
enum WhatsNew {
    static let current = WhatsNewRelease(
        version: "4.0",
        date: "September 2026",
        headline: "The lock screen works on every Mac now, and Explore loads on networks that used to show nothing.",
        sections: [
            WhatsNewSection(name: "New", tint: .muroAccent, entries: [
                WhatsNewEntry(title: "Intel Macs",
                              detail: "Runs natively on Intel as well as Apple Silicon."),
                WhatsNewEntry(title: "Update alerts",
                              detail: "The menu bar tells you when a new Muro is out."),
                WhatsNewEntry(title: "Menu bar colour",
                              detail: "Follows your wallpaper on macOS 15 and earlier."),
            ]),
            WhatsNewSection(name: "Fixed", tint: .muroGreen, entries: [
                WhatsNewEntry(title: "The lock screen on macOS 26",
                              detail: "It kept showing Apple's picture instead of your wallpaper."),
                WhatsNewEntry(title: "Explore was empty on some networks",
                              detail: "Wallpapers now come from Muro's own domain."),
                WhatsNewEntry(title: "Applying now waits for macOS",
                              detail: "Muro used to say it worked even when macOS had ignored it."),
                WhatsNewEntry(title: "Other small bug fixes",
                              detail: "The Dock, the menus, and Muro's Pick."),
            ]),
        ]
    )

    // Past releases are deliberately not listed here. Keeping them inline meant
    // the sheet grew by one more release every time, and 4.0 opened onto a
    // scroll through 3.0, 2.0 and 1.1 before you reached anything current. The
    // footer's "Earlier releases" goes to the releases page, which is the one
    // place that list is complete and does not need shipping in the app.

    static let releasesURL = URL(string: "https://github.com/MrRockySL/Muro/releases")!
}

// MARK: - The sheet

/// What's New: the top bar's sparkle button opens this.
///
/// It is built like the two editor sheets (the same glass, header, scroller
/// and footer) so it reads as part of the app rather than an About box, and it
/// is written against `WhatsNew` so the notes are data, never layout.
struct WhatsNewView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let release = WhatsNew.current

    var body: some View {
        VStack(spacing: 0) {
            header
            GlassScrollView(fadeTop: 14, fadeBottom: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    // A newer Muro comes first, above this build's own notes.
                    // Someone who opened this because of the badge is here for
                    // that, and should not have to scroll past old news.
                    if let update = store.latestRelease {
                        updateBlock(update)
                        SectionLabel("IN THE VERSION YOU HAVE")
                    }
                    releaseCard
                    if release.isEmpty {
                        placeholder
                    } else {
                        ForEach(release.sections) { section in
                            sectionBlock(section)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            footer
        }
        .frame(width: 580, height: 620)
        .sheetSurface()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            MuroMark(cornerRadius: 9)
                .frame(width: 32, height: 32)
            Text("What's New")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .glassCircleChrome()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(.glassSheen(0.05, 0.02))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                }
        )
    }

    // MARK: The release

    /// The version, the date and the one sentence, inside a card of their own.
    /// It gives the top of the sheet something to be, instead of three loose
    /// pieces of text sitting on the background.
    private var releaseCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Muro \(release.version)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let date = release.date {
                    Text(date)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.muroSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.glassSheen(0.09, 0.03)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
            }
            Text(release.headline)
                .font(.system(size: 12))
                .foregroundStyle(Color.muroSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.glassSheen(0.06, 0.02))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.muroAccent.opacity(0.30), Color.muroAccent.opacity(0)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.05), startRadius: 0, endRadius: 260
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    /// The group's name as a bubble in its own colour. A pair of identical grey
    /// captions made New and Fixed look like the same thing twice.
    private func groupBubble(_ section: WhatsNewSection) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(section.tint)
                .frame(width: 5, height: 5)
            Text(section.name.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(section.tint)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(section.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(section.tint.opacity(0.30), lineWidth: 1))
    }

    // MARK: The update

    /// The new release: what it is, what changed in it, and the button that
    /// gets it. Accent-framed so it cannot be mistaken for the notes of the
    /// build already running.
    private func updateBlock(_ update: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("UPDATE AVAILABLE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(1.3)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.muroAccent))
                if let date = update.publishedAt.map(Self.dateText) {
                    Text(date)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.muroSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Muro \(update.version)")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                if let title = update.title {
                    Text(title)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.muroSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if update.isEmpty {
                Text("The notes for this release are on the release page.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.muroSecondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(update.notes) { note in
                        VStack(alignment: .leading, spacing: 8) {
                            if let name = note.name, !name.isEmpty {
                                SectionLabel(name.uppercased())
                            }
                            ForEach(Array(note.lines.enumerated()), id: \.offset) { _, line in
                                noteLine(line)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                PrimaryPill(title: "Download Muro \(update.version)") {
                    store.downloadUpdate()
                }
                GhostPill(title: "Release Notes") {
                    NSWorkspace.shared.open(update.page)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.glassSheen(0.1, 0.035))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.muroAccent.opacity(0.28), Color.muroAccent.opacity(0)
                        ]),
                        center: UnitPoint(x: 0.1, y: -0.2), startRadius: 0, endRadius: 360
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.muroAccent.opacity(0.55), lineWidth: 1)
        )
    }

    /// One line of the remote notes. A dot rather than a symbol bubble: the
    /// text comes from GitHub, so there is no icon to pick for it.
    private func noteLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.muroAccent)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    // MARK: Notes

    private func sectionBlock(_ section: WhatsNewSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            groupBubble(section)
                .padding(.bottom, 1)
            ForEach(section.entries) { entry in
                entryRow(entry)
            }
        }
    }

    /// The name in a rounded face, the explanation in the normal one. The
    /// contrast is what makes a name read as a name; when both were the same
    /// face at the same weight the list read as undifferentiated prose.
    private func entryRow(_ entry: WhatsNewEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.muroSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }

    /// What the sheet shows until the notes are written. It is a designed
    /// state rather than a blank panel, because an update button that opens
    /// onto nothing reads as a broken one.
    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.muroAccent)
                .frame(width: 54, height: 54)
                .background(Circle().fill(.glassSheen(0.14, 0.05)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            Text("The notes for this update are on the way")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.white)
            Text("Everything that changed will be listed right here: what is new, what got better, and what was fixed.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.glassSheen(0.05, 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: Footer

    private var footer: some View {
        SheetFooter {
            Text(
                store.latestRelease == nil
                    ? "You are running Muro \(AppStore.appVersion), the latest version"
                    : "You are running Muro \(AppStore.appVersion)"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.muroSecondary)
        } actions: {
            GhostPill(title: "Earlier releases") {
                NSWorkspace.shared.open(WhatsNew.releasesURL)
            }
            PrimaryPill(title: "Done") { dismiss() }
        }
    }
}

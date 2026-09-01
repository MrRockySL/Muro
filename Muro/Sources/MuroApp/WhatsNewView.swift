import SwiftUI
import AppKit
import MuroKit

// MARK: - The notes themselves

/// One line in a release: what changed, and why anyone would care.
struct WhatsNewEntry: Identifiable {
    let id = UUID()
    /// SF Symbol shown in the row's bubble.
    var icon: String
    var title: String
    var detail: String
}

/// Entries are grouped so a release reads as a few short lists rather than one
/// long one: "Library", "Explore", "Fixed".
struct WhatsNewSection: Identifiable {
    let id = UUID()
    var name: String
    var entries: [WhatsNewEntry]
}

struct WhatsNewRelease: Identifiable {
    var id: String { version }
    var version: String
    /// Free text, so a release can say "August 2026" or nothing at all.
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
        headline: "The lock screen now works on Macs where it never did, wallpapers load on networks that used to show nothing, and Muro runs on Intel.",
        sections: [
            WhatsNewSection(name: "New", entries: [
                WhatsNewEntry(
                    icon: "desktopcomputer",
                    title: "Intel Macs",
                    detail: "Muro is built for Intel as well as Apple Silicon, so it runs natively on either one."
                ),
                WhatsNewEntry(
                    icon: "bell.badge",
                    title: "New versions from the menu bar",
                    detail: "When a new Muro is out, the menu bar says so and takes you straight to it."
                ),
                WhatsNewEntry(
                    icon: "paintpalette",
                    title: "The menu bar matches your wallpaper",
                    detail: "On macOS 15 and earlier the menu bar took its colour from whatever picture you had before installing Muro, not from what Muro is playing. It follows the wallpaper now. macOS 26 made the menu bar clear, so there is nothing to match there."
                ),
            ]),
            WhatsNewSection(name: "Fixed", entries: [
                WhatsNewEntry(
                    icon: "lock.display",
                    title: "The lock screen on macOS 26",
                    detail: "If your desktop and lock screen share one wallpaper, Muro was writing its choice somewhere macOS never reads, so the lock screen kept showing Apple's. It writes to the right place now."
                ),
                WhatsNewEntry(
                    icon: "globe",
                    title: "Explore was empty on some networks",
                    detail: "Wallpapers came from an address shared with every other Cloudflare bucket, and some networks block the whole thing. They now come from Muro's own domain, which nobody else is on."
                ),
                WhatsNewEntry(
                    icon: "checkmark.seal",
                    title: "Applying to the lock screen tells the truth",
                    detail: "Muro used to check its own work, so it passed every time even when macOS had ignored it. It waits for macOS to confirm now, and clears out old entries left behind by wallpapers you deleted."
                ),
                WhatsNewEntry(
                    icon: "macwindow",
                    title: "Smaller things",
                    detail: "Muro stays out of the Dock and still opens when you click it there, Muro's Pick comes from the catalog, the menu says which screen a wallpaper is on and no longer jumps as you read it, and Muro no longer puts a CPU percentage on anything."
                ),
            ]),
        ]
    )

    /// Older releases, newest first.
    static let earlier: [WhatsNewRelease] = [
        WhatsNewRelease(
            version: "3.0",
            date: "August 2026",
            headline: "The biggest Muro yet. Wallpapers you can delete, schedules that change them for you, and a new look for every screen in the app.",
            sections: [WhatsNewSection(name: "", entries: [
                WhatsNewEntry(
                    icon: "trash",
                    title: "Delete wallpapers",
                    detail: "Every card has a delete button, and you can clear several at once. Nothing goes without asking first."
                ),
                WhatsNewEntry(
                    icon: "clock.arrow.2.circlepath",
                    title: "Automations and Pause after",
                    detail: "Change wallpaper on a timer or by time of day, and let one play for a while before holding on a frame."
                ),
                WhatsNewEntry(
                    icon: "square.grid.2x2",
                    title: "A new look",
                    detail: "The Library, Explore and every menu in the app were redrawn by Muro instead of by the system."
                ),
            ])]
        ),
        WhatsNewRelease(
            version: "2.0",
            date: "July 2026",
            headline: "Lock screen live wallpapers.",
            sections: [WhatsNewSection(name: "", entries: [
                WhatsNewEntry(
                    icon: "lock.display",
                    title: "Lock screen live wallpapers",
                    detail: "Set any wallpaper on the lock screen as well as the desktop."
                ),
            ])]
        ),
        WhatsNewRelease(
            version: "1.1",
            date: "July 2026",
            headline: "New wallpapers arrive on their own.",
            sections: [WhatsNewSection(name: "", entries: [
                WhatsNewEntry(
                    icon: "sparkle",
                    title: "New wallpapers arrive on their own",
                    detail: "Wallpapers published since you installed Muro show up in Explore, marked NEW, with no update needed."
                ),
            ])]
        ),
    ]

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
                VStack(alignment: .leading, spacing: 22) {
                    // A newer Muro comes first, above this build's own notes.
                    // Someone who opened this because of the badge is here for
                    // that, and should not have to scroll past old news.
                    if let update = store.latestRelease {
                        updateBlock(update)
                        SectionLabel("IN THE VERSION YOU HAVE")
                    }
                    hero
                    if release.isEmpty {
                        placeholder
                    } else {
                        ForEach(release.sections) { section in
                            sectionBlock(section)
                        }
                    }
                    ForEach(WhatsNew.earlier) { past in
                        earlierBlock(past)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 18)
                .padding(.bottom, 20)
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
        .padding(.horizontal, 26)
        .padding(.top, 24)
    }

    // MARK: Hero

    /// The version, big, with the accent light behind it. A release note that
    /// opens with a heading the size of body text does not feel like an
    /// occasion, and this is the one screen in the app whose whole job is to
    /// make an update feel like one.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                versionPill
                if let date = release.date {
                    Text(date)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.muroSecondary)
                }
            }
            Text("Muro \(release.version)")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Text(release.headline)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.muroSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.glassSheen(0.085, 0.03))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color.muroAccent.opacity(0.22), Color.muroAccent.opacity(0)
                        ]),
                        center: UnitPoint(x: 0.88, y: -0.1), startRadius: 0, endRadius: 300
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var versionPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 9.5, weight: .semibold))
            Text("LATEST UPDATE")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.3)
        }
        .foregroundStyle(Color.muroAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.muroAccent.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.3), lineWidth: 1))
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
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(section.name.uppercased())
            ForEach(section.entries) { entry in
                entryRow(entry)
            }
        }
    }

    private func earlierBlock(_ past: WhatsNewRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("MURO \(past.version)", trailing: past.date)
            ForEach(past.sections) { section in
                ForEach(section.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: WhatsNewEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: entry.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.muroAccent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.glassSheen(0.13, 0.05)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(entry.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muroSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 18)
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
            GhostPill(title: "All Releases") {
                NSWorkspace.shared.open(WhatsNew.releasesURL)
            }
            PrimaryPill(title: "Done") { dismiss() }
        }
    }
}

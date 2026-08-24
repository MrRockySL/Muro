import SwiftUI
import AppKit

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
/// Deliberately empty for now: the owner asked for the button and the surface
/// first and will dictate the entries themselves. Filling it in later is a
/// data change and nothing else, because the sheet draws whatever is here.
enum WhatsNew {
    static let current = WhatsNewRelease(
        version: "3.0",
        date: nil,
        headline: "A new Muro. The notes for this update land here.",
        sections: []
    )

    /// Older releases, newest first. Shown under the current one once there
    /// is something to show.
    static let earlier: [WhatsNewRelease] = []

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
            Text("You are running Muro \(AppStore.appVersion)")
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

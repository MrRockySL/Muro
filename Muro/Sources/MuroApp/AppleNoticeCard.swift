import SwiftUI

/// What the Apple section is, said each time the section opens until the
/// person ticks "Do not show this message again" (owner, 2026-09-30).
///
/// **In the middle of the window, not a sheet.** macOS hangs a sheet from the
/// top of the window, and the owner asked for a card in the middle. It is
/// dressed like the sheets (the glass of `SheetSurface`, `SheetFooter` under
/// it) so it reads as the same app. `SheetSurface` itself is not used: its
/// `ClearWindowChrome` clears the window it sits in, which for a sheet is the
/// sheet's own window and here would be the gallery.
///
/// The page behind is dimmed and takes no clicks until the card is closed
/// with Got it, Return or Esc. The tick only counts when it closes.
struct AppleNoticeCard: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(AppleNoticeCard.hiddenKey) private var hidden = false
    @State private var dontShowAgain = false
    @State private var appeared = false

    static let hiddenKey = "appleNoticeHidden"

    /// Whether the section should raise the card when it opens.
    static var wanted: Bool { !UserDefaults.standard.bool(forKey: hiddenKey) }

    private static let radius: CGFloat = 28

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
            card
                .scaleEffect(appeared ? 1 : 0.95)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) { appeared = true }
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Text("It brings Apple's own wallpapers and screen savers into Muro:")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
                VStack(spacing: 8) {
                    row("mountain.2.fill", "Aerials",
                        "Apple's videos of landscapes, cities, oceans and space")
                    row("circle.lefthalf.filled", "Dynamic Wallpapers",
                        "Videos, still pictures, and a few drawn live by macOS")
                    row("moon.stars.fill", "Screen Savers",
                        "8 of Apple's own, like Hello and Flurry")
                }
                .padding(.top, 12)
                costNote
                    .padding(.top, 14)
            }
            .padding(26)
            footer
        }
        .frame(width: 480)
        .background(surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.3), .white.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 90)
        }
        .shadow(color: .black.opacity(0.55), radius: 40, y: 18)
        // Return is Got it (`PrimaryPill`); this is Esc.
        .background {
            Button("", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }

    /// Icon, title and the first thing to know, laid out like the delete
    /// confirmation's header so Muro's cards share one shape.
    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.glassSheen(0.14, 0.05)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text("About this section")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("This section was added by community request.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.muroSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
            Spacer(minLength: 0)
        }
    }

    /// One kind of wallpaper in the section. White glyphs, as everywhere
    /// inside the app outside Settings.
    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.glassSheen(0.13, 0.05)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muroSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.glassSheen(0.06, 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Amber, the app's colour for "worth knowing", as on the delete card's
    /// chips. Muro's own wallpapers are what the low CPU, RAM and power
    /// promise is about; this section is outside it.
    private var costNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.muroWarn)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.muroWarn.opacity(0.14)))
            Text("These are Apple's, not made for Muro, so some of them can use more CPU, RAM and power than Muro's own wallpapers.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.muroWarn.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.muroWarn.opacity(0.24), lineWidth: 1)
        )
    }

    /// The tick on the left, Got it on the right (owner, 2026-09-30).
    private var footer: some View {
        SheetFooter {
            Button {
                dontShowAgain.toggle()
            } label: {
                HStack(spacing: 9) {
                    SelectionTick(isSelected: dontShowAgain, size: 18)
                    Text("Do not show this message again")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(dontShowAgain ? Color.white : Color.muroSecondary)
                }
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: dontShowAgain)
            }
            .buttonStyle(.plain)
        } actions: {
            PrimaryPill(title: "Got it") { close() }
        }
    }

    /// The sheets' own glass, without their window clearing.
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return shape
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x11151C), Color(hex: 0x0B0E14)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.muroAccent.opacity(0.16), Color.muroAccent.opacity(0)
                    ]),
                    center: UnitPoint(x: 0.12, y: -0.06), startRadius: 0, endRadius: 480
                )
                .clipShape(shape)
            )
    }

    private func close() {
        if dontShowAgain { hidden = true }
        store.appleNoticeOpen = false
    }
}

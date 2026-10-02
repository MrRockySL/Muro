import SwiftUI

/// What the Apple section is, said each time the section opens until the
/// person ticks "Do not show this message again" (owner, 2026-09-30).
///
/// **In the middle of the window, not a sheet.** macOS hangs a sheet from the
/// top of the window, and the owner asked for a card in the middle.
///
/// **Dark liquid glass, wider, white glyphs, coloured words** (owner,
/// 2026-10-02: the first one read as AI written, and clear glass let the page
/// show through too much). The three kinds of wallpaper sit side by side as
/// tiles instead of a stacked list. The subtitle is in the accent and the
/// note about CPU, RAM and power in the amber the app uses for "worth
/// knowing".
/// The words are the card's first ones, saying "live wallpapers". The design
/// is "6.0 / Apple Notice · Card in the window" in the Muro App Design file,
/// and its glyphs are `NoticeGlyph`, drawn on the same grid as the Now Playing
/// icons.
///
/// The page behind takes no clicks until the card is closed with Got it,
/// Return or Esc. The tick only counts when it closes.
struct AppleNoticeCard: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(AppleNoticeCard.hiddenKey) private var hidden = false
    @State private var dontShowAgain = false
    @State private var appeared = false

    static let hiddenKey = "appleNoticeHidden"

    /// Whether the section should raise the card when it opens.
    static var wanted: Bool { !UserDefaults.standard.bool(forKey: hiddenKey) }

    private static let radius: CGFloat = 30
    private static let width: CGFloat = 580

    var body: some View {
        ZStack {
            Color.muroScrim
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
            header
            Text("It brings Apple's own live wallpapers and screen savers into Muro:")
                .font(.system(size: 13))
                .foregroundStyle(Color.muroInk.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            kinds
                .padding(.top, 14)
            powerNote
                .padding(.top, 16)
            Rectangle()
                .fill(Color.muroInk.opacity(0.1))
                .frame(height: 1)
                .padding(.top, 20)
            footer
                .padding(.top, 16)
        }
        .padding(.top, 26)
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .frame(width: Self.width)
        .background(surface)
        .modifier(DarkGlass(shape: shape))
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.muroInk.opacity(0.3), Color.muroInk.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, 90)
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
        // Return is Got it (`PrimaryPill`); this is Esc.
        .background {
            Button("", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }

    /// The people glyph in the top bar's white glass bubble, then the title
    /// and why the section exists, in the accent.
    private var header: some View {
        HStack(spacing: 14) {
            NoticeGlyph(kind: .people, size: 20)
                .shadow(color: .white.opacity(0.45), radius: 3)
                .bubbleSurface(size: 40, tint: .white)
            VStack(alignment: .leading, spacing: 3) {
                Text("About this section")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.muroInk)
                Text("This section was added by community request.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muroAccent)
            }
            Spacer(minLength: 0)
        }
    }

    /// The three kinds of wallpaper in the section, side by side and the same
    /// height whatever their text does. Names and glyphs are white (owner,
    /// 2026-10-02); the colour on the card is the subtitle and the note.
    private var kinds: some View {
        HStack(alignment: .top, spacing: 12) {
            kind("Aerials", "Apple's videos of landscapes, cities, oceans and space") {
                NoticeGlyph(kind: .aerials, size: 17)
            }
            kind("Dynamic Wallpapers", "Videos, still pictures, and a few drawn live by macOS") {
                NoticeGlyph(kind: .dynamic, size: 17)
            }
            kind("Screen Savers", "8 of Apple's own, like Hello and Flurry") {
                PlaceGlyph(place: .screenSaver, size: 17)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func kind<Glyph: View>(
        _ title: String,
        _ detail: String,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            glyph()
                .shadow(color: .white.opacity(0.45), radius: 3)
                .bubbleSurface(size: 34, tint: .white)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.muroInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muroInk.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(.glassSheen(0.08, 0.025)))
        .overlay(shape.strokeBorder(Color.muroInk.opacity(0.1), lineWidth: 1))
    }

    /// Muro's own live wallpapers are what the low CPU, RAM and power promise
    /// is about; this section is outside it. The one thing on the card worth
    /// stopping for, so it is amber, with the cost itself in bold.
    private var powerNote: some View {
        HStack(spacing: 10) {
            NoticeGlyph(kind: .power, size: 15)
                .opacity(0.72)
            (Text("These are Apple's, not made for Muro, so some of them can use ")
                + Text("more CPU, RAM and power").fontWeight(.semibold)
                + Text(" than Muro's own live wallpapers."))
                .font(.system(size: 12))
                .foregroundStyle(Color.muroWarn)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// The tick on the left, Got it on the right (owner, 2026-09-30).
    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                dontShowAgain.toggle()
            } label: {
                HStack(spacing: 9) {
                    SelectionTick(isSelected: dontShowAgain, size: 18)
                    Text("Do not show this message again")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(dontShowAgain ? Color.muroInk : Color.muroInk.opacity(0.62))
                }
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: dontShowAgain)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            PrimaryPill(title: "Got it") { close() }
        }
    }

    /// Dark and nearly solid, brighter at the top where the light lands, with
    /// the accent glow in the top corner that the sheets have. On the Dark
    /// look it is solid black with no glow: the bit of glass that showed
    /// through picked up the warm pictures behind it and read as brown
    /// (owner, 2026-10-02).
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        let solid = Appearance.shared.mode == .dark
        return shape
            .fill(
                LinearGradient(
                    colors: [Color.muroSheetTop.opacity(solid ? 1 : 0.9),
                             Color.muroSheetBottom.opacity(solid ? 1 : 0.95)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.muroGlow.opacity(0.16 * Appearance.shared.palette.wash), Color.muroGlow.opacity(0)
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

/// Liquid glass on macOS 26 with a dark tint, a thin material before it. The
/// card's own dark surface sits over it, so the page behind shows only as a
/// soft blur at the edges; clear glass let it through too much (owner,
/// 2026-10-02).
private struct DarkGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.muroShade.opacity(0.4)), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

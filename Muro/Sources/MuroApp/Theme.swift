import SwiftUI
import AppKit
import Observation

// Design tokens from the Figma file "Muro — App Design":
// bg #0A0C10 · accent (moonbeam) #A9C4FF · secondary #98A0AC · green #7DE8A8
// glass = white 7–12% fill + white 10–20% stroke · radii 16/18/99.
//
// Since 6.0 every one of them belongs to a palette, and there are three
// (owner, 2026-10-02). See `Appearance` below.

// MARK: - Appearance

/// The look Muro wears, picked in Settings, General, Appearance.
enum AppearanceMode: String, CaseIterable, Identifiable {
    /// Muro as it has always looked: midnight glass with the moonbeam blue.
    case standard = "default"
    /// The same glass in black and white: true black where the midnight blue
    /// was, white wherever the moonbeam was.
    case dark
    /// White glass, dark text, dark buttons.
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

extension Notification.Name {
    /// After the look changes, for the AppKit parts SwiftUI does not redraw by
    /// itself: the menu bar panel's material and rim.
    static let muroAppearanceChanged = Notification.Name("MuroAppearanceChanged")
}

/// The current look, and the palette that goes with it.
///
/// Observable, and that is the whole mechanism: every Muro colour is read
/// through `palette`, so a view whose body uses one is redrawn when the look
/// changes, in place, with its scroll position and state kept. Nothing is
/// rebuilt and no window is reopened.
@Observable
final class Appearance {
    static let shared = Appearance()
    static let defaultsKey = "appearance"

    private(set) var mode: AppearanceMode

    private init() {
        mode = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .standard
    }

    func set(_ newMode: AppearanceMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.defaultsKey)
        apply()
    }

    var isLight: Bool { mode == .light }

    /// What SwiftUI is told, for the system parts of each window.
    var colorScheme: ColorScheme { isLight ? .light : .dark }

    var palette: Palette {
        switch mode {
        case .standard: return .standard
        case .dark: return .mono
        case .light: return .light
        }
    }

    /// The AppKit side: system controls, materials, menus and dialogs follow
    /// `NSApp.appearance`. Called at launch and on every change.
    func apply() {
        NSApp?.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
        NotificationCenter.default.post(name: .muroAppearanceChanged, object: nil)
    }
}

/// Every colour Muro draws with, for one look.
struct Palette {
    /// The page behind everything (`muroBG`).
    var background: Color
    /// The three stops of the page gradient.
    var pageTop: Color, pageMid: Color, pageBottom: Color
    /// How strong the page's soft colour blooms are; 0 leaves them out.
    var blooms: Double
    /// Selected states, rings, section caps: the moonbeam in Default.
    var accent: Color
    /// Text and glyphs sitting on an `accent` fill.
    var onAccent: Color
    /// Light that glows rather than marks: accent haloes and radial washes.
    var glow: Color
    /// Second-level text.
    var secondary: Color
    /// Text, glyphs, hairlines and glass washes: white on the dark looks,
    /// near black on the light one, so every "white at 8%" surface becomes a
    /// matching tint of the other ink.
    var ink: Color
    /// Text on an `ink` fill: the white pills' dark label.
    var onInk: Color
    /// The tint that darkens glass on the dark looks and lightens it on the
    /// light one.
    var shade: Color
    /// The two editor sheets and every card shaped like them.
    var sheetTop: Color, sheetBottom: Color
    /// The base under a menu's glass.
    var menuBase: Color
    /// The glass tray a page's content sits in.
    var trayTop: Color, trayBottom: Color
    /// What dims the page behind a card in the middle of the window.
    var scrim: Color
    /// The track of a switch that is on.
    var switchOn: Color
    /// Accent and second-level text over a playing wallpaper, which stays
    /// dark whatever the look.
    var accentOnMedia: Color, secondaryOnMedia: Color
    var green: Color, warn: Color, danger: Color, violet: Color, teal: Color
    /// Whether materials should be the dark kind.
    var darkMaterials: Bool
    /// How strong the coloured light washed over sheets and cards is. Dark
    /// leaves it out: black there means black (owner, 2026-10-02).
    var wash: Double = 1

    /// Muro as it has always looked. Every value is the one the app used
    /// before 6.0, so Default is the old app exactly.
    static let standard = Palette(
        background: Color(hex: 0x0A0C10),
        pageTop: Color(hex: 0x07080D), pageMid: Color(hex: 0x070A0E), pageBottom: Color(hex: 0x05070A),
        blooms: 1,
        accent: Color(hex: 0xA9C4FF),
        onAccent: .black,
        glow: Color(hex: 0xA9C4FF),
        secondary: Color(hex: 0x98A0AC),
        ink: .white,
        onInk: .black,
        shade: .black,
        sheetTop: Color(hex: 0x11151C), sheetBottom: Color(hex: 0x0B0E14),
        menuBase: Color(hex: 0x0B0E14),
        trayTop: .white.opacity(0.055), trayBottom: .white.opacity(0.022),
        scrim: .black.opacity(0.5),
        switchOn: Color(hex: 0xA9C4FF),
        accentOnMedia: Color(hex: 0xA9C4FF), secondaryOnMedia: Color(hex: 0x98A0AC),
        green: Color(hex: 0x7DE8A8), warn: Color(hex: 0xFFC46B), danger: Color(hex: 0xFF6B6B),
        violet: Color(hex: 0x8E7BFF), teal: Color(hex: 0x4FD6C9),
        darkMaterials: true,
        wash: 1
    )

    /// Black and white. The midnight blue goes to true black and neutral
    /// greys, the moonbeam to white, the page's coloured blooms to a faint
    /// white one. Green, amber and red keep their meaning.
    static let mono = Palette(
        background: Color(hex: 0x050505),
        pageTop: Color(hex: 0x0B0B0B), pageMid: Color(hex: 0x060606), pageBottom: Color(hex: 0x000000),
        blooms: 0.35,
        accent: .white,
        onAccent: .black,
        glow: .white,
        secondary: Color(hex: 0x98989D),
        ink: .white,
        onInk: .black,
        shade: .black,
        sheetTop: Color(hex: 0x0A0A0A), sheetBottom: Color(hex: 0x000000),
        menuBase: Color(hex: 0x000000),
        trayTop: .white.opacity(0.055), trayBottom: .white.opacity(0.022),
        scrim: .black.opacity(0.55),
        // A white track would hide the switch's white knob.
        switchOn: Color(hex: 0x8E8E93),
        accentOnMedia: .white, secondaryOnMedia: Color(hex: 0xA1A1A6),
        green: Color(hex: 0x7DE8A8), warn: Color(hex: 0xFFC46B), danger: Color(hex: 0xFF6B6B),
        violet: .white, teal: .white,
        darkMaterials: true,
        wash: 0
    )

    /// White. Apple's light greys for the page and the second-level text, a
    /// near black for text and for everything the moonbeam marked, so the
    /// buttons go dark. Green, amber and red are deepened to read on white.
    static let light = Palette(
        background: Color(hex: 0xF5F5F7),
        pageTop: Color(hex: 0xF7F7F9), pageMid: Color(hex: 0xF0F0F3), pageBottom: Color(hex: 0xE8E8EC),
        blooms: 0,
        accent: Color(hex: 0x1D1D1F),
        onAccent: .white,
        glow: .clear,
        secondary: Color(hex: 0x6E6E73),
        ink: Color(hex: 0x1D1D1F),
        onInk: .white,
        shade: .white,
        sheetTop: Color(hex: 0xFFFFFF), sheetBottom: Color(hex: 0xF4F4F7),
        menuBase: Color(hex: 0xFFFFFF),
        trayTop: .white.opacity(0.8), trayBottom: .white.opacity(0.62),
        scrim: .black.opacity(0.22),
        switchOn: Color(hex: 0x1D1D1F),
        accentOnMedia: .white, secondaryOnMedia: Color(hex: 0xD1D1D6),
        green: Color(hex: 0x1E8E4E), warn: Color(hex: 0xB26A00), danger: Color(hex: 0xD7263D),
        violet: Color(hex: 0x5E5CE6), teal: Color(hex: 0x0E9E90),
        darkMaterials: false,
        wash: 0
    )
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    static var muroBG: Color { Appearance.shared.palette.background }
    static var muroAccent: Color { Appearance.shared.palette.accent }
    static var muroSecondary: Color { Appearance.shared.palette.secondary }
    static var muroGreen: Color { Appearance.shared.palette.green }

    // 6.0, the tokens the three looks needed. See `Palette`.
    static var muroInk: Color { Appearance.shared.palette.ink }
    static var muroOnInk: Color { Appearance.shared.palette.onInk }
    static var muroOnAccent: Color { Appearance.shared.palette.onAccent }
    static var muroGlow: Color { Appearance.shared.palette.glow }
    static var muroShade: Color { Appearance.shared.palette.shade }
    static var muroScrim: Color { Appearance.shared.palette.scrim }
    static var muroSwitch: Color { Appearance.shared.palette.switchOn }
    static var muroSheetTop: Color { Appearance.shared.palette.sheetTop }
    static var muroSheetBottom: Color { Appearance.shared.palette.sheetBottom }
    static var muroMenuBase: Color { Appearance.shared.palette.menuBase }
    static var muroAccentOnMedia: Color { Appearance.shared.palette.accentOnMedia }
    static var muroSecondaryOnMedia: Color { Appearance.shared.palette.secondaryOnMedia }
}

struct Glass: ViewModifier {
    var cornerRadius: CGFloat = 16
    var fill: Double = 0.07
    var stroke: Double = 0.12
    @Environment(\.muroOnMedia) private var onMedia

    func body(content: Content) -> some View {
        let ink = onMedia ? Color.white : Color.muroInk
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(ink.opacity(fill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ink.opacity(stroke), lineWidth: 1)
            )
    }
}

// MARK: - Over a playing wallpaper

private struct MuroOnMediaKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for controls drawn over a playing wallpaper: they keep the dark
    /// looks' white whatever the look is. The top bar sets it on the light
    /// look while Home's banner is behind it (owner, 2026-10-02).
    var muroOnMedia: Bool {
        get { self[MuroOnMediaKey.self] }
        set { self[MuroOnMediaKey.self] = newValue }
    }
}

/// Real liquid glass (macOS 26 `.glassEffect`) with a material fallback for
/// older SDKs. `tint` adds a dark wash for legibility over bright content.
struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = 16
    var tint: Double = 0
    var stroke: Double = 0.14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(tint > 0 ? .regular.tint(Color.muroShade.opacity(tint)) : .regular, in: shape)
                .overlay(shape.strokeBorder(Color.muroInk.opacity(stroke), lineWidth: 1))
        } else {
            content
                .background(shape.fill(Color.muroShade.opacity(tint)))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.muroInk.opacity(stroke), lineWidth: 1))
        }
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 16, fill: Double = 0.07, stroke: Double = 0.12) -> some View {
        modifier(Glass(cornerRadius: cornerRadius, fill: fill, stroke: stroke))
    }

    func glassCapsule(fill: Double = 0.07, stroke: Double = 0.12) -> some View {
        modifier(Glass(cornerRadius: 99, fill: fill, stroke: stroke))
    }

    func liquidGlass(cornerRadius: CGFloat = 16, tint: Double = 0, stroke: Double = 0.14) -> some View {
        modifier(LiquidGlass(cornerRadius: cornerRadius, tint: tint, stroke: stroke))
    }

    /// Soft top fade so scrolled content dissolves instead of getting a hard
    /// cut at the clip edge below the filter/tab rows.
    func topFade(_ height: CGFloat = 26) -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                Color.black
            }
        )
    }
}

// MARK: - Credits

enum Credits {
    static let name = "MrRockySL"
    static let url = URL(string: "https://github.com/MrRockySL")!
}

// MARK: - Formatting

/// "0.5×", "0.75×", "1×", "1.25×" — Text("\(double)") would print 0.500000.
func speedLabel(_ speed: Double) -> String {
    speed == speed.rounded() ? "\(Int(speed))×" : String(format: "%g×", speed)
}

func formatSize(_ bytes: Int64) -> String {
    // Megabytes of a million bytes, the way Finder counts them. These were
    // 1,048,576-byte units, so a card said 129 MB for a file Finder lists as
    // 135 MB (full check, 2026-10-01).
    let mb = Double(bytes) / 1_000_000
    if mb >= 1000 { return String(format: "%.2f GB", mb / 1000) }
    // Under a megabyte, one decimal. Whole numbers made a real half-second
    // clip read "0 MB" (full check, 2026-10-01), and anything with bytes in
    // it is at least "0.1 MB".
    if bytes > 0, mb < 0.95 { return String(format: "%.1f MB", max(mb, 0.1)) }
    return String(format: "%.0f MB", mb)
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Page surface (Muro 3.0)

// The library and explore pages used to sit on flat #0A0C10, which reads as a
// black box rather than a surface. Three layers fix that without a blur pass:
// a barely-blue gradient, three wide radial blooms, and an inset glass tray
// the content is clipped to. Radial gradients are used instead of `.blur()`
// because blur on a full-window view is the one thing that would break the
// CPU budget the whole app is built around.

extension Color {
    // Darkened 2026-08-30, about 40% down from 0x0B0E15 / 0x0C1017 / 0x090B10.
    // They keep the blue lean rather than going to neutral grey, because a
    // page that is exactly black makes the glass panels look like they are
    // floating on nothing.
    static var muroBGTop: Color { Appearance.shared.palette.pageTop }
    static var muroBGMid: Color { Appearance.shared.palette.pageMid }
    static var muroBGBottom: Color { Appearance.shared.palette.pageBottom }
    static var muroViolet: Color { Appearance.shared.palette.violet }
    static var muroTeal: Color { Appearance.shared.palette.teal }
    static var muroWarn: Color { Appearance.shared.palette.warn }
    static var muroDanger: Color { Appearance.shared.palette.danger }
}

// MARK: - Page changes

extension Animation {
    /// The one curve behind every page change in Muro: the main tabs, the
    /// Library's tabs, Explore's categories, and both card rows on Home.
    ///
    /// Slower and softer than the rest of the app on purpose. Muro's other
    /// animations are 0.12 to 0.24 second easeOuts on small controls, where
    /// quick reads as responsive. A page change moves a screenful of large
    /// photographs, and at that size quick reads as a flicker instead of as
    /// movement. Damping just under 1 lets it glide to a stop with no bounce,
    /// which is the difference between smooth and springy.
    static let muroPage = Animation.spring(response: 0.5, dampingFraction: 0.94)

    /// Switching between Home, Explore and Library. A plain crossfade, and
    /// deliberately not `.muroPage`.
    ///
    /// Those three are whole windows, not panels inside one. Sliding or
    /// scaling a whole window animates its background with it: the gradient
    /// and its blooms slide under the content, and the glass tray's rounded
    /// corners visibly resize. The Library's tabs and Explore's categories can
    /// move because they happen inside that tray, which stays still and clips
    /// them. Up here there is nothing outside the movement to hold the eye, so
    /// the only thing that reads as clean is not moving at all.
    ///
    /// Symmetric easing rather than a spring, because both halves of a
    /// crossfade should run at the same rate. A spring settles at the end,
    /// which on a fade means the last of the old page lingers.
    static let muroTab = Animation.easeInOut(duration: 0.28)
}

extension AnyTransition {
    /// One page replacing another, leaving towards the control that sent it
    /// and arriving from the far side.
    ///
    /// `shift` is which way the user went: positive for forwards, negative
    /// for back. Offset carries the direction, opacity does most of the work,
    /// and the barely-there scale keeps the outgoing page reading as passing
    /// behind the incoming one rather than beside it.
    ///
    /// The travel is deliberately far short of a full width slide. Moving a
    /// page its own width means it either races to get there or drags, and
    /// the two pages sweep across the whole window on the way past.
    static func muroPage(shift: CGFloat, distance: CGFloat = 86) -> AnyTransition {
        let leaving = shift >= 0 ? -distance : distance
        let arriving = shift >= 0 ? distance : -distance
        return .asymmetric(
            insertion: .offset(x: arriving)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.985)),
            removal: .offset(x: leaving)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.985))
        )
    }
}

/// One soft colour bloom, sized and placed as a fraction of the page.
private struct Bloom: View {
    var colour: Color
    var alpha: Double
    /// Centre, in unit coordinates of the containing page.
    var at: UnitPoint
    /// Radius, as a fraction of the page's larger edge.
    var spread: CGFloat

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height) * spread
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: colour.opacity(alpha), location: 0),
                    .init(color: colour.opacity(alpha * 0.42), location: 0.5),
                    .init(color: colour.opacity(0), location: 1)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: side / 2
            )
            .frame(width: side, height: side)
            .position(x: geo.size.width * at.x, y: geo.size.height * at.y)
        }
        .allowsHitTesting(false)
    }
}

/// The coloured surface behind a page. All three tabs use it. Home was left
/// out at first, on the theory that a 4K wallpaper is already playing there,
/// but the hero is only the top of the page and everything below it read as
/// flatter and darker than Explore and Library.
struct MuroPageBackground: View {
    private var blooms: Double { Appearance.shared.palette.blooms }

    var body: some View {
        LinearGradient(
            colors: [.muroBGTop, .muroBGMid, .muroBGBottom],
            startPoint: .top, endPoint: .bottom
        )
        // The blooms, not the gradient, are what set how dark the page reads.
        // The gradient stops are all within a few steps of black already, so
        // darkening only those changes almost nothing; these are the numbers
        // to move. Down from 0.26 / 0.20 / 0.11 on 2026-08-30, kept rather
        // than removed so the page still has some depth to it.
        //
        // The violet one came down twice, to 0.05. It is the right hand glow,
        // and it reads far stronger on Home than anywhere else: Explore and
        // Library cover most of their background with the glass tray, while
        // Home leaves it bare between the hero and the rows. Judge this one on
        // Home, not on the other two, or it will always look too strong there.
        //
        // Since 6.0 each look sets their strength: full in Default, a faint
        // white in Dark, none in Light, where a coloured cloud reads as a
        // stain on the white.
        .overlay(Bloom(colour: .muroGlow, alpha: 0.14 * blooms, at: UnitPoint(x: 0.16, y: 0.06), spread: 0.86))
        .overlay(Bloom(colour: .muroViolet, alpha: 0.05 * blooms, at: UnitPoint(x: 0.88, y: 0.85), spread: 0.82))
        .overlay(Bloom(colour: .muroTeal, alpha: 0.06 * blooms, at: UnitPoint(x: 0.40, y: 1.02), spread: 0.62))
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The rounded glass panel a page's content sits inside. Content is clipped to
/// it, so a scrolled grid dissolves at the corner instead of spilling onto the
/// background.
struct GlassTray<Content: View>: View {
    var cornerRadius: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [Appearance.shared.palette.trayTop, Appearance.shared.palette.trayBottom],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.muroInk.opacity(0.09), lineWidth: 1))
            // The top edge catch-light: the detail that makes glass read as
            // glass rather than as a lighter rectangle.
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, cornerRadius * 3)
            }
            .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 12)
    }
}

// MARK: - Glass building blocks

extension ShapeStyle where Self == LinearGradient {
    /// Top-lit glass fill. Two stops, because a flat white wash looks like
    /// paper and a real pane is brighter where the light lands.
    static func glassSheen(_ top: Double, _ bottom: Double) -> LinearGradient {
        LinearGradient(
            colors: [Color.muroInk.opacity(top), Color.muroInk.opacity(bottom)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

extension View {
    /// A card or panel in the 3.0 language: sheened glass, hairline border,
    /// and an accent ring plus glow when it is the active one.
    func glassPanel(
        cornerRadius: CGFloat = 22,
        active: Bool = false,
        top: Double = 0.065,
        bottom: Double = 0.028
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(.glassSheen(active ? 0.10 : top, active ? 0.04 : bottom)))
            .overlay(
                shape.strokeBorder(
                    active ? Color.muroAccent.opacity(0.5) : Color.muroInk.opacity(0.1),
                    lineWidth: active ? 1.5 : 1
                )
            )
            .shadow(color: active ? Color.muroAccent.opacity(0.18) : .clear, radius: 13, x: 0, y: 3)
    }
}

// MARK: - The look, per window

/// What each window tells SwiftUI about light and dark, read inside a body so
/// it follows the look the moment it changes.
private struct MuroColorScheme: ViewModifier {
    func body(content: Content) -> some View {
        content.preferredColorScheme(Appearance.shared.colorScheme)
    }
}

extension View {
    func muroColorScheme() -> some View { modifier(MuroColorScheme()) }
}

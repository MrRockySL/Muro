import SwiftUI
import AppKit
import CoreImage
import Observation
import MuroKit

// Every colour Muro draws with belongs to a palette, one for Light and one for
// Dark, which are macOS 26's own (owner, 2026-11-20). System follows the Mac.
// See `Appearance` below.

// MARK: - Appearance

/// The look Muro wears, picked in Settings, General, Appearance (owner,
/// 2026-11-22: Light, Dark and System; the old Default look is gone).
enum AppearanceMode: String, CaseIterable, Identifiable {
    /// macOS's Light.
    case light
    /// macOS's Dark.
    case dark
    /// Whatever the Mac is on, Light or Dark, changing with it.
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return L("Light", ctx: "look")
        case .dark: return L("Dark", ctx: "look")
        case .system: return L("System", ctx: "look")
        }
    }

    /// The saved choice. Nothing saved, or the Default look Muro had before
    /// 6.2, is System.
    static func saved(_ raw: String?) -> AppearanceMode {
        raw.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }
}

/// The look Muro is drawn in right now. System is whichever of the two the
/// Mac is on.
enum AppearanceLook {
    case light, dark
}

extension Notification.Name {
    /// After the look changes, for the AppKit parts SwiftUI does not redraw by
    /// itself: the menu bar panel's material and rim. Also when the Mac
    /// changes between Light and Dark while Muro follows it.
    static let muroAppearanceChanged = Notification.Name("MuroAppearanceChanged")
}

/// The current look, and the palette that goes with it.
///
/// Observable, and that is the whole mechanism: every Muro colour is read
/// through `palette`, so a view whose body uses one is redrawn when the look
/// changes, in place, with its scroll position and state kept. Nothing is
/// rebuilt and no window is reopened. That holds when the Mac changes too.
@Observable
final class Appearance {
    static let shared = Appearance()
    static let defaultsKey = "appearance"

    private(set) var mode: AppearanceMode
    /// The Mac's own look, kept up to date while Muro follows it.
    private(set) var systemLook: AppearanceLook

    @ObservationIgnored private var systemWatch: NSKeyValueObservation?
    @ObservationIgnored private var themeObserver: NSObjectProtocol?

    private init() {
        mode = AppearanceMode.saved(UserDefaults.standard.string(forKey: Self.defaultsKey))
        // A first guess from macOS's own setting, before AppKit is running.
        // `start` replaces it with what AppKit reports.
        systemLook = Self.savedSystemLook()
    }

    /// At launch, before any window opens: puts the look on AppKit and starts
    /// following the Mac. AppKit reports the Mac's look through the app's
    /// effective appearance while Muro sets none of its own (System); the
    /// notification macOS sends when the Mac's look changes is a second way
    /// to hear about it.
    func start() {
        if systemWatch == nil, let app = NSApp {
            systemWatch = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.followSystem() }
            }
            themeObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil, queue: .main
            ) { [weak self] _ in
                // A turn later, so AppKit has taken the new look first.
                DispatchQueue.main.async { self?.followSystem() }
            }
        }
        apply()
    }

    func set(_ newMode: AppearanceMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.defaultsKey)
        apply()
    }

    var look: AppearanceLook {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemLook
        }
    }

    var isLight: Bool { look == .light }

    /// What SwiftUI is told, for the system parts of each window.
    var colorScheme: ColorScheme { isLight ? .light : .dark }

    var palette: Palette {
        switch look {
        case .light: return .light
        case .dark: return .mono
        }
    }

    /// The AppKit side: system controls, materials, menus and dialogs follow
    /// `NSApp.appearance`. Called at launch and on every change. On System
    /// Muro sets none, so AppKit draws whatever the Mac is on.
    func apply() {
        switch mode {
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp?.appearance = nil
            if let now = Self.reportedSystemLook() { systemLook = now }
        }
        NotificationCenter.default.post(name: .muroAppearanceChanged, object: nil)
    }

    /// The Mac changed between Light and Dark, or AppKit says so again.
    /// Nothing happens unless Muro follows the Mac and the look really moved.
    private func followSystem() {
        guard mode == .system, let now = Self.reportedSystemLook(), now != systemLook else { return }
        systemLook = now
        NotificationCenter.default.post(name: .muroAppearanceChanged, object: nil)
    }

    /// What AppKit draws the app in. That is the Mac's own look only while
    /// Muro sets no appearance of its own.
    private static func reportedSystemLook() -> AppearanceLook? {
        guard let app = NSApp, app.appearance == nil else { return nil }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// macOS's own setting, readable before AppKit runs: "Dark" on Dark,
    /// nothing on Light.
    private static func savedSystemLook() -> AppearanceLook {
        let domain = kCFPreferencesAnyApplication
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let style = CFPreferencesCopyValue(
            "AppleInterfaceStyle" as CFString, domain,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? String
        return style == "Dark" ? .dark : .light
    }
}

/// Every colour Muro draws with, for one look.
struct Palette {
    /// The page behind everything (`muroBG`).
    var background: Color
    /// Selected states, rings, the switch that is on: the system accent.
    var accent: Color
    /// Text and glyphs sitting on an `accent` fill.
    var onAccent: Color
    /// Light that glows rather than marks: accent haloes and radial washes.
    var glow: Color
    /// Second-level text.
    var secondary: Color
    /// Text, glyphs, hairlines and glass washes: white on Dark, near black on
    /// Light, so every "white at 8%" surface becomes a matching tint of the
    /// other ink.
    var ink: Color
    /// Text on an `ink` fill.
    var onInk: Color
    /// The tint that darkens glass on Dark and lightens it on Light.
    var shade: Color
    /// The two editor sheets and every card shaped like them.
    var sheetTop: Color, sheetBottom: Color
    /// The base under a menu's glass.
    var menuBase: Color
    /// What dims the page behind a card in the middle of the window.
    var scrim: Color
    /// The track of a switch that is on.
    var switchOn: Color
    /// Accent and second-level text over a playing wallpaper, which stays
    /// dark whatever the look.
    var accentOnMedia: Color, secondaryOnMedia: Color
    var green: Color, warn: Color, danger: Color
    /// Whether materials should be the dark kind.
    var darkMaterials: Bool
    /// How strong the coloured light washed over sheets and cards is. Both
    /// looks leave it out: Apple's sheets and menus carry no coloured light.
    var wash: Double = 0

    /// The small caps that head a section.
    var caption: Color
    /// The selected item of a bar that moves between pages (the top bar's
    /// tabs, the Library's tabs, Explore's categories): Apple's toolbars give
    /// it a soft grey pill, not the accent.
    var navSelected: Color
    var onNavSelected: Color
    /// The chosen value of a picker (Appearance, Quality, a speed): Apple's
    /// form pickers fill it with the accent.
    var picked: Color
    var onPicked: Color
    /// The one button a sheet or bar is asking you to press.
    var primary: Color
    var onPrimary: Color
    /// Hairline rims on controls and panels. Apple's controls have none.
    var rim: Color
    /// The shadow under a control. Apple's controls cast none.
    var controlShadow: Color

    /// macOS's Dark. Every colour is one of macOS's own, so it resolves to
    /// exactly what Apple's apps draw: the window's dark grey, its text greys,
    /// its fills, and the accent the person picked in System Settings (blue
    /// for most). Measured against App Store, Music, Calendar and System
    /// Settings on 2026-11-20. Over a playing wallpaper things stay white.
    static let mono = Palette(
        background: .sysWindow,
        accent: .sysAccent,
        onAccent: .white,
        glow: .clear,
        secondary: .sysSecondaryLabel,
        ink: .sysLabel,
        onInk: .sysInverse,
        shade: .black,
        sheetTop: .sysWindow, sheetBottom: .sysWindow,
        menuBase: .sysWindow,
        scrim: .black.opacity(0.25),
        switchOn: .sysAccent,
        accentOnMedia: .white, secondaryOnMedia: Color(hex: 0xA1A1A6),
        green: .sysGreen, warn: .sysWarn, danger: .sysDanger,
        darkMaterials: true,
        wash: 0,
        caption: .sysSecondaryLabel,
        navSelected: .sysFill, onNavSelected: .sysLabel,
        picked: .sysAccent, onPicked: .white,
        primary: .sysAccent, onPrimary: .white,
        rim: .clear,
        controlShadow: .clear
    )

    /// macOS's Light, the same way: white window, Apple's text greys and
    /// fills, the system accent. Green, amber and red are a shade deeper than
    /// Apple's, the way its own status text is, so they read on white.
    static let light = Palette(
        background: .sysWindow,
        accent: .sysAccent,
        onAccent: .white,
        glow: .clear,
        secondary: .sysSecondaryLabel,
        ink: .sysLabel,
        onInk: .sysInverse,
        // The window's own colour: white here, and dark wherever a part of
        // the light look is drawn dark, such as the bar over a playing video.
        shade: .sysWindow,
        sheetTop: .sysWindow, sheetBottom: .sysWindow,
        menuBase: .sysWindow,
        scrim: .black.opacity(0.1),
        switchOn: .sysAccent,
        // Dark's grey where a part of the light look is drawn dark, such as
        // the menu bar panel (owner, 2026-11-21).
        accentOnMedia: .white,
        secondaryOnMedia: .dynamic(light: NSColor(hex: 0xD1D1D6), dark: NSColor(hex: 0xA1A1A6)),
        green: .sysGreen, warn: .sysWarn, danger: .sysDanger,
        darkMaterials: false,
        wash: 0,
        caption: .sysSecondaryLabel,
        navSelected: .sysFill, onNavSelected: .sysLabel,
        picked: .sysAccent, onPicked: .white,
        primary: .sysAccent, onPrimary: .white,
        rim: .clear,
        controlShadow: .clear
    )
}

extension Color {
    // macOS 26's own colours, Light and Dark, as Apple's apps get them.
    //
    // Written out rather than read from NSColor's names, because Muro is
    // built to run on macOS 14, and macOS hands an app built that way the
    // colours of the design before 26: a grey window (#ECECEC) and greys about
    // twice as strong for every fill, line and second-level text. Measured on
    // 2026-11-20 against a test app built both ways. These are the values the
    // names return to an app built for 26 (sRGB), so Muro draws exactly what
    // App Store, Music and System Settings draw. The accent is the same either
    // way and stays the person's own choice from System Settings.
    static let sysWindow = dynamic(light: .white, dark: NSColor(hex: 0x1E1E1E))
    static let sysLabel = dynamic(light: .black.withAlphaComponent(0.85), dark: .white.withAlphaComponent(0.85))
    static let sysSecondaryLabel = dynamic(light: .black.withAlphaComponent(0.5), dark: .white.withAlphaComponent(0.55))
    static let sysTertiaryLabel = dynamic(light: .black.withAlphaComponent(0.26), dark: .white.withAlphaComponent(0.25))
    static let sysAccent = Color(nsColor: .controlAccentColor)
    static let sysSeparator = dynamic(light: .black.withAlphaComponent(0.1), dark: .white.withAlphaComponent(0.12))
    /// A switch that is off, a selected toolbar segment (10%).
    static let sysFill = dynamic(light: .black.withAlphaComponent(0.1), dark: .white.withAlphaComponent(0.1))
    /// A button, a segmented control's track, a pop-up (8%).
    static let sysControlFill = dynamic(light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.08))
    /// A grouped box like System Settings' (3%).
    static let sysGroupFill = dynamic(light: .black.withAlphaComponent(0.03), dark: .white.withAlphaComponent(0.03))

    /// White on Light and black on Dark: words on a fill of the text colour.
    static let sysInverse = dynamic(light: .white, dark: .black)
    /// Apple's green, orange and red on Dark. On Light the shade deeper that
    /// Apple's own status words use, so they read on white.
    static let sysGreen = dynamic(light: NSColor(hex: 0x1E8E4E), dark: .systemGreen)
    static let sysWarn = dynamic(light: NSColor(hex: 0xB26A00), dark: .systemOrange)
    static let sysDanger = dynamic(light: NSColor(hex: 0xD7263D), dark: .systemRed)

    /// One colour on Light and another on Dark, picked the way macOS picks
    /// its own: by the appearance of whatever is drawing it. So a part of the
    /// light look that is told to be dark (the bar over a video) gets Dark's.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
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

    // 6.0, the tokens the looks needed. See `Palette`.
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

    // 6.2, the roles Light and Dark draw the way macOS does. See `Palette`.
    static var muroCaption: Color { Appearance.shared.palette.caption }
    static var muroNavSelected: Color { Appearance.shared.palette.navSelected }
    static var muroOnNavSelected: Color { Appearance.shared.palette.onNavSelected }
    static var muroPicked: Color { Appearance.shared.palette.picked }
    static var muroOnPicked: Color { Appearance.shared.palette.onPicked }
    static var muroPrimary: Color { Appearance.shared.palette.primary }
    static var muroOnPrimary: Color { Appearance.shared.palette.onPrimary }
    static var muroRim: Color { Appearance.shared.palette.rim }
    static var muroControlShadow: Color { Appearance.shared.palette.controlShadow }
}

struct Glass: ViewModifier {
    var cornerRadius: CGFloat = 16
    var fill: Double = 0.07
    var stroke: Double = 0.12
    @Environment(\.muroOnMedia) private var onMedia
    @Environment(\.muroClassicGlass) private var classic

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if !onMedia && !classic {
            // macOS draws a control as a flat fill with no rim: 8% for a
            // button, a field or a segmented track, 3% for a box that groups
            // things. The light washes Muro asks for map onto those two.
            content
                .background(shape.fill(fill >= 0.07 ? Color.sysControlFill : Color.sysGroupFill))
        } else {
            let ink = onMedia ? Color.white : Color.muroInk
            content
                .background(shape.fill(ink.opacity(fill)))
                .overlay(shape.strokeBorder(ink.opacity(stroke), lineWidth: 1))
        }
    }
}

// MARK: - Liquid Glass (Light and Dark)

extension View {
    /// macOS 26's Liquid Glass, for a control that floats over the page on
    /// Light and Dark: a tab bar, a toolbar button, the menu bar panel and its
    /// controls, the bar over a video. It is the glass Apple's own apps are
    /// made of, with its own edge light and shadow, so nothing is drawn around
    /// it. `interactive` gives it the press response of Apple's glass buttons.
    /// Before macOS 26 it is a blurred material with a hairline edge.
    func appleGlass<S: InsettableShape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(AppleGlass(shape: shape, interactive: interactive, tint: tint))
    }
}

private struct AppleGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    @Environment(\.muroRegularGlass) private var regular

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(style, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.sysSeparator, lineWidth: 0.5))
        }
    }

    @available(macOS 26.0, *)
    private var style: SwiftUI.Glass {
        var glass = lookGlass(regular: regular)
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Dark takes the regular glass, which darkens what is behind it. Light takes
/// the clear glass: the regular one turns milky white on Light, and Apple's
/// own glass on Light reads as clear glass bending the colours behind it
/// (owner, 2026-11-20: "use the pure liquid glass, not the whitish one").
/// Where `muroRegularGlass` is set, Light keeps the regular glass too.
@available(macOS 26.0, *)
func lookGlass(regular: Bool) -> SwiftUI.Glass {
    Appearance.shared.isLight && !regular ? .clear : .regular
}

private struct MuroRegularGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True where Light keeps the regular, whitish Liquid Glass instead of
    /// the clear one for the glass controls (`appleGlass`): the menu bar
    /// panel, the panel and menus that open over a playing wallpaper on a
    /// wallpaper's page, and the card at the top of the Apple section. Clear
    /// glass let the picture behind show through so much that the words on
    /// it could not be read (owner, 2026-11-21: "You have to go with the
    /// whitish liquid because there is no solution for that"). Dark always
    /// has the regular glass, so this changes nothing there. Menus and cards
    /// themselves (`GlassCard`) are the regular glass on every look.
    ///
    /// A menu or card is drawn by the window, away from the control that
    /// opens it, so the control reads this where it sits and hands it on.
    var muroRegularGlass: Bool {
        get { self[MuroRegularGlassKey.self] }
        set { self[MuroRegularGlassKey.self] = newValue }
    }
}

private struct MuroClassicGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True where a part is drawn in Muro's classic glass, its washes and
    /// rims, in the look's own colours: the look Muro had before Light and
    /// Dark, kept for one place. The menu bar panel on Dark is that dark glass
    /// with Dark's macOS blue buttons (owner, 2026-11-21: "the same default,
    /// but the buttons go with blue"). See `StatusBarController.drawsClassicPanel`.
    var muroClassicGlass: Bool {
        get { self[MuroClassicGlassKey.self] }
        set { self[MuroClassicGlassKey.self] = newValue }
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
                .overlay(shape.strokeBorder(Color.muroRim.opacity(stroke), lineWidth: 1))
        } else {
            content
                .background(shape.fill(Color.muroShade.opacity(tint)))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.muroRim.opacity(stroke), lineWidth: 1))
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
    if mb >= 1000 { return L("%@ GB", decimalText(mb / 1000, places: 2)) }
    // Under a megabyte, one decimal. Whole numbers made a real half-second
    // clip read "0 MB" (full check, 2026-10-01), and anything with bytes in
    // it is at least "0.1 MB".
    if bytes > 0, mb < 0.95 { return L("%@ MB", decimalText(max(mb, 0.1), places: 1)) }
    return L("%@ MB", decimalText(mb, places: 0))
}

/// A number with a fixed count of decimals, written the way the chosen
/// language writes it: "1.25" in English, "1,25" in German.
func decimalText(_ value: Double, places: Int) -> String {
    DecimalWriter.shared.text(value, places: places)
}

/// Keeps one number formatter per language and count of decimals. A formatter
/// is slow to make, and a grid of cards asks for a size on every card.
private final class DecimalWriter: @unchecked Sendable {
    static let shared = DecimalWriter()
    private let lock = NSLock()
    private var formatters: [String: NumberFormatter] = [:]

    func text(_ value: Double, places: Int) -> String {
        let language = Localization.shared.language
        let key = "\(language.rawValue)#\(places)"
        return lock.withLock {
            let formatter = formatters[key] ?? {
                let made = NumberFormatter()
                made.locale = language.locale
                made.numberStyle = .decimal
                made.usesGroupingSeparator = false
                made.minimumFractionDigits = places
                made.maximumFractionDigits = places
                formatters[key] = made
                return made
            }()
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(places)f", value)
        }
    }
}

/// A line with one part in bold. The bold part sits between two stars in the
/// text itself: "uses *more power* than the rest".
func emphasisedText(_ line: String) -> Text {
    line.components(separatedBy: "*").enumerated().reduce(Text(verbatim: "")) { text, part in
        text + (part.offset % 2 == 1
            ? Text(verbatim: part.element).fontWeight(.semibold)
            : Text(verbatim: part.element))
    }
}

/// "A, B and C", joined the way the chosen language joins a list.
func listText(_ items: [String]) -> String {
    let formatter = ListFormatter()
    formatter.locale = Localization.shared.locale
    return formatter.string(from: items) ?? items.joined(separator: ", ")
}

/// A wallpaper's category in the chosen language. The category itself is
/// stored and compared in English, the way the catalog names it; only what is
/// shown goes through here. One Muro has no word for comes back unchanged.
func categoryTitle(_ category: String) -> String {
    L(category, ctx: "category")
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Page surface

extension Color {
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

/// The surface behind a page. All three tabs use it: the window's colour,
/// lit from the top by the wallpaper's own colours (`AmbientLight`). Apple's
/// apps never sit their glass on an empty page: their sidebars and toolbars
/// show the desktop through them, macOS tints its windows with the wallpaper,
/// and Music and TV light their pages with the artwork. On a flat page the
/// glass bars read as grey pills (owner, 2026-11-20).
struct MuroPageBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Color.sysWindow
            AmbientLight()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The wallpaper's own light at the top of a page, on Light and Dark.
///
/// The wallpaper Home features (`heroItem`: the one picked in Home's strip,
/// else the one on the desktop) is blurred into a wash of its colours, made
/// darker and richer on Dark and paler on Light, and laid over the top of the
/// page, fading out by two thirds of the way down. It gives the Liquid Glass
/// bars real colour to bend, as the desktop does through Apple's sidebars.
/// On Home it sits behind the banner, so the banner melts into its own light.
///
/// A still picture, made once per wallpaper and look off the main thread and
/// kept: nothing here redraws while the page scrolls or the video plays.
struct AmbientLight: View {
    @EnvironmentObject var store: AppStore
    @State private var landed = 0

    private var key: String? {
        store.heroItem.map { "\($0.id)|\(Appearance.shared.isLight ? "light" : "dark")" }
    }

    var body: some View {
        let key = key
        GeometryReader { geo in
            ZStack {
                if let key, let image = AmbientLightPicture.cached(key) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height * 0.72)
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white.opacity(0.85), location: 0.35),
                                    .init(color: .white.opacity(0.4), location: 0.65),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .id(key)
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.45), value: "\(key ?? "") \(landed)")
        .task(id: key) {
            guard let key, AmbientLightPicture.cached(key) == nil,
                  let item = store.heroItem, let path = store.thumbnailPath(for: item) else { return }
            let dark = !Appearance.shared.isLight
            let picture = await Task.detached(priority: .utility) {
                AmbientLightPicture.make(thumbnailPath: path, dark: dark)
            }.value
            guard let picture, !Task.isCancelled else { return }
            AmbientLightPicture.remember(picture, for: key)
            landed += 1
        }
    }
}

/// Makes and keeps the ambient light's pictures.
enum AmbientLightPicture {
    /// Wallpaper id and look to picture. Touched on the main thread only.
    private static var cache: [String: CGImage] = [:]

    static func cached(_ key: String) -> CGImage? { cache[key] }

    static func remember(_ picture: CGImage, for key: String) {
        // A handful at most: one per wallpaper featured this session.
        if cache.count > 24 { cache.removeAll() }
        cache[key] = picture
    }

    /// The thumbnail at 192 pixels, blurred until no shape is left, then on
    /// Dark richer and darker (the light of the picture, not the picture),
    /// on Light mixed most of the way to white. Off the main thread.
    static func make(thumbnailPath path: String, dark: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 192,
              ] as CFDictionary)
        else { return nil }
        let input = CIImage(cgImage: thumb)
        let extent = input.extent
        var light = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 14)
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: dark ? 1.35 : 1.3,
                kCIInputContrastKey: 1.0,
                kCIInputBrightnessKey: 0.0,
            ])
        // Dark keeps half of the light. Light keeps 62% and is lifted the
        // rest of the way to white: a light page with the wallpaper's colour
        // in it, so its glass has colour to bend the way Dark's has (owner,
        // 2026-11-20). Tuned against his own wallpapers in a copy of Explore.
        let keep: CGFloat = dark ? 0.52 : 0.62
        let lift: CGFloat = dark ? 0.0 : 0.38
        light = light.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0),
        ])
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(light, from: extent)
    }
}

/// The rounded glass panel a page's content sits inside. Content is clipped to
/// it, so a scrolled grid dissolves at the corner instead of spilling onto the
/// background.
struct GlassTray<Content: View>: View {
    var cornerRadius: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        // App Store, Music and TV put their grids straight on the window: no
        // panel, no rim, no shadow. The content is still clipped, so a
        // scrolled grid ends where the tray always ended.
        content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Glass building blocks

extension ShapeStyle where Self == LinearGradient {
    /// A glass fill, given as the strength at its top and bottom. macOS fills
    /// a control flat, with no light falling on it, so it is the strength of
    /// the middle, a touch more because the ink here is Apple's 85% text
    /// colour: 0.11/0.05 lands on the 8% Apple fills a button with, 0.05/0.02
    /// on the 3% of a box.
    static func glassSheen(_ top: Double, _ bottom: Double) -> LinearGradient {
        let flat = Color.muroInk.opacity((top + bottom) / 2 * 1.15)
        return LinearGradient(colors: [flat, flat], startPoint: .top, endPoint: .bottom)
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
                    active ? Color.muroAccent.opacity(0.5) : Color.muroRim.opacity(0.1),
                    lineWidth: active ? 1.5 : 1
                )
            )
            .shadow(color: active ? Color.muroGlow.opacity(0.18) : .clear, radius: 13, x: 0, y: 3)
    }
}

// MARK: - The look, per window

/// What each window tells SwiftUI about light and dark, read inside a body so
/// it follows the look the moment it changes. A window that is dark on every
/// look (the menu bar panel and its menus) says so with
/// `muroColorSchemeOverride`, which every card inside it follows too.
private struct MuroColorScheme: ViewModifier {
    @Environment(\.muroColorSchemeOverride) private var override

    func body(content: Content) -> some View {
        content.preferredColorScheme(override ?? Appearance.shared.colorScheme)
    }
}

private struct MuroColorSchemeOverrideKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    /// Set on a window drawn in one scheme whatever the look. Nil: the look's.
    var muroColorSchemeOverride: ColorScheme? {
        get { self[MuroColorSchemeOverrideKey.self] }
        set { self[MuroColorSchemeOverrideKey.self] = newValue }
    }
}

extension View {
    func muroColorScheme() -> some View { modifier(MuroColorScheme()) }
}

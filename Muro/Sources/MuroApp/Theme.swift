import SwiftUI

// Design tokens from the Figma file "Muro — App Design":
// bg #0A0C10 · accent (moonbeam) #A9C4FF · secondary #98A0AC · green #7DE8A8
// glass = white 7–12% fill + white 10–20% stroke · radii 16/18/99.

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

    static let muroBG = Color(hex: 0x0A0C10)
    static let muroAccent = Color(hex: 0xA9C4FF)
    static let muroSecondary = Color(hex: 0x98A0AC)
    static let muroGreen = Color(hex: 0x7DE8A8)
}

struct Glass: ViewModifier {
    var cornerRadius: CGFloat = 16
    var fill: Double = 0.07
    var stroke: Double = 0.12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(fill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(stroke), lineWidth: 1)
            )
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
                .glassEffect(tint > 0 ? .regular.tint(Color.black.opacity(tint)) : .regular, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(stroke), lineWidth: 1))
        } else {
            content
                .background(shape.fill(Color.black.opacity(tint)))
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(stroke), lineWidth: 1))
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
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
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
    static let muroBGTop = Color(hex: 0x07080D)
    static let muroBGMid = Color(hex: 0x070A0E)
    static let muroBGBottom = Color(hex: 0x05070A)
    static let muroViolet = Color(hex: 0x8E7BFF)
    static let muroTeal = Color(hex: 0x4FD6C9)
    static let muroWarn = Color(hex: 0xFFC46B)
    static let muroDanger = Color(hex: 0xFF6B6B)
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
        .overlay(Bloom(colour: .muroAccent, alpha: 0.14, at: UnitPoint(x: 0.16, y: 0.06), spread: 0.86))
        .overlay(Bloom(colour: .muroViolet, alpha: 0.05, at: UnitPoint(x: 0.88, y: 0.85), spread: 0.82))
        .overlay(Bloom(colour: .muroTeal, alpha: 0.06, at: UnitPoint(x: 0.40, y: 1.02), spread: 0.62))
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
                        colors: [.white.opacity(0.055), .white.opacity(0.022)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
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
            colors: [.white.opacity(top), .white.opacity(bottom)],
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
                    active ? Color.muroAccent.opacity(0.5) : Color.white.opacity(0.1),
                    lineWidth: active ? 1.5 : 1
                )
            )
            .shadow(color: active ? Color.muroAccent.opacity(0.18) : .clear, radius: 13, x: 0, y: 3)
    }
}

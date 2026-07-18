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

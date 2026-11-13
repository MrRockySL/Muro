import SwiftUI
import AppKit

/// Where Muro's community lives: the Discord server and the website. Shown on
/// the welcome's community step and in Settings > About.
enum CommunityLinks {
    /// The server's permanent invite, into #welcome.
    static let discord = URL(string: "https://discord.gg/w9qtWysSpA")!
    static let website = URL(string: "https://murowallpaper.com")!
}

/// Discord's logo, from its official SVG (24 by 24), drawn into any square.
/// The eyes are holes, so fill it with `FillStyle(eoFill: true)`.
func discordLogoPath(in rect: CGRect) -> Path {
    // The logo is wider than it is tall: centre it in the square.
    let size = min(rect.width, rect.height)
    let origin = CGPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * size, y: origin.y + y * size) }
    var p = Path()
    p.move(to: pt(0.847, 0.182))
    p.addCurve(to: pt(0.643, 0.119), control1: pt(0.782, 0.152), control2: pt(0.713, 0.131))
    p.addCurve(to: pt(0.64, 0.12), control1: pt(0.642, 0.119), control2: pt(0.64, 0.119))
    p.addCurve(to: pt(0.614, 0.173), control1: pt(0.631, 0.136), control2: pt(0.621, 0.157))
    p.addCurve(to: pt(0.386, 0.173), control1: pt(0.538, 0.161), control2: pt(0.461, 0.161))
    p.addCurve(to: pt(0.36, 0.12), control1: pt(0.379, 0.156), control2: pt(0.369, 0.136))
    p.addCurve(to: pt(0.357, 0.119), control1: pt(0.359, 0.119), control2: pt(0.358, 0.119))
    p.addCurve(to: pt(0.153, 0.182), control1: pt(0.286, 0.131), control2: pt(0.218, 0.152))
    p.addCurve(to: pt(0.152, 0.183), control1: pt(0.153, 0.182), control2: pt(0.152, 0.183))
    p.addCurve(to: pt(0.004, 0.752), control1: pt(0.022, 0.377), control2: pt(-0.013, 0.566))
    p.addCurve(to: pt(0.005, 0.755), control1: pt(0.004, 0.753), control2: pt(0.005, 0.754))
    p.addCurve(to: pt(0.255, 0.881), control1: pt(0.091, 0.818), control2: pt(0.174, 0.856))
    p.addCurve(to: pt(0.259, 0.88), control1: pt(0.256, 0.881), control2: pt(0.258, 0.881))
    p.addCurve(to: pt(0.31, 0.797), control1: pt(0.278, 0.854), control2: pt(0.295, 0.826))
    p.addCurve(to: pt(0.31, 0.794), control1: pt(0.31, 0.796), control2: pt(0.31, 0.795))
    p.addCurve(to: pt(0.308, 0.792), control1: pt(0.31, 0.793), control2: pt(0.309, 0.793))
    p.addCurve(to: pt(0.23, 0.755), control1: pt(0.281, 0.782), control2: pt(0.255, 0.769))
    p.addCurve(to: pt(0.228, 0.753), control1: pt(0.229, 0.755), control2: pt(0.228, 0.754))
    p.addCurve(to: pt(0.23, 0.75), control1: pt(0.228, 0.752), control2: pt(0.229, 0.75))
    p.addCurve(to: pt(0.245, 0.738), control1: pt(0.235, 0.746), control2: pt(0.24, 0.742))
    p.addCurve(to: pt(0.248, 0.737), control1: pt(0.246, 0.737), control2: pt(0.247, 0.737))
    p.addCurve(to: pt(0.751, 0.737), control1: pt(0.412, 0.812), control2: pt(0.589, 0.812))
    p.addCurve(to: pt(0.754, 0.738), control1: pt(0.752, 0.737), control2: pt(0.753, 0.737))
    p.addCurve(to: pt(0.77, 0.75), control1: pt(0.759, 0.742), control2: pt(0.764, 0.746))
    p.addCurve(to: pt(0.771, 0.753), control1: pt(0.771, 0.75), control2: pt(0.771, 0.751))
    p.addCurve(to: pt(0.769, 0.755), control1: pt(0.771, 0.754), control2: pt(0.77, 0.755))
    p.addCurve(to: pt(0.691, 0.792), control1: pt(0.745, 0.77), control2: pt(0.718, 0.782))
    p.addCurve(to: pt(0.69, 0.794), control1: pt(0.691, 0.793), control2: pt(0.69, 0.793))
    p.addCurve(to: pt(0.69, 0.797), control1: pt(0.689, 0.795), control2: pt(0.689, 0.796))
    p.addCurve(to: pt(0.741, 0.88), control1: pt(0.705, 0.826), control2: pt(0.722, 0.854))
    p.addCurve(to: pt(0.744, 0.881), control1: pt(0.742, 0.881), control2: pt(0.743, 0.881))
    p.addCurve(to: pt(0.994, 0.755), control1: pt(0.826, 0.856), control2: pt(0.909, 0.818))
    p.addCurve(to: pt(0.996, 0.752), control1: pt(0.995, 0.754), control2: pt(0.996, 0.753))
    p.addCurve(to: pt(0.848, 0.183), control1: pt(1.017, 0.537), control2: pt(0.961, 0.349))
    p.addCurve(to: pt(0.847, 0.182), control1: pt(0.848, 0.183), control2: pt(0.847, 0.182))
    p.closeSubpath()
    p.move(to: pt(0.334, 0.639))
    p.addCurve(to: pt(0.244, 0.538), control1: pt(0.285, 0.639), control2: pt(0.244, 0.594))
    p.addCurve(to: pt(0.334, 0.437), control1: pt(0.244, 0.482), control2: pt(0.284, 0.437))
    p.addCurve(to: pt(0.424, 0.538), control1: pt(0.385, 0.437), control2: pt(0.425, 0.483))
    p.addCurve(to: pt(0.334, 0.639), control1: pt(0.424, 0.594), control2: pt(0.384, 0.639))
    p.closeSubpath()
    p.move(to: pt(0.666, 0.639))
    p.addCurve(to: pt(0.577, 0.538), control1: pt(0.617, 0.639), control2: pt(0.577, 0.594))
    p.addCurve(to: pt(0.666, 0.437), control1: pt(0.577, 0.482), control2: pt(0.616, 0.437))
    p.addCurve(to: pt(0.756, 0.538), control1: pt(0.717, 0.437), control2: pt(0.757, 0.483))
    p.addCurve(to: pt(0.666, 0.639), control1: pt(0.756, 0.594), control2: pt(0.717, 0.639))
    p.closeSubpath()
    return p
}

struct DiscordLogo: Shape {
    func path(in rect: CGRect) -> Path { discordLogoPath(in: rect) }
}

/// The Muro moon, still: one frame of the welcome's turning moon, for places
/// too small to play the film. The app icon stands in for a build without it.
struct MuroMoonStill: View {
    private static let image: NSImage? = Bundle.main.url(forResource: "WelcomeMoonStill", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Image(nsImage: Self.image ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

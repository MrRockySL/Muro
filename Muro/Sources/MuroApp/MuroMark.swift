import SwiftUI
import AppKit

/// The Muro brand mark — "Moonrise" (owner-approved 2026-07-18).
///
/// One definition drives every surface: the app icon (rendered offline by
/// `Icon/icongen.swift`), the Home top bar, the Settings header, and the menu
/// bar glyph. Geometry is expressed in the Figma artboard's 824-unit square
/// with y pointing DOWN — which is exactly SwiftUI's Canvas convention, so the
/// numbers here are the design file's numbers, unconverted.
enum MoonriseArt {
    static let unit: CGFloat = 824

    static let skyTop     = Color(red: 28/255, green: 42/255, blue: 72/255)
    static let skyMid     = Color(red: 18/255, green: 32/255, blue: 58/255)
    static let skyBottom  = Color(red: 10/255, green: 14/255, blue: 24/255)
    static let glow       = Color(red: 169/255, green: 196/255, blue: 255/255)
    static let moonLit    = Color(red: 244/255, green: 247/255, blue: 255/255)
    static let moonShade  = Color(red: 190/255, green: 208/255, blue: 250/255)
    static let ridgeBack  = Color(red: 6/255, green: 8/255, blue: 14/255)
    static let ridgeFront = Color(red: 12/255, green: 18/255, blue: 34/255)

    static let moonCenter = CGPoint(x: 470, y: 300)
    static let moonRadius: CGFloat = 132
    static let haloRadius: CGFloat = 235

    /// The far ridge — a low, wide swell that sets the horizon.
    static func backRidge() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 545))
        p.addCurve(to: CGPoint(x: 415, y: 500),
                   control1: CGPoint(x: 150, y: 470), control2: CGPoint(x: 260, y: 520))
        p.addCurve(to: CGPoint(x: 824, y: 486),
                   control1: CGPoint(x: 560, y: 483), control2: CGPoint(x: 690, y: 548))
        p.addLine(to: CGPoint(x: 824, y: 824))
        p.addLine(to: CGPoint(x: 0, y: 824))
        p.closeSubpath()
        return p
    }

    /// The near ridge — slightly lighter, which is what reads as depth.
    static func frontRidge() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 662))
        p.addCurve(to: CGPoint(x: 470, y: 632),
                   control1: CGPoint(x: 180, y: 610), control2: CGPoint(x: 330, y: 652))
        p.addCurve(to: CGPoint(x: 824, y: 628),
                   control1: CGPoint(x: 620, y: 612), control2: CGPoint(x: 720, y: 662))
        p.addLine(to: CGPoint(x: 824, y: 824))
        p.addLine(to: CGPoint(x: 0, y: 824))
        p.closeSubpath()
        return p
    }
}

/// The app mark as a rounded tile — Home top bar and Settings header.
struct MuroMark: View {
    var cornerRadius: CGFloat = 8

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / MoonriseArt.unit
            let scale = CGAffineTransform(scaleX: k, y: k)
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }

            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: MoonriseArt.skyTop, location: 0),
                        .init(color: MoonriseArt.skyMid, location: 0.55),
                        .init(color: MoonriseArt.skyBottom, location: 1),
                    ]),
                    startPoint: pt(412, 0), endPoint: pt(412, 824))
            )

            let moon = pt(MoonriseArt.moonCenter.x, MoonriseArt.moonCenter.y)
            let haloR = MoonriseArt.haloRadius * k
            ctx.fill(
                Path(ellipseIn: CGRect(x: moon.x - haloR, y: moon.y - haloR,
                                       width: haloR * 2, height: haloR * 2)),
                with: .radialGradient(
                    Gradient(colors: [MoonriseArt.glow.opacity(0.55),
                                      MoonriseArt.glow.opacity(0)]),
                    center: moon, startRadius: 0, endRadius: haloR)
            )

            // The disc's gradient origin sits up and to the left of the disc
            // itself — that offset is what makes it read as lit, not flat.
            let moonR = MoonriseArt.moonRadius * k
            ctx.fill(
                Path(ellipseIn: CGRect(x: moon.x - moonR, y: moon.y - moonR,
                                       width: moonR * 2, height: moonR * 2)),
                with: .radialGradient(
                    Gradient(colors: [MoonriseArt.moonLit, MoonriseArt.moonShade]),
                    center: pt(430, 268), startRadius: 0, endRadius: 185 * k)
            )

            ctx.fill(MoonriseArt.backRidge().applying(scale),
                     with: .color(MoonriseArt.ridgeBack))
            ctx.fill(MoonriseArt.frontRidge().applying(scale),
                     with: .color(MoonriseArt.ridgeFront.opacity(0.92)))
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// The menu bar glyph: a bare monochrome moon over a curved horizon — the app
/// icon reduced to what survives at 18pt. Drawn through
/// `NSImage(size:flipped:)` so it re-renders per scale factor instead of being
/// an upscaled bitmap, and flagged `isTemplate` so macOS tints it for light
/// and dark menu bars.
enum MuroGlyph {
    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / 18   // designed against an 18pt box, y-up

            c.setFillColor(NSColor.black.cgColor)
            let moon = CGPoint(x: 9 * s, y: 11 * s), r = 3.5 * s
            c.addEllipse(in: CGRect(x: moon.x - r, y: moon.y - r, width: r * 2, height: r * 2))
            c.fillPath()

            // Horizon as a stroke rather than a filled mass: a solid block of
            // ink under the moon reads as a smudge at menu bar size.
            let horizon = CGMutablePath()
            horizon.move(to: CGPoint(x: 1.4 * s, y: 4.5 * s))
            horizon.addCurve(to: CGPoint(x: 9 * s, y: 5.1 * s),
                             control1: CGPoint(x: 4.0 * s, y: 6.3 * s),
                             control2: CGPoint(x: 6.2 * s, y: 4.1 * s))
            horizon.addCurve(to: CGPoint(x: 16.6 * s, y: 4.3 * s),
                             control1: CGPoint(x: 11.8 * s, y: 6.1 * s),
                             control2: CGPoint(x: 14.4 * s, y: 5.9 * s))
            c.addPath(horizon)
            c.setStrokeColor(NSColor.black.cgColor)
            c.setLineWidth(1.7 * s)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

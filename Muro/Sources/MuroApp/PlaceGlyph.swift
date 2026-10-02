import SwiftUI

/// The icon of each place a playlist or an automation plays on: a screen
/// showing a picture for the desktop, a padlock for the lock screen, a moon
/// and a star for the screen saver.
///
/// White, because these sit among the app's own controls: in the Now Playing
/// bar inside the top bar's glass bubble, and in the menu bar beside Open Muro
/// and Settings. The shapes follow the Settings icons, 1.5 point round strokes
/// and a soft fill on an 18 by 18 point grid, and every coordinate matches a
/// node in "6.0 / Now Playing Icon Components" in the Muro App Design file.
/// Drawn rather than bundled, so they stay sharp at any size.
struct PlaceGlyph: View {
    let place: SchedulePlace
    /// The side of the 18 point grid on screen. Strokes scale with it.
    var size: CGFloat = 18

    var body: some View {
        // Read here rather than inside the canvas, so the glyph redraws when
        // the look changes: dark on the light look, white on the others.
        let ink = Color.muroInk
        Canvas { context, _ in
            context.scaleBy(x: size / 18, y: size / 18)
            draw(context, ink: ink)
        }
        .frame(width: size, height: size)
    }

    private func draw(_ context: GraphicsContext, ink: Color) {
        func fill(_ path: Path, soft: Bool = false) {
            context.fill(path, with: .color(ink.opacity(soft ? 0.2 : 1)))
        }
        func stroke(_ path: Path, width: CGFloat = 1.5) {
            context.stroke(path, with: .color(ink),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        switch place {
        case .desktop:
            fill(rect(1.75, 2.5, 14.5, 10.75, 2.5), soft: true)
            let hills = Path { p in
                p.move(to: pt(3.75, 12.5))
                p.addLine(to: pt(6.9, 8.4))
                p.addLine(to: pt(9.1, 10.9))
                p.addLine(to: pt(11.2, 8.9))
                p.addLine(to: pt(14.25, 12.5))
                p.closeSubpath()
            }
            fill(hills)
            stroke(hills, width: 1)
            fill(circle(12.4, 6, 1.2))
            stroke(rect(1.75, 2.5, 14.5, 10.75, 2.5))
            stroke(Path { p in
                p.move(to: pt(9, 13.25))
                p.addLine(to: pt(9, 15.75))
                p.move(to: pt(6.25, 15.75))
                p.addLine(to: pt(11.75, 15.75))
            })
        case .lockScreen:
            stroke(Path { p in
                p.move(to: pt(5.75, 7.75))
                p.addLine(to: pt(5.75, 5.5))
                p.addCurve(to: pt(9, 2.25), control1: pt(5.75, 3.705), control2: pt(7.205, 2.25))
                p.addCurve(to: pt(12.25, 5.5), control1: pt(10.795, 2.25), control2: pt(12.25, 3.705))
                p.addLine(to: pt(12.25, 7.75))
            })
            fill(rect(3.25, 7.75, 11.5, 8, 2.25), soft: true)
            stroke(rect(3.25, 7.75, 11.5, 8, 2.25))
            fill(circle(9, 11.1, 1.2))
            stroke(Path { p in
                p.move(to: pt(9, 11.65))
                p.addLine(to: pt(9, 13.35))
            })
        case .screenSaver:
            // A circle of 6 at (8, 10) with one of 5.25 at (10.75, 7.5) taken
            // out of it, as curves.
            let moon = Path { p in
                p.move(to: pt(6.717, 4.139))
                p.addCurve(to: pt(2.005, 10.241), control1: pt(3.875, 4.761), control2: pt(1.888, 7.333))
                p.addCurve(to: pt(7.191, 15.945), control1: pt(2.121, 13.148), control2: pt(4.308, 15.553))
                p.addCurve(to: pt(13.713, 11.834), control1: pt(10.074, 16.338), control2: pt(12.823, 14.605))
                p.addCurve(to: pt(6.865, 11.032), control1: pt(11.55, 13.313), control2: pt(8.628, 12.97))
                p.addCurve(to: pt(6.717, 4.139), control1: pt(5.103, 9.093), control2: pt(5.04, 6.151))
                p.closeSubpath()
            }
            fill(moon, soft: true)
            stroke(moon)
            let star = Path { p in
                p.move(to: pt(13.75, 2.15))
                p.addQuadCurve(to: pt(15.85, 4.25), control: pt(14.1, 3.9))
                p.addQuadCurve(to: pt(13.75, 6.35), control: pt(14.1, 4.6))
                p.addQuadCurve(to: pt(11.65, 4.25), control: pt(13.4, 4.6))
                p.addQuadCurve(to: pt(13.75, 2.15), control: pt(13.4, 3.9))
                p.closeSubpath()
            }
            fill(star)
            stroke(star, width: 0.6)
            fill(circle(15.6, 8.4, 0.75))
        }
    }
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> Path {
    Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius, style: .circular)
}

import SwiftUI

/// The glyphs on the Apple section's notice card: two people for "added by
/// request", mountains under a sun for the aerials, a circle half light and
/// half dark for the Dynamic Wallpapers, and a bolt beside the note about
/// power. The screen saver tile uses the Now Playing moon (`PlaceGlyph`).
///
/// White, because the card sits inside the app among its own controls. The
/// shapes follow the Settings and Now Playing icons, 1.5 point round strokes
/// and a soft fill on an 18 by 18 point grid, and every coordinate matches a
/// node in "6.0 / Apple Notice Icon Components" in the Muro App Design file.
/// Drawn rather than bundled, so they stay sharp at any size.
struct NoticeGlyph: View {
    enum Kind { case people, aerials, dynamic, power }

    let kind: Kind
    /// The side of the 18 point grid on screen. Strokes scale with it.
    var size: CGFloat = 18

    var body: some View {
        // Read here so the glyph redraws when the look changes.
        let ink = Color.muroInk
        Canvas { context, _ in
            context.scaleBy(x: size / 18, y: size / 18)
            draw(context, ink: ink)
        }
        .frame(width: size, height: size)
    }

    private func draw(_ context: GraphicsContext, ink: Color) {
        func fill(_ path: Path, opacity: Double = 1) {
            context.fill(path, with: .color(ink.opacity(opacity)))
        }
        func stroke(_ path: Path, opacity: Double = 1) {
            context.stroke(path, with: .color(ink.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        switch kind {
        case .people:
            // The one behind is fainter, so the pair reads as one in front.
            stroke(circle(13.25, 5.1, 1.9), opacity: 0.65)
            stroke(Path { p in
                p.move(to: pt(14.05, 9.5))
                p.addCurve(to: pt(16.4, 13.2), control1: pt(15.5, 9.9), control2: pt(16.4, 11.2))
            }, opacity: 0.65)
            let shoulders = Path { p in
                p.move(to: pt(1.6, 15.25))
                p.addCurve(to: pt(6.6, 10.35), control1: pt(1.6, 12.35), control2: pt(3.95, 10.35))
                p.addCurve(to: pt(11.6, 15.25), control1: pt(9.25, 10.35), control2: pt(11.6, 12.35))
            }
            fill(Path { p in
                p.addPath(shoulders)
                p.closeSubpath()
            }, opacity: 0.2)
            stroke(shoulders)
            fill(circle(6.6, 5.85, 2.55), opacity: 0.2)
            stroke(circle(6.6, 5.85, 2.55))
        case .aerials:
            let mountains = Path { p in
                p.move(to: pt(1.75, 14.75))
                p.addLine(to: pt(6.6, 7.6))
                p.addLine(to: pt(9.7, 11.85))
                p.addLine(to: pt(11.8, 9.05))
                p.addLine(to: pt(16.25, 14.75))
                p.closeSubpath()
            }
            fill(mountains, opacity: 0.2)
            stroke(mountains)
            fill(circle(12.9, 4.35, 1.65))
        case .dynamic:
            // Each half of the circle as two curves; 3.728 is the radius,
            // 6.75, times the usual 0.5523 for a quarter circle.
            fill(Path { p in
                p.move(to: pt(9, 2.25))
                p.addCurve(to: pt(2.25, 9), control1: pt(5.272, 2.25), control2: pt(2.25, 5.272))
                p.addCurve(to: pt(9, 15.75), control1: pt(2.25, 12.728), control2: pt(5.272, 15.75))
                p.closeSubpath()
            }, opacity: 0.2)
            fill(Path { p in
                p.move(to: pt(9, 2.25))
                p.addCurve(to: pt(15.75, 9), control1: pt(12.728, 2.25), control2: pt(15.75, 5.272))
                p.addCurve(to: pt(9, 15.75), control1: pt(15.75, 12.728), control2: pt(12.728, 15.75))
                p.closeSubpath()
            })
            stroke(circle(9, 9, 6.75))
        case .power:
            let bolt = Path { p in
                p.move(to: pt(10.3, 1.75))
                p.addLine(to: pt(4.1, 10.15))
                p.addLine(to: pt(8.75, 10.15))
                p.addLine(to: pt(7.7, 16.25))
                p.addLine(to: pt(13.9, 7.85))
                p.addLine(to: pt(9.25, 7.85))
                p.closeSubpath()
            }
            fill(bolt, opacity: 0.2)
            stroke(bolt)
        }
    }
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
}

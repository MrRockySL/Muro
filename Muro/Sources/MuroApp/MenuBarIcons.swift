import SwiftUI
import AppKit

/// The icon Muro shows in the menu bar, chosen in Settings, General (6.0).
///
/// The owner picked five beside the default on 2026-10-04, from ten drawn in
/// Figma ("6.0 / Menu Bar Icons · Choices" in the Muro App Design file). Every
/// one is drawn in the default glyph's own 18 point box, with its 1.7 point
/// line and its moon, so they read as one set. Lines are turned into outlines
/// and merged into a single path, the same silhouette as the Figma
/// components, then filled as a template image that macOS tints for light and
/// dark menu bars.
///
/// The default is not redrawn here: it stays `MuroGlyph.menuBarImage()`, so a
/// Mac that never opens this setting shows exactly what it always has.
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case standard = "default"
    case outline
    case glassMoon = "glass-moon"
    case planet
    case peaks
    case display

    static let defaultsKey = "menuBarIcon"

    static var current: MenuBarIconStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MenuBarIconStyle.init(rawValue:)) ?? .standard
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Default"
        case .outline: return "Outline"
        case .glassMoon: return "Glass Moon"
        case .planet: return "Planet"
        case .peaks: return "Peaks"
        case .display: return "Display"
        }
    }

    /// The template image for the status item, the Settings row and its menu.
    /// Drawn through a handler, like the default, so it re-renders at every
    /// scale instead of being an upscaled bitmap.
    func menuBarImage(size: CGFloat = 18) -> NSImage {
        guard let shape = outline else { return MuroGlyph.menuBarImage(size: size) }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width / 18   // drawn against an 18 pt box, y down
            c.scaleBy(x: s, y: s)
            c.addPath(shape)
            c.setFillColor(NSColor.black.cgColor)
            c.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The glyph as one filled outline in an 18 pt box, y pointing down (the
    /// Figma convention, so the numbers are the design's). Nil for the default.
    private var outline: CGPath? {
        switch self {
        case .standard:
            return nil
        case .outline:
            // The default with a hollow moon.
            return union([stroked(ellipse(9, 7, 2.75)), stroked(Self.horizon)])
        case .glassMoon:
            // The 6.0 app icon as a line: a ribbon from the lower left, under
            // the moon, up its right side and over the top.
            let swirl = CGMutablePath()
            swirl.move(to: pt(1.3, 12.7))
            swirl.addCurve(to: pt(12.0, 14.0), control1: pt(3.8, 14.7), control2: pt(8.3, 15.4))
            swirl.addCurve(to: pt(15.6, 7.0), control1: pt(15.0, 12.9), control2: pt(16.4, 9.8))
            swirl.addCurve(to: pt(9.4, 2.5), control1: pt(14.8, 4.2), control2: pt(12.2, 2.4))
            swirl.addCurve(to: pt(5.0, 4.9), control1: pt(7.4, 2.6), control2: pt(5.8, 3.5))
            return union([ellipse(9.8, 8.4, 3.1), stroked(swirl)])
        case .planet:
            // A ringed planet. The ring is a true ellipse turned 0.38 rad; its
            // far half is hidden by the planet, its near half crosses in front
            // with a gap cut into the planet around it.
            let t = CGAffineTransform(translationX: 9, y: 9).rotated(by: -0.38).scaledBy(x: 8.1, y: 2.5)
            let ring = CGMutablePath()
            ring.addEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2), transform: t)
            let near = CGMutablePath()
            near.addArc(center: .zero, radius: 1, startAngle: 0, endAngle: .pi, clockwise: false, transform: t)
            let planet = ellipse(9, 9, 4.0)
            let behind = stroked(ring, 1.4).subtracting(planet)
            let gap = stroked(near, 1.4 + 2 * 0.85)
            return union([planet.subtracting(gap), behind, stroked(near, 1.4)])
        case .peaks:
            // The moon over two mountains.
            let ridge = CGMutablePath()
            ridge.addLines(between: [pt(1.5, 14.3), pt(6.4, 7.3), pt(9.5, 11.4), pt(11.9, 8.7), pt(16.5, 14.3)])
            return union([stroked(ridge), ellipse(13.7, 4.0, 2.1)])
        case .display:
            // A small screen with the moon and a hill on it. Its straight
            // edges sit on half points, so they stay sharp at 2x.
            let screen = CGPath(roundedRect: CGRect(x: 1.75, y: 2.25, width: 14.5, height: 10.5),
                                cornerWidth: 2.25, cornerHeight: 2.25, transform: nil)
            let hill = CGMutablePath()
            hill.move(to: pt(0, 10.2))
            hill.addCurve(to: pt(18, 9.0), control1: pt(5.5, 8.2), control2: pt(10.5, 11.0))
            hill.addLine(to: pt(18, 18))
            hill.addLine(to: pt(0, 18))
            hill.closeSubpath()
            let foot = CGMutablePath()
            foot.move(to: pt(6.25, 15.25))
            foot.addLine(to: pt(11.75, 15.25))
            return union([stroked(screen, 1.5),
                          screen.intersection(hill),
                          ellipse(12.0, 5.9, 1.55),
                          CGPath(rect: CGRect(x: 8.0, y: 12.75, width: 2.0, height: 2.5), transform: nil),
                          stroked(foot, 1.5)])
        }
    }

    /// The default glyph's horizon, its numbers flipped to y down.
    private static let horizon: CGPath = {
        let p = CGMutablePath()
        p.move(to: pt(1.4, 13.5))
        p.addCurve(to: pt(9, 12.9), control1: pt(4.0, 11.7), control2: pt(6.2, 13.9))
        p.addCurve(to: pt(16.6, 13.7), control1: pt(11.8, 11.9), control2: pt(14.4, 12.1))
        return p
    }()
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func ellipse(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil)
}

/// The default glyph's line: 1.7 pt, round ends and joins.
private func stroked(_ path: CGPath, _ width: CGFloat = 1.7) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

private func union(_ paths: [CGPath]) -> CGPath {
    paths.dropFirst().reduce(paths[0]) { $0.union($1) }
}

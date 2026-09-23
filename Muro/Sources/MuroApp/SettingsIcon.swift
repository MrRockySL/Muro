import SwiftUI

/// The icons in Settings, one for each row.
///
/// Each is a 30 point tile of dark glass in the row's own colour, carrying an
/// 18 point glyph: 1.5 point round strokes and a soft fill, both in the tile's
/// colour mixed halfway to white. They replace SF Symbols in plain tinted
/// squares, which read as system chrome rather than as Muro.
///
/// The geometry is the approved Figma set, "6.0 / Icon Components" in the Muro
/// App Design file, on the same 18 by 18 point grid, so every coordinate here
/// matches a node there. The glyphs are drawn rather than loaded as images, so
/// they stay sharp at any scale and nothing has to be bundled.
///
/// Download Folder came later, on 2026-09-23: drawn here on the same grid and
/// rules, and approved from a render beside the others rather than in Figma.
///
/// Replay on Clear Desktop has no tile. It belongs to the row above it, and a
/// dependent setting keeps an arrow where its icon would be.
enum SettingsIcon {
    case launchAtLogin, menuBar, dockIcon, playbackSpeed, defaultQuality, pauseAfter
    case replay, screenSaver, lowPower, lowBattery, covered, desktopOnly
    case builtInDisplay, externalDisplay, storage, downloadFolder, softwareUpdate, support

    /// The tile's colour. Nil for the replay arrow, which has no tile.
    var tint: Color? {
        switch self {
        case .launchAtLogin: return Color(hex: 0x5B8CFF)
        case .menuBar: return Color(hex: 0x9B7BFF)
        case .dockIcon: return Color(hex: 0xFF6FAE)
        case .playbackSpeed: return Color(hex: 0xFF9A4D)
        case .defaultQuality: return Color(hex: 0x38D6A5)
        case .pauseAfter: return Color(hex: 0x7B7FFF)
        case .replay: return nil
        case .screenSaver: return Color(hex: 0x3CC4F0)
        case .lowPower: return Color(hex: 0xA3D94A)
        case .lowBattery: return Color(hex: 0xFF6464)
        case .covered: return Color(hex: 0x2EC4B6)
        case .desktopOnly: return Color(hex: 0x4D9DFF)
        case .builtInDisplay: return Color(hex: 0x3CC4F0)
        case .externalDisplay: return Color(hex: 0x3CC4F0)
        case .storage: return Color(hex: 0x9AA4B2)
        case .downloadFolder: return Color(hex: 0xFFB23F)
        case .softwareUpdate: return Color(hex: 0x45D483)
        case .support: return Color(hex: 0xFF6B8E)
        }
    }

    /// The glyph's colour: the tint mixed halfway to white.
    var glyphColor: Color {
        switch self {
        case .launchAtLogin: return Color(hex: 0xADC6FF)
        case .menuBar: return Color(hex: 0xCDBDFF)
        case .dockIcon: return Color(hex: 0xFFB7D6)
        case .playbackSpeed: return Color(hex: 0xFFCCA6)
        case .defaultQuality: return Color(hex: 0x9CEAD2)
        case .pauseAfter: return Color(hex: 0xBDBFFF)
        case .replay: return .muroSecondary
        case .screenSaver: return Color(hex: 0x9EE2F8)
        case .lowPower: return Color(hex: 0xD1ECA4)
        case .lowBattery: return Color(hex: 0xFFB2B2)
        case .covered: return Color(hex: 0x96E2DA)
        case .desktopOnly: return Color(hex: 0xA6CEFF)
        case .builtInDisplay: return Color(hex: 0x9EE2F8)
        case .externalDisplay: return Color(hex: 0x9EE2F8)
        case .storage: return Color(hex: 0xCCD2D8)
        case .downloadFolder: return Color(hex: 0xFFD89F)
        case .softwareUpdate: return Color(hex: 0xA2EAC1)
        case .support: return Color(hex: 0xFFB5C6)
        }
    }

    /// How strong the soft fill inside a glyph is. The heart is filled more,
    /// so it still reads as a heart at this size.
    var softFillOpacity: Double { self == .support ? 0.4 : 0.28 }

    fileprivate func draw(_ context: GraphicsContext) {
        let color = glyphColor
        func fill(_ path: Path, soft: Bool = false) {
            context.fill(path, with: .color(soft ? color.opacity(softFillOpacity) : color))
        }
        func stroke(_ path: Path, width: CGFloat = 1.5, opacity: Double = 1) {
            context.stroke(path, with: .color(color.opacity(opacity)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        switch self {
        case .launchAtLogin:
            fill(circle(9, 10, 6.5), soft: true)
            stroke(Path { p in
                p.move(to: pt(4.82, 5.02))
                p.addCurve(to: pt(2.892, 12.222), control1: pt(2.728, 6.777), control2: pt(1.957, 9.655))
                p.addCurve(to: pt(9, 16.498), control1: pt(3.827, 14.789), control2: pt(6.268, 16.498))
                p.addCurve(to: pt(15.108, 12.222), control1: pt(11.732, 16.498), control2: pt(14.173, 14.789))
                p.addCurve(to: pt(13.18, 5.02), control1: pt(16.043, 9.655), control2: pt(15.272, 6.777))
            })
            stroke(Path { p in
                p.move(to: pt(9, 2))
                p.addLine(to: pt(9, 8.75))
            })
        case .menuBar:
            fill(Path { p in
                p.move(to: pt(1.75, 5.75))
                p.addCurve(to: pt(4.5, 3), control1: pt(1.75, 4.231), control2: pt(2.981, 3))
                p.addLine(to: pt(13.5, 3))
                p.addCurve(to: pt(16.25, 5.75), control1: pt(15.019, 3), control2: pt(16.25, 4.231))
                p.addLine(to: pt(16.25, 7))
                p.addLine(to: pt(1.75, 7))
                p.closeSubpath()
            }, soft: true)
            stroke(rect(1.75, 3, 14.5, 12, 2.75))
            stroke(Path { p in
                p.move(to: pt(1.75, 7))
                p.addLine(to: pt(16.25, 7))
            })
            fill(circle(11.9, 5.05, 0.8))
            fill(circle(14.05, 5.05, 0.8))
        case .dockIcon:
            fill(rect(1.75, 3, 14.5, 12, 2.75), soft: true)
            stroke(rect(1.75, 3, 14.5, 12, 2.75))
            fill(rect(4.75, 10.5, 8.5, 2.5, 1.25))
        case .playbackSpeed:
            fill(Path { p in
                p.move(to: pt(9, 10.75))
                p.addLine(to: pt(3.15, 14.13))
                p.addCurve(to: pt(4.663, 5.59), control1: pt(1.517, 11.293), control2: pt(2.155, 7.693))
                p.addCurve(to: pt(13.337, 5.59), control1: pt(7.172, 3.487), control2: pt(10.828, 3.487))
                p.addCurve(to: pt(14.85, 14.13), control1: pt(15.845, 7.693), control2: pt(16.483, 11.293))
                p.closeSubpath()
            }, soft: true)
            stroke(Path { p in
                p.move(to: pt(3.15, 14.13))
                p.addCurve(to: pt(4.663, 5.59), control1: pt(1.517, 11.293), control2: pt(2.155, 7.693))
                p.addCurve(to: pt(13.337, 5.59), control1: pt(7.172, 3.487), control2: pt(10.828, 3.487))
                p.addCurve(to: pt(14.85, 14.13), control1: pt(15.845, 7.693), control2: pt(16.483, 11.293))
            })
            stroke(Path { p in
                p.move(to: pt(9, 10.75))
                p.addLine(to: pt(12.25, 7.25))
            })
            fill(circle(9, 10.75, 1.35))
        case .defaultQuality:
            fill(Path { p in
                p.move(to: pt(5, 3))
                p.addLine(to: pt(13, 3))
                p.addLine(to: pt(16.25, 7.25))
                p.addLine(to: pt(1.75, 7.25))
                p.closeSubpath()
            }, soft: true)
            stroke(Path { p in
                p.move(to: pt(5, 3))
                p.addLine(to: pt(13, 3))
                p.addLine(to: pt(16.25, 7.25))
                p.addLine(to: pt(9, 15.5))
                p.addLine(to: pt(1.75, 7.25))
                p.closeSubpath()
            })
            stroke(Path { p in
                p.move(to: pt(1.75, 7.25))
                p.addLine(to: pt(16.25, 7.25))
                p.move(to: pt(6.9, 3))
                p.addLine(to: pt(5.75, 7.25))
                p.addLine(to: pt(9, 15.5))
                p.addLine(to: pt(12.25, 7.25))
                p.addLine(to: pt(11.1, 3))
            }, width: 1.25)
        case .pauseAfter:
            fill(circle(9, 10.25, 6.5), soft: true)
            stroke(circle(9, 10.25, 6.5))
            stroke(Path { p in
                p.move(to: pt(7, 1.75))
                p.addLine(to: pt(11, 1.75))
                p.move(to: pt(9, 1.75))
                p.addLine(to: pt(9, 3.75))
                p.move(to: pt(14.1, 4.65))
                p.addLine(to: pt(15.25, 3.5))
            })
            stroke(Path { p in
                p.move(to: pt(7.25, 8))
                p.addLine(to: pt(7.25, 12.5))
                p.move(to: pt(10.75, 8))
                p.addLine(to: pt(10.75, 12.5))
            })
        case .replay:
            stroke(Path { p in
                p.move(to: pt(5, 3.5))
                p.addLine(to: pt(5, 8.25))
                p.addCurve(to: pt(8.25, 11.5), control1: pt(5, 10.045), control2: pt(6.455, 11.5))
                p.addLine(to: pt(14.25, 11.5))
            })
            stroke(Path { p in
                p.move(to: pt(11.25, 8.5))
                p.addLine(to: pt(14.25, 11.5))
                p.addLine(to: pt(11.25, 14.5))
            })
        case .screenSaver:
            fill(Path { p in
                p.move(to: pt(4.5, 10.25))
                p.addCurve(to: pt(9, 5.75), control1: pt(4.5, 7.765), control2: pt(6.515, 5.75))
                p.addCurve(to: pt(13.5, 10.25), control1: pt(11.485, 5.75), control2: pt(13.5, 7.765))
                p.closeSubpath()
            }, soft: true)
            stroke(rect(1.75, 2.5, 14.5, 10.75, 2.5))
            stroke(Path { p in
                p.move(to: pt(9, 13.25))
                p.addLine(to: pt(9, 15.75))
                p.move(to: pt(6.25, 15.75))
                p.addLine(to: pt(11.75, 15.75))
            })
            fill(Path { p in
                p.move(to: pt(6.25, 10.25))
                p.addCurve(to: pt(9, 7.5), control1: pt(6.25, 8.731), control2: pt(7.481, 7.5))
                p.addCurve(to: pt(11.75, 10.25), control1: pt(10.519, 7.5), control2: pt(11.75, 8.731))
                p.closeSubpath()
            })
            stroke(Path { p in
                p.move(to: pt(4.25, 10.25))
                p.addLine(to: pt(13.75, 10.25))
            }, width: 1.25)
            fill(circle(5, 5.5, 0.7))
            fill(circle(13, 5.25, 0.55))
        case .lowPower:
            fill(Path { p in
                p.move(to: pt(3.25, 14.75))
                p.addCurve(to: pt(14.75, 3.25), control1: pt(3.25, 7.75), control2: pt(7.75, 3.25))
                p.addCurve(to: pt(3.25, 14.75), control1: pt(14.75, 10.25), control2: pt(10.25, 14.75))
                p.closeSubpath()
            }, soft: true)
            stroke(Path { p in
                p.move(to: pt(3.25, 14.75))
                p.addCurve(to: pt(14.75, 3.25), control1: pt(3.25, 7.75), control2: pt(7.75, 3.25))
                p.addCurve(to: pt(3.25, 14.75), control1: pt(14.75, 10.25), control2: pt(10.25, 14.75))
                p.closeSubpath()
            })
            stroke(Path { p in
                p.move(to: pt(3.25, 14.75))
                p.addLine(to: pt(10, 8))
            })
        case .lowBattery:
            fill(rect(1.75, 5.25, 12.75, 7.5, 2.25), soft: true)
            stroke(rect(1.75, 5.25, 12.75, 7.5, 2.25))
            stroke(Path { p in
                p.move(to: pt(16.5, 7.75))
                p.addLine(to: pt(16.5, 10.25))
            })
            fill(rect(3.5, 7, 2.5, 4, 0.9))
        case .covered:
            stroke(Path { p in
                p.move(to: pt(5.25, 11.25))
                p.addLine(to: pt(3.75, 11.25))
                p.addCurve(to: pt(1.75, 9.25), control1: pt(2.645, 11.25), control2: pt(1.75, 10.355))
                p.addLine(to: pt(1.75, 4.25))
                p.addCurve(to: pt(3.75, 2.25), control1: pt(1.75, 3.145), control2: pt(2.645, 2.25))
                p.addLine(to: pt(10.75, 2.25))
                p.addCurve(to: pt(12.75, 4.25), control1: pt(11.855, 2.25), control2: pt(12.75, 3.145))
                p.addLine(to: pt(12.75, 6.25))
            }, opacity: 0.55)
            fill(rect(5.25, 6.25, 11, 9.5, 2), soft: true)
            stroke(rect(5.25, 6.25, 11, 9.5, 2))
            stroke(Path { p in
                p.move(to: pt(5.25, 8.9))
                p.addLine(to: pt(16.25, 8.9))
            }, width: 1.25)
        case .desktopOnly:
            fill(rect(1.75, 2.5, 14.5, 10.75, 2.5), soft: true)
            stroke(rect(1.75, 2.5, 14.5, 10.75, 2.5))
            stroke(Path { p in
                p.move(to: pt(9, 13.25))
                p.addLine(to: pt(9, 15.75))
                p.move(to: pt(6.25, 15.75))
                p.addLine(to: pt(11.75, 15.75))
            })
            let shape1 = Path { p in
                p.move(to: pt(7.6, 5.65))
                p.addLine(to: pt(7.6, 10.1))
                p.addLine(to: pt(11.35, 7.875))
                p.closeSubpath()
            }
            fill(shape1)
            stroke(shape1, width: 1)
        case .builtInDisplay:
            fill(rect(3, 3.25, 12, 8.75, 1.75), soft: true)
            stroke(rect(3, 3.25, 12, 8.75, 1.75))
            stroke(Path { p in
                p.move(to: pt(1.25, 14.5))
                p.addLine(to: pt(16.75, 14.5))
            })
        case .externalDisplay:
            fill(rect(1.75, 2.75, 14.5, 10, 2.25), soft: true)
            stroke(rect(1.75, 2.75, 14.5, 10, 2.25))
            stroke(Path { p in
                p.move(to: pt(9, 12.75))
                p.addLine(to: pt(9, 15.5))
                p.move(to: pt(6, 15.5))
                p.addLine(to: pt(12, 15.5))
            })
        case .storage:
            fill(rect(1.75, 9.5, 14.5, 5.75, 2), soft: true)
            stroke(Path { p in
                p.move(to: pt(3.25, 9.5))
                p.addLine(to: pt(5.25, 3.25))
                p.addLine(to: pt(12.75, 3.25))
                p.addLine(to: pt(14.75, 9.5))
            })
            stroke(rect(1.75, 9.5, 14.5, 5.75, 2))
            stroke(Path { p in
                p.move(to: pt(4.5, 12.375))
                p.addLine(to: pt(8.5, 12.375))
            })
            fill(circle(12.75, 12.375, 0.85))
        case .downloadFolder:
            let folder = Path { p in
                p.move(to: pt(1.75, 13.25))
                p.addLine(to: pt(1.75, 4.75))
                p.addQuadCurve(to: pt(3.75, 2.75), control: pt(1.75, 2.75))
                p.addLine(to: pt(6.55, 2.75))
                p.addQuadCurve(to: pt(7.75, 3.35), control: pt(7.3, 2.75))
                p.addLine(to: pt(8.55, 4.45))
                p.addQuadCurve(to: pt(9.75, 5.05), control: pt(9, 5.05))
                p.addLine(to: pt(14.25, 5.05))
                p.addQuadCurve(to: pt(16.25, 7.05), control: pt(16.25, 5.05))
                p.addLine(to: pt(16.25, 13.25))
                p.addQuadCurve(to: pt(14.25, 15.25), control: pt(16.25, 15.25))
                p.addLine(to: pt(3.75, 15.25))
                p.addQuadCurve(to: pt(1.75, 13.25), control: pt(1.75, 15.25))
                p.closeSubpath()
            }
            fill(folder, soft: true)
            stroke(folder)
            stroke(Path { p in
                p.move(to: pt(9, 7.75))
                p.addLine(to: pt(9, 12.5))
                p.move(to: pt(6.9, 10.4))
                p.addLine(to: pt(9, 12.5))
                p.addLine(to: pt(11.1, 10.4))
            })
        case .softwareUpdate:
            fill(circle(9, 9, 7), soft: true)
            stroke(circle(9, 9, 7))
            stroke(Path { p in
                p.move(to: pt(9, 5.25))
                p.addLine(to: pt(9, 12.25))
                p.move(to: pt(6.25, 9.5))
                p.addLine(to: pt(9, 12.25))
                p.addLine(to: pt(11.75, 9.5))
            })
        case .support:
            fill(Path { p in
                p.move(to: pt(9, 15.4))
                p.addCurve(to: pt(2, 6.55), control1: pt(9, 15.4), control2: pt(2, 11.4))
                p.addCurve(to: pt(5.95, 2.6), control1: pt(2, 4.35), control2: pt(3.75, 2.6))
                p.addCurve(to: pt(9, 4.35), control1: pt(7.3, 2.6), control2: pt(8.4, 3.3))
                p.addCurve(to: pt(12.05, 2.6), control1: pt(9.6, 3.3), control2: pt(10.7, 2.6))
                p.addCurve(to: pt(16, 6.55), control1: pt(14.25, 2.6), control2: pt(16, 4.35))
                p.addCurve(to: pt(9, 15.4), control1: pt(16, 11.4), control2: pt(9, 15.4))
                p.closeSubpath()
            }, soft: true)
            stroke(Path { p in
                p.move(to: pt(9, 15.4))
                p.addCurve(to: pt(2, 6.55), control1: pt(9, 15.4), control2: pt(2, 11.4))
                p.addCurve(to: pt(5.95, 2.6), control1: pt(2, 4.35), control2: pt(3.75, 2.6))
                p.addCurve(to: pt(9, 4.35), control1: pt(7.3, 2.6), control2: pt(8.4, 3.3))
                p.addCurve(to: pt(12.05, 2.6), control1: pt(9.6, 3.3), control2: pt(10.7, 2.6))
                p.addCurve(to: pt(16, 6.55), control1: pt(14.25, 2.6), control2: pt(16, 4.35))
                p.addCurve(to: pt(9, 15.4), control1: pt(16, 11.4), control2: pt(9, 15.4))
                p.closeSubpath()
            })
            stroke(Path { p in
                p.move(to: pt(4.9, 6.2))
                p.addCurve(to: pt(6.35, 4.75), control1: pt(5, 5.35), control2: pt(5.55, 4.85))
            }, width: 1.1, opacity: 0.8)
        }
    }
}

struct SettingsIconView: View {
    let icon: SettingsIcon

    var body: some View {
        ZStack {
            if let tint = icon.tint {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: 0x0C0F16))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.46), tint.opacity(0.16)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            Canvas { context, _ in icon.draw(context) }
                .frame(width: 18, height: 18)
        }
        .frame(width: 30, height: 30)
    }
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> Path {
    Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius, style: .circular)
}

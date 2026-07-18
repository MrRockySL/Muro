import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// ---- helpers ---------------------------------------------------------------

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

func ctx(_ size: Int) -> CGContext {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setAllowsAntialiasing(true)
    c.interpolationQuality = .high
    return c
}

func writePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// Apple-style continuous-corner squircle (superellipse), n≈5.
func squircle(_ rect: CGRect, n: CGFloat = 5.0, steps: Int = 1440) -> CGPath {
    let p = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width/2, b = rect.height/2
    for i in 0...steps {
        let t = CGFloat(i)/CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2/n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2/n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

// Four-point sparkle (the ✦ brand mark), centered at c, tip radius R,
// pinch controls how concave the sides are (smaller = sharper points).
func sparkle(center c: CGPoint, radius R: CGFloat, pinch: CGFloat = 0.14) -> CGPath {
    let k = R * pinch
    let p = CGMutablePath()
    let top = CGPoint(x: c.x, y: c.y + R)
    let right = CGPoint(x: c.x + R, y: c.y)
    let bottom = CGPoint(x: c.x, y: c.y - R)
    let left = CGPoint(x: c.x - R, y: c.y)
    p.move(to: top)
    p.addQuadCurve(to: right, control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: bottom, control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: left, control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: top, control: CGPoint(x: c.x - k, y: c.y + k))
    p.closeSubpath()
    return p
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray, locations: locations)!
}

// The icon-art region: Apple leaves ~10% padding around the squircle body.
func bodyRect(_ S: CGFloat) -> CGRect {
    let inset = S * 0.098
    return CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
}

func cornerRadius(_ body: CGRect) -> CGFloat { body.width * 0.2237 }

// Subtle top inner highlight along the squircle's upper edge (glass sheen).
func topSheen(_ c: CGContext, _ body: CGRect) {
    c.saveGState()
    c.addPath(squircle(body))
    c.clip()
    let g = linearGradient(
        [rgb(255,255,255,0.10), rgb(255,255,255,0.0)],
        [0, 0.28])
    c.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.maxY),
                         end: CGPoint(x: body.midX, y: body.minY), options: [])
    c.restoreGState()
}

// Thin bright rim on the squircle edge — reads as beveled glass.
func rim(_ c: CGContext, _ body: CGRect) {
    c.saveGState()
    c.addPath(squircle(body))
    c.setStrokeColor(rgb(255,255,255,0.14))
    c.setLineWidth(body.width * 0.006)
    c.strokePath()
    c.restoreGState()
}

// ---- SHIPPING ICON — "Moonrise" -------------------------------------------
// Owner-approved 2026-07-18 (Figma VJfewS69etqChwyZB5Ko6a, "Concept 1 —
// Moonrise"). Reproduced natively rather than exported as a flat PNG so every
// iconset size is rendered from vectors — the ridges and halo stay crisp at
// 16pt, and the same geometry drives the in-app mark (MuroMark.swift).
// Geometry/colors below are the Figma artboard values verbatim: an 824-unit
// square, y-DOWN, which figmaTransform maps into the icon body rect.

func figmaTransform(_ body: CGRect) -> CGAffineTransform {
    let k = body.width / 824
    return CGAffineTransform(translationX: body.minX, y: body.minY + body.height)
        .scaledBy(x: k, y: -k)
}

func moonrise(_ S: CGFloat) -> CGImage {
    let c = ctx(Int(S))
    let body = bodyRect(S)
    let t = figmaTransform(body)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(t) }

    c.saveGState()
    c.addPath(squircle(body)); c.clip()

    // night sky
    let sky = linearGradient([rgb(28,42,72), rgb(18,32,58), rgb(10,14,24)], [0, 0.55, 1])
    c.drawLinearGradient(sky, start: p(412, 0), end: p(412, 824), options: [])

    // moon halo — soft bloom behind the disc
    let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(169,196,255,0.55), rgb(169,196,255,0)] as CFArray,
        locations: [0, 1])!
    c.drawRadialGradient(halo, startCenter: p(470, 300), startRadius: 0,
                         endCenter: p(470, 300), endRadius: 235 * body.width/824,
                         options: [])

    // moon disc — lit from the upper-left, so the gradient origin is offset
    c.saveGState()
    let mr = 132 * body.width/824
    let moon = p(470, 300)
    c.addEllipse(in: CGRect(x: moon.x - mr, y: moon.y - mr, width: 2*mr, height: 2*mr))
    c.clip()
    let disc = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(244,247,255), rgb(190,208,250)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(disc, startCenter: p(430, 268), startRadius: 0,
                         endCenter: p(430, 268), endRadius: 185 * body.width/824,
                         options: [.drawsAfterEndLocation])
    c.restoreGState()

    // two ridges, back then front — the depth cue that makes it a landscape
    let back = CGMutablePath()
    back.move(to: CGPoint(x: 0, y: 545))
    back.addCurve(to: CGPoint(x: 415, y: 500),
                  control1: CGPoint(x: 150, y: 470), control2: CGPoint(x: 260, y: 520))
    back.addCurve(to: CGPoint(x: 824, y: 486),
                  control1: CGPoint(x: 560, y: 483), control2: CGPoint(x: 690, y: 548))
    back.addLine(to: CGPoint(x: 824, y: 824))
    back.addLine(to: CGPoint(x: 0, y: 824))
    back.closeSubpath()
    var tf = t
    c.addPath(back.copy(using: &tf)!)
    c.setFillColor(rgb(6, 8, 14)); c.fillPath()

    let front = CGMutablePath()
    front.move(to: CGPoint(x: 0, y: 662))
    front.addCurve(to: CGPoint(x: 470, y: 632),
                   control1: CGPoint(x: 180, y: 610), control2: CGPoint(x: 330, y: 652))
    front.addCurve(to: CGPoint(x: 824, y: 628),
                   control1: CGPoint(x: 620, y: 612), control2: CGPoint(x: 720, y: 662))
    front.addLine(to: CGPoint(x: 824, y: 824))
    front.addLine(to: CGPoint(x: 0, y: 824))
    front.closeSubpath()
    c.addPath(front.copy(using: &tf)!)
    c.setFillColor(rgb(12, 18, 34, 0.92)); c.fillPath()

    c.restoreGState()
    rim(c, body)
    return c.makeImage()!
}

// ---- Concept A — "Moonbeam": the ✦ mark, refined -------------------------

func conceptA(_ S: CGFloat) -> CGImage {
    let c = ctx(Int(S))
    let body = bodyRect(S)
    c.saveGState()
    c.addPath(squircle(body)); c.clip()
    // deep midnight radial glow, brighter just above center
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(26,38,66), rgb(13,19,34), rgb(6,9,16)] as CFArray,
        locations: [0, 0.55, 1])!
    c.drawRadialGradient(g,
        startCenter: CGPoint(x: body.midX, y: body.midY + body.height*0.10), startRadius: 0,
        endCenter: CGPoint(x: body.midX, y: body.midY + body.height*0.10), endRadius: body.width*0.72,
        options: [.drawsAfterEndLocation])
    c.restoreGState()

    let star = CGPoint(x: body.midX, y: body.midY - body.height*0.02)
    let R = body.width * 0.30

    // soft outer glow
    c.saveGState()
    c.setShadow(offset: .zero, blur: S*0.06, color: rgb(169,196,255,0.55))
    c.addPath(sparkle(center: star, radius: R))
    c.setFillColor(rgb(169,196,255,1))
    c.fillPath()
    c.restoreGState()

    // main sparkle with vertical white→moonbeam gradient
    c.saveGState()
    c.addPath(sparkle(center: star, radius: R)); c.clip()
    let sg = linearGradient([rgb(255,255,255), rgb(196,214,255), rgb(150,180,250)], [0, 0.5, 1])
    c.drawLinearGradient(sg, start: CGPoint(x: star.x, y: star.y + R),
                         end: CGPoint(x: star.x, y: star.y - R), options: [])
    c.restoreGState()

    // small accent sparkle upper-right
    let s2 = CGPoint(x: body.midX + body.width*0.235, y: body.midY + body.height*0.235)
    c.saveGState()
    c.setShadow(offset: .zero, blur: S*0.03, color: rgb(169,196,255,0.6))
    c.addPath(sparkle(center: s2, radius: body.width*0.075))
    c.setFillColor(rgb(224,234,255,1)); c.fillPath()
    c.restoreGState()

    topSheen(c, body); rim(c, body)
    return c.makeImage()!
}

// ---- Concept B — "Nightfall": moon over misty ridges ----------------------

func conceptB(_ S: CGFloat) -> CGImage {
    let c = ctx(Int(S))
    let body = bodyRect(S)
    c.saveGState()
    c.addPath(squircle(body)); c.clip()

    // night sky gradient
    let sky = linearGradient([rgb(30,44,74), rgb(17,26,45), rgb(9,13,22)], [0, 0.55, 1])
    c.drawLinearGradient(sky, start: CGPoint(x: body.midX, y: body.maxY),
                         end: CGPoint(x: body.midX, y: body.minY), options: [])

    // moon with halo, upper-right
    let moon = CGPoint(x: body.midX + body.width*0.20, y: body.midY + body.height*0.24)
    let mr = body.width*0.115
    c.saveGState()
    let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [rgb(169,196,255,0.55), rgb(169,196,255,0.0)] as CFArray, locations: [0,1])!
    c.drawRadialGradient(halo, startCenter: moon, startRadius: mr*0.8,
                         endCenter: moon, endRadius: mr*3.4, options: [])
    c.restoreGState()
    c.addEllipse(in: CGRect(x: moon.x-mr, y: moon.y-mr, width: 2*mr, height: 2*mr))
    c.setFillColor(rgb(225,234,255,1)); c.fillPath()

    // layered ridges (back→front, lighter→darker) for parallax depth
    func ridge(baseY: CGFloat, amp: CGFloat, color: CGColor, phase: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: body.minX, y: body.minY))
        p.addLine(to: CGPoint(x: body.minX, y: baseY))
        let steps = 60
        for i in 0...steps {
            let x = body.minX + body.width * CGFloat(i)/CGFloat(steps)
            let t = CGFloat(i)/CGFloat(steps)
            let y = baseY + sin(t * .pi * 2 + phase) * amp * 0.5
                          + sin(t * .pi * 3.7 + phase*1.7) * amp * 0.28
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: body.maxX, y: body.minY))
        p.closeSubpath()
        c.addPath(p); c.setFillColor(color); c.fillPath()
    }
    ridge(baseY: body.minY + body.height*0.40, amp: body.height*0.10, color: rgb(20,32,54), phase: 0.4)
    ridge(baseY: body.minY + body.height*0.28, amp: body.height*0.11, color: rgb(12,20,36), phase: 2.1)
    ridge(baseY: body.minY + body.height*0.16, amp: body.height*0.09, color: rgb(6,10,18), phase: 3.6)

    c.restoreGState()
    topSheen(c, body); rim(c, body)
    return c.makeImage()!
}

// ---- Concept C — "Aperture": a living scene behind glass -------------------

func conceptC(_ S: CGFloat) -> CGImage {
    let c = ctx(Int(S))
    let body = bodyRect(S)
    c.saveGState()
    c.addPath(squircle(body)); c.clip()
    // dark base
    c.setFillColor(rgb(9,12,20)); c.fill(body)

    // inset "screen" panel showing an abstract moonbeam→green flow
    let pad = body.width*0.14
    let panel = body.insetBy(dx: pad, dy: pad)
    let panelPath = CGPath(roundedRect: panel, cornerWidth: panel.width*0.22,
                           cornerHeight: panel.width*0.22, transform: nil)
    c.saveGState()
    c.addPath(panelPath); c.clip()
    let flow = linearGradient(
        [rgb(169,196,255), rgb(120,150,230), rgb(125,232,168)], [0, 0.55, 1])
    c.drawLinearGradient(flow, start: CGPoint(x: panel.minX, y: panel.maxY),
                         end: CGPoint(x: panel.maxX, y: panel.minY), options: [])
    // flowing wave bands for a "live" feel
    for i in 0..<3 {
        let p = CGMutablePath()
        let yb = panel.minY + panel.height * (0.30 + 0.22*CGFloat(i))
        p.move(to: CGPoint(x: panel.minX, y: yb))
        let steps = 40
        for s in 0...steps {
            let x = panel.minX + panel.width*CGFloat(s)/CGFloat(steps)
            let t = CGFloat(s)/CGFloat(steps)
            let y = yb + sin(t * .pi * 2 + CGFloat(i)) * panel.height*0.05
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: panel.maxX, y: panel.minY))
        p.addLine(to: CGPoint(x: panel.minX, y: panel.minY))
        p.closeSubpath()
        c.addPath(p); c.setFillColor(rgb(255,255,255, 0.06)); c.fillPath()
    }
    // glass sheen sweep
    let sheen = CGMutablePath()
    sheen.move(to: CGPoint(x: panel.minX, y: panel.maxY))
    sheen.addLine(to: CGPoint(x: panel.minX + panel.width*0.5, y: panel.maxY))
    sheen.addLine(to: CGPoint(x: panel.minX + panel.width*0.22, y: panel.minY))
    sheen.addLine(to: CGPoint(x: panel.minX, y: panel.minY))
    sheen.closeSubpath()
    c.addPath(sheen); c.setFillColor(rgb(255,255,255,0.12)); c.fillPath()
    c.restoreGState()

    // panel border
    c.addPath(panelPath); c.setStrokeColor(rgb(255,255,255,0.18))
    c.setLineWidth(body.width*0.006); c.strokePath()

    // tiny sparkle badge, bottom-right of body
    let s2 = CGPoint(x: panel.maxX - panel.width*0.04, y: panel.minY - body.height*0.02)
    c.setShadow(offset: .zero, blur: S*0.02, color: rgb(169,196,255,0.7))
    c.addPath(sparkle(center: s2, radius: body.width*0.055))
    c.setFillColor(rgb(240,245,255,1)); c.fillPath()

    c.restoreGState()
    topSheen(c, body); rim(c, body)
    return c.makeImage()!
}

// ---- render ----------------------------------------------------------------
// Usage: ./icongen <outdir> [moonrise|A|B|C]   (default: moonrise)

let out = CommandLine.arguments[1]
let choice = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "moonrise"
let chosen: (CGFloat) -> CGImage
switch choice {
case "A": chosen = conceptA
case "B": chosen = conceptB
case "C": chosen = conceptC
default:  chosen = moonrise
}

writePNG(chosen(1024), "\(out)/AppIcon-1024.png")

// Legibility sheet: the icon large, then at the sizes macOS actually uses.
let hero = 512
let smalls = [256, 128, 64, 32, 16]
let pad = 70, gap = 60
let columnH = smalls.reduce(0, +) + 26 * (smalls.count - 1)
let W = pad*2 + hero + gap + 256, H = pad*2 + max(hero, columnH)
let sc = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// light backdrop so the dark icon and its squircle silhouette read clearly
let bg = linearGradient([rgb(232,235,240), rgb(200,205,214)], [0,1])
sc.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: 0, y: 0), options: [])
sc.saveGState()
sc.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(20,26,40,0.35))
sc.draw(chosen(CGFloat(hero)),
        in: CGRect(x: CGFloat(pad), y: CGFloat(H - hero) / 2,
                   width: CGFloat(hero), height: CGFloat(hero)))
sc.restoreGState()
// the real-size column, top-aligned and baseline-stacked down the right
var top = CGFloat(H - pad)
for px in smalls {
    let y = top - CGFloat(px)
    sc.saveGState()
    sc.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: rgb(20,26,40,0.30))
    sc.draw(chosen(CGFloat(px)),
            in: CGRect(x: CGFloat(pad + hero + gap), y: y,
                       width: CGFloat(px), height: CGFloat(px)))
    sc.restoreGState()
    top = y - 26
}
writePNG(sc.makeImage()!, "\(out)/sheet.png")

let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs { writePNG(chosen(CGFloat(px)), "\(iconset)/\(name).png") }
print("rendered \(choice): AppIcon-1024.png, sheet.png, AppIcon.iconset")

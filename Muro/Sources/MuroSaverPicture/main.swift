import AppKit
import Metal
import QuartzCore
import ScreenSaver

// Takes one picture of a screen saver, for its card in Muro's Library, when
// the screen saver carries no picture of its own (owner, 2026-09-30).
//
// Muro runs this as a process of its own, so a screen saver that crashes or
// hangs takes only this down: Muro waits a little and moves on.
//
// The screen saver runs in a hidden window far off screen, since
// XScreenSaver's refuse to start without a window (found 2026-09-28). Its
// layer is then moved into a bare layer tree and drawn off screen by Core
// Animation into a Metal texture, which brings its OpenGL output along. No
// screen recording and nothing on any display.
//
// Usage: muro-saver-picture <module.saver> <picture.jpg>, about 21 seconds.
// Exits 0 with the picture written, 1 when the screen saver drew nothing,
// 2 when it could not be loaded.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: muro-saver-picture <module.saver> <picture.jpg>\n".utf8))
    exit(2)
}
let module = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])

/// The size of every card picture in the Apple section.
let width = 1280, height = 720

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

guard let bundle = Bundle(url: module),
      (try? bundle.loadAndReturnError()) != nil,
      let viewClass = bundle.principalClass as? ScreenSaverView.Type,
      let view = viewClass.init(
          frame: NSRect(x: 0, y: 0, width: width, height: height), isPreview: false),
      let device = MTLCreateSystemDefaultDevice()
else { exit(2) }

let window = NSWindow(
    contentRect: NSRect(x: -30000, y: -30000, width: width, height: height),
    styleMask: .borderless, backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
view.wantsLayer = true
window.contentView = view
window.orderFrontRegardless()
view.startAnimation()

let root = CALayer()
root.frame = CGRect(x: 0, y: 0, width: width, height: height)
root.backgroundColor = CGColor(gray: 0, alpha: 1)

let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
descriptor.usage = [.renderTarget, .shaderRead]
// Intel Macs with their own graphics memory cannot share a texture with the
// processor; theirs is copied back before it is read.
descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
guard let texture = device.makeTexture(descriptor: descriptor),
      let queue = device.makeCommandQueue()
else { exit(2) }
let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
// Attached before anything is drawn: set later, the first frame came out
// empty (tested 2026-09-30).
renderer.layer = root
renderer.bounds = root.bounds

/// Waits until the graphics card has finished the frame, since `render()`
/// only queues the work and reading straight after gets the frame before.
func waitForGPU() {
    guard let buffer = queue.makeCommandBuffer() else { return }
    if texture.storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
        blit.synchronize(resource: texture)
        blit.endEncoding()
    }
    buffer.commit()
    buffer.waitUntilCompleted()
}

/// One frame, and how much of it is more than black.
func grab() -> (image: CGImage, drawn: Double)? {
    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()
    waitForGPU()
    let rowBytes = width * 4
    var raw = [UInt8](repeating: 0, count: rowBytes * height)
    texture.getBytes(
        &raw, bytesPerRow: rowBytes,
        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    // The texture's first row is the bottom of the picture.
    var bytes = [UInt8](repeating: 0, count: raw.count)
    for row in 0..<height {
        let from = (height - 1 - row) * rowBytes
        bytes[(row * rowBytes)..<((row + 1) * rowBytes)] = raw[from..<(from + rowBytes)]
    }
    var lit = 0
    for i in stride(from: 0, to: bytes.count, by: 4)
    where Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) > 60 {
        lit += 1
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
              width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                  | CGBitmapInfo.byteOrder32Little.rawValue),
              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return (image, Double(lit) / Double(width * height))
}

/// Many screen savers start from black, or from a few frames of noise, and
/// fill the screen over many seconds; GLMatrix's rain takes about twenty to
/// reach the bottom. So the latest look that is nearly as full as the fullest
/// one wins, which also passes over a look caught in a fade to black.
var looks: [(image: CGImage, drawn: Double)] = []

func finish() {
    let fullest = looks.map(\.drawn).max() ?? 0
    guard fullest > 0.003,
          let chosen = looks.last(where: { $0.drawn >= fullest * 0.6 })
    else { exit(1) }
    let picture = NSBitmapImageRep(cgImage: chosen.image)
    guard let data = picture.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
          (try? data.write(to: output, options: .atomic)) != nil
    else { exit(1) }
    exit(0)
}

// A second to start in its window, then into the bare tree, then five looks.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let layer = view.layer {
        layer.removeFromSuperlayer()
        layer.frame = root.bounds
        root.addSublayer(layer)
    }
    CATransaction.commit()
    CATransaction.flush()
    let delays = [4.0, 8.0, 12.0, 16.0, 20.0]
    for (index, delay) in delays.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let frame = grab() { looks.append(frame) }
            if index == delays.count - 1 { finish() }
        }
    }
}

// Never longer than this, whatever the screen saver does.
DispatchQueue.main.asyncAfter(deadline: .now() + 28) { exit(1) }

app.run()

import AppKit

// Swivel app icon: Claude-coral squircle, white 10-ray starburst (matching the
// menu-bar mark), and the switch-arrow badge. Vector-drawn at every size so
// small variants stay crisp rather than being downscaled mush.
func render(_ size: CGFloat) -> Data {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // macOS icon grid: the card occupies ~80% of the canvas, leaving margin
    // for the system's shadow treatment.
    let inset = size * 0.0977
    let card = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
    let radius = card.width * 0.2237
    let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)

    // Coral gradient — Claude brand hue, light top to deep bottom.
    let grad = NSGradient(starting: NSColor(srgbRed: 0.918, green: 0.565, blue: 0.435, alpha: 1),
                          ending:   NSColor(srgbRed: 0.769, green: 0.361, blue: 0.235, alpha: 1))!
    path.addClip()
    grad.draw(in: card, angle: -90)
    NSGraphicsContext.current!.cgContext.resetClip()

    // Inner top highlight for a little dimensionality.
    if size >= 64 {
        let hl = NSBezierPath(roundedRect: card.insetBy(dx: card.width*0.02, dy: card.height*0.02),
                              xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        hl.lineWidth = max(1, size * 0.006)
        hl.stroke()
    }

    // 10-ray starburst, same mark as the menu bar icon.
    let center = NSPoint(x: card.midX, y: card.midY)
    let outer = card.width * 0.315
    let inner = card.width * 0.045
    let rays = NSBezierPath()
    rays.lineCapStyle = .round
    for i in 0..<10 {
        let a = (CGFloat.pi * 2 / 10) * CGFloat(i)
        rays.move(to: NSPoint(x: center.x + inner*cos(a), y: center.y + inner*sin(a)))
        rays.line(to: NSPoint(x: center.x + outer*cos(a), y: center.y + outer*sin(a)))
    }
    NSColor.white.setStroke()
    rays.lineWidth = card.width * 0.058
    rays.stroke()

    // Switch-arrow badge, bottom-right — the "swivel" cue. Dropped below 64px
    // where it would collapse into noise.
    if size >= 64 {
        let bd = card.width * 0.26
        let inset2 = card.width * 0.055
        let br = NSRect(x: card.maxX - bd - inset2, y: card.minY + inset2,
                        width: bd, height: bd)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: br).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: bd*0.58, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [
                NSColor(srgbRed: 0.769, green: 0.361, blue: 0.235, alpha: 1)]))
        if let g = NSImage(systemSymbolName: "arrow.left.arrow.right",
                           accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let gs = g.size
            g.draw(in: NSRect(x: br.midX - gs.width/2, y: br.midY - gs.height/2,
                              width: gs.width, height: gs.height))
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
let dir = "Swivel.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, s) in sizes {
    try! render(s).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
print("rendered \(sizes.count) sizes")

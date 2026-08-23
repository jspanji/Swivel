import AppKit

// DMG window backdrop: 660x400 logical. Rendered at 1x and 2x, then combined
// into a HiDPI TIFF so it stays crisp on retina.
func render(scale: CGFloat) -> Data {
    let w: CGFloat = 660, h: CGFloat = 400
    let px = Int(w*scale), py = Int(h*scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    // Warm off-white gradient — quiet, lets the icons carry the eye.
    NSGradient(starting: NSColor(srgbRed: 0.988, green: 0.980, blue: 0.976, alpha: 1),
               ending:   NSColor(srgbRed: 0.957, green: 0.941, blue: 0.933, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

    // Arrow between the two icon slots (icons sit at x=165 and x=495, y=205
    // measured from the TOP in Finder coords → y=195 from the bottom here).
    let y: CGFloat = h - 205
    let a = NSBezierPath()
    a.move(to: NSPoint(x: 268, y: y))
    a.line(to: NSPoint(x: 384, y: y))
    a.lineWidth = 3
    a.lineCapStyle = .round
    NSColor(srgbRed: 0.769, green: 0.361, blue: 0.235, alpha: 0.55).setStroke()
    a.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 392, y: y))
    head.line(to: NSPoint(x: 375, y: y + 9))
    head.line(to: NSPoint(x: 375, y: y - 9))
    head.close()
    NSColor(srgbRed: 0.769, green: 0.361, blue: 0.235, alpha: 0.55).setFill()
    head.fill()

    // Caption under the arrow.
    let para = NSMutableParagraphStyle(); para.alignment = .center

    // Wordmark.
    let t: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.22, green: 0.20, blue: 0.19, alpha: 1),
        .paragraphStyle: para
    ]
    ("Swivel" as NSString).draw(in: NSRect(x: 0, y: h - 58, width: w, height: 28), withAttributes: t)
    let sub: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor(srgbRed: 0.52, green: 0.48, blue: 0.46, alpha: 1),
        .paragraphStyle: para
    ]
    ("Switch Claude accounts from your menu bar" as NSString).draw(
        in: NSRect(x: 0, y: h - 80, width: w, height: 18), withAttributes: sub)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
try! render(scale: 1).write(to: URL(fileURLWithPath: "Resources/dmg/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "Resources/dmg/background@2x.png"))
print("background rendered")

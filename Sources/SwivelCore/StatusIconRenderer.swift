import AppKit

/// Renders the menu-bar status icon. Pure Core Graphics — given a profile
/// color, Claude's service level, and the active account's usage, it returns
/// an `NSImage`. No app state, so it's trivially unit/snapshot-testable and
/// keeps ~150 lines of drawing out of `AppDelegate`.
///
/// Three independent signals, each in its own visual real estate:
///   profile color = "which account am I on"
///   ray color     = "is Claude's service OK"
///   top bar       = "am I about to hit my personal rate limit"
enum StatusIconRenderer {

    /// Claude-style menu bar icon:
    ///   - Rounded square background in the active profile's color.
    ///   - 10-ray starburst on top, colored by Claude's service status.
    ///   - Thin progress bar along the TOP edge, filled to the active
    ///     account's utilization when approaching/over the rate limit.
    ///     Absent (no bar drawn) in healthy state — empty top = all fine.
    ///   - Arrow-switch badge in the bottom-right.
    static func make(
        backgroundColor: NSColor,
        claudeStatus: ClaudeStatusLevel?,
        usage: UsageSnapshot? = nil
    ) -> NSImage {
        let canvas: CGFloat = 22
        let totalSize = NSSize(width: canvas, height: canvas)

        // Badge geometry: subtle indicator tucked into the bottom-right.
        let badgeSize: CGFloat = 6.5
        let badgeRect = NSRect(
            x: canvas - badgeSize,
            y: 0,
            width: badgeSize,
            height: badgeSize
        )

        let composite = NSImage(size: totalSize)
        composite.lockFocus()

        // 1. Rounded card in the profile color.
        let bgRect = NSRect(origin: .zero, size: totalSize).insetBy(dx: 1, dy: 1)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 5, yRadius: 5)
        backgroundColor.setFill()
        bgPath.fill()

        // 2. White multi-ray starburst centered in the card. Drawn from
        //    primitives so we can pick the ray count exactly; SF Symbols'
        //    `asterisk` is capped at 6 points which reads too sparse.
        let rayCount = 10
        let innerRadius: CGFloat = 1.0   // tiny center gap
        let outerRadius: CGFloat = 7.5
        let center = NSPoint(x: canvas / 2, y: canvas / 2)

        // Rays are drawn in two passes: a halo first (so the rays stay
        // legible if the profile color and status color happen to
        // share a hue — e.g. a green profile with "operational" green
        // rays), then the main status color on top.
        let rays = NSBezierPath()
        rays.lineCapStyle = .round
        for i in 0..<rayCount {
            let angle = (CGFloat.pi * 2 / CGFloat(rayCount)) * CGFloat(i)
            let from = NSPoint(
                x: center.x + innerRadius * cos(angle),
                y: center.y + innerRadius * sin(angle)
            )
            let to = NSPoint(
                x: center.x + outerRadius * cos(angle),
                y: center.y + outerRadius * sin(angle)
            )
            rays.move(to: from)
            rays.line(to: to)
        }

        // Halo pass — adaptive to profile luminance. A black halo on a
        // dark profile is invisible (the old bug); every color in the
        // current palette lands below 0.35 luminance, so in practice
        // we always draw a white halo today. The branch is there so
        // a lighter custom profile (future feature) still gets the
        // right treatment.
        let profileLum = relativeLuminance(of: backgroundColor)
        let haloColor: NSColor = profileLum >= 0.5
            ? NSColor.black.withAlphaComponent(0.45)
            : NSColor.white.withAlphaComponent(0.55)
        haloColor.setStroke()
        rays.lineWidth = 2.5
        rays.stroke()

        // Main pass — status color.
        MenuStyle.statusRayColor(for: claudeStatus).setStroke()
        rays.lineWidth = 1.5
        rays.stroke()

        // 2. Translucent white circle for the badge background. No border —
        //    the soft edge blends into the card rather than competing with
        //    the starburst for attention.
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        // 3. Top-edge usage progress bar — only drawn when the active
        //    account is approaching or over its rate limit.
        drawUsageBar(usage: usage, cardRect: bgRect)

        // 4. Switch-arrow glyph — muted gray, centered in the badge.
        let arrowConfig = NSImage.SymbolConfiguration(pointSize: 3.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [
                NSColor.black.withAlphaComponent(0.6)
            ]))
        if let arrows = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "Switch"
        )?.withSymbolConfiguration(arrowConfig) {
            let g = arrows.size
            let drawRect = NSRect(
                x: badgeRect.midX - g.width / 2,
                y: badgeRect.midY - g.height / 2,
                width: g.width,
                height: g.height
            )
            arrows.draw(in: drawRect)
        }

        composite.unlockFocus()
        return composite
    }

    /// Draw the usage progress bar along the top edge of the icon card.
    /// Only runs when `usage` indicates a warning — the healthy path
    /// renders no bar, keeping the icon calm until there's something to
    /// flag. A subtle dark track keeps even a small fill legible against a
    /// warm profile color.
    private static func drawUsageBar(usage: UsageSnapshot?, cardRect: NSRect) {
        guard let usage = usage,
              usage.status == .approachingLimit || usage.status == .limitReached,
              let utilization = usage.utilization
        else { return }

        let barHeight: CGFloat = 2.0
        let inset: CGFloat = 2.0
        let barY = cardRect.maxY - barHeight - 0.5
        let barTrack = NSRect(
            x: cardRect.minX + inset,
            y: barY,
            width: cardRect.width - 2 * inset,
            height: barHeight
        )

        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: barTrack).fill()

        // Floor at 4% so "approaching_limit" just past threshold still draws.
        let clamped = max(0.04, min(1.0, utilization))
        let fillColor: NSColor = {
            switch usage.status {
            case .limitReached: return .systemRed
            case .approachingLimit:
                return clamped >= 0.9 ? .systemRed : .systemOrange
            default: return .systemOrange
            }
        }()
        let fillRect = NSRect(
            x: barTrack.minX,
            y: barTrack.minY,
            width: barTrack.width * CGFloat(clamped),
            height: barTrack.height
        )
        fillColor.setFill()
        NSBezierPath(rect: fillRect).fill()
    }

    /// WCAG-style relative luminance of a color in sRGB. Used to decide
    /// whether to place light- or dark-tinted chrome over a given profile
    /// background (e.g. the ray halo).
    static func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.redComponent)
            + 0.7152 * lin(rgb.greenComponent)
            + 0.0722 * lin(rgb.blueComponent)
    }
}

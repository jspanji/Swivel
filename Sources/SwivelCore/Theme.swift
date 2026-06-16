import AppKit
import SwiftUI

/// One named color choice offered in the "Profile Color" menu. `hex` is
/// what we persist (stable across OS appearance changes — system colors
/// would resolve differently under macOS accent/appearance overrides).
struct ColorPreset {
    let name: String
    let hex: String
}

/// Palette + small rendering utilities shared by the popover/widget
/// (swatches) and the menu bar icon (ray color).
enum MenuStyle {
    /// Profile color palette. "Identity" colors — sophisticated and
    /// curated, ~60% saturation. Deliberately muted so the bright
    /// status rays drawn on top have clear visual hierarchy. Each hue
    /// is well-separated from its neighbors on the color wheel, so 10
    /// profiles remain distinguishable at 22-point menu bar size.
    static let colorPresets: [ColorPreset] = [
        ColorPreset(name: "Red",     hex: "#BE3A3A"),   // warm brick red
        ColorPreset(name: "Orange",  hex: "#D97757"),   // Claude brand coral
        ColorPreset(name: "Amber",   hex: "#C68A2B"),   // warm gold
        ColorPreset(name: "Green",   hex: "#4A8659"),   // forest / sage
        ColorPreset(name: "Teal",    hex: "#2D8B89"),   // deep teal
        ColorPreset(name: "Blue",    hex: "#3559A1"),   // confident cobalt
        ColorPreset(name: "Indigo",  hex: "#5050A8"),   // indigo
        ColorPreset(name: "Purple",  hex: "#7246B0"),   // rich plum
        ColorPreset(name: "Pink",    hex: "#B84381"),   // rose (not neon)
        ColorPreset(name: "Slate",   hex: "#5F6773")    // cool neutral gray
    ]

    /// Small 12×12 rounded colored square for use as a menu item leading
    /// icon. Outline uses the dynamic `separatorColor` so the edge
    /// reads correctly in both light and dark menu appearances — a
    /// fixed black outline (the previous behaviour) disappeared in
    /// dark mode.
    static func colorSwatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.25, dy: 0.25),
            xRadius: 3, yRadius: 3
        )
        border.lineWidth = 0.5
        border.stroke()
        img.unlockFocus()
        return img
    }

    /// Convenience — look up a preset by hex and render its swatch.
    static func colorSwatch(hex: String) -> NSImage? {
        guard let color = NSColor(hexString: hex) else { return nil }
        return colorSwatch(color)
    }

    /// Status ray colors. These are "alert" colors — punchy, saturated,
    /// universally-recognized (Tailwind-500-ish). Brighter and more
    /// saturated than the profile palette so status reads as distinct
    /// signal *over* the profile-color background.
    ///
    /// Red covers both `major` and `critical` — orange is too easy to
    /// confuse with yellow at menu bar size. Loading/unknown is white
    /// for maximum contrast against any profile color.
    static func statusRayColor(for level: ClaudeStatusLevel?) -> NSColor {
        guard let level = level else { return .white }
        let hex: String
        switch level {
        case .none:        hex = "#22C55E"   // emerald — operational
        case .minor:       hex = "#F59E0B"   // amber — warning
        case .major:       hex = "#EF4444"   // red — alert
        case .critical:    hex = "#EF4444"   // red — same visual weight
        case .maintenance: hex = "#3B82F6"   // cobalt — info
        case .unknown:     return .white
        }
        return NSColor(hexString: hex) ?? .white
    }

    /// SwiftUI flavor of the status color, for the popover banner and
    /// footer dot. Unknown/loading maps to gray rather than white —
    /// inside translucent surfaces white reads as "operational-ish",
    /// gray reads correctly as "no signal".
    static func statusColor(for level: ClaudeStatusLevel?) -> Color {
        guard let level = level, level != .unknown else { return Color(.systemGray) }
        return Color(nsColor: statusRayColor(for: level))
    }
}

extension Color {
    /// Parse "#RRGGBB" via the existing NSColor bridge so SwiftUI views
    /// share one hex parser with the AppKit icon code.
    init?(hexString: String) {
        guard let ns = NSColor(hexString: hexString) else { return nil }
        self.init(nsColor: ns)
    }
}

/// Legibility backing for SwiftUI content placed over a behind-window
/// `NSVisualEffectView` (the popover and the Usage Overlay both use one).
///
/// The macOS semantic label colors (`.secondary` / `.tertiary` /
/// `.quaternary`), which the rows lean on heavily, are calibrated to read
/// against an opaque window background. Over translucent glass there is no
/// such background, so on a bright wallpaper the wallpaper blurs straight
/// through and the muted text washes out — pronounced in light mode (dark
/// glass already darkens bright content enough to keep its text readable).
/// This lays the assumed backing back in: `windowBackgroundColor` is a
/// dynamic color (light in light mode, dark in dark mode), at a partial
/// opacity so the blur still reads through. Heavier in light mode where the
/// problem is; a light touch in dark mode where the glass was already fine.
///
/// Tuning knob: raise the opacities for more contrast / less glass, lower
/// them for more glass / less contrast.
private struct GlassLegibilityScrim: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor)
                    .opacity(colorScheme == .dark ? 0.3 : 0.6))
        )
    }
}

extension View {
    /// See `GlassLegibilityScrim`. `cornerRadius` should match the host
    /// card's rounding (14 for the overlay; 0 for the popover, which the
    /// system already clips to its own shape).
    func glassLegibilityScrim(cornerRadius: CGFloat = 0) -> some View {
        modifier(GlassLegibilityScrim(cornerRadius: cornerRadius))
    }
}

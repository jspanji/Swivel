import AppKit

/// Custom-drawn NSView that renders a per-account rate-limit comparison
/// at the top of the Swivel menu. Every piece of information that used
/// to live in row tooltips is now visible here — plan, messages
/// remaining, reset time, data freshness — so the user never has to
/// hover to find out what's going on.
///
/// Two-line row layout when we have data:
///
///     ▣ Personal               ▓▓▓▓▓▓░░░░   73%
///       Claude Max 5x · 1 msg left · resets in 2h 47m
///
///     ▣ Media.net              ░░░░░░░░░░   ✓
///       Claude Max 5x · snapshot 4h ago
///
/// Single-line row when we have nothing:
///
///     ▣ Personal               no data
///
/// Line 2 adapts to state: plan is always shown; warning detail
/// (remaining + reset) only when status is approaching/reached;
/// freshness is always shown for inactive (snapshot age) and only
/// when stale for active.
final class UsageHeaderView: NSView {

    struct Row {
        let name: String
        let colorHex: String?
        let isActive: Bool
        let usage: UsageSnapshot?
    }

    // MARK: - Layout constants
    //
    // All numbers assume the view is ~300pt wide. Shrinking means
    // dropping the bar + label widths in lockstep so the right side
    // still fits. Don't make `primaryLineHeight` smaller than ~16pt
    // or the name starts bumping into the bar visually.

    private static let viewWidth: CGFloat = 300
    private static let hPad: CGFloat = 14
    private static let topPad: CGFloat = 8
    private static let bottomPad: CGFloat = 10
    private static let titleHeight: CGFloat = 14
    private static let titleRowGap: CGFloat = 8

    private static let primaryLineHeight: CGFloat = 18
    private static let secondaryLineHeight: CGFloat = 14
    private static let interLineGap: CGFloat = 1
    private static let rowSpacing: CGFloat = 6

    private static let swatchSize: CGFloat = 9
    private static let swatchNameGap: CGFloat = 8
    private static let nameWidth: CGFloat = 84
    private static let barWidth: CGFloat = 84
    private static let barHeight: CGFloat = 6
    private static let barLabelGap: CGFloat = 8
    private static let labelWidth: CGFloat = 78

    // If Claude last refetched this profile's data more than this long
    // ago, we dim the row and surface the age on line 2. Matches user
    // expectation from the old tooltip-based warning.
    private static let staleAfter: TimeInterval = 30 * 60    // 30 minutes
    private static let staleDimming: CGFloat = 0.55          // 55% opacity

    private let rows: [Row]

    // MARK: - Init / sizing

    init(rows: [Row]) {
        self.rows = rows
        let totalHeight = Self.topPad
            + Self.titleHeight
            + Self.titleRowGap
            + Self.totalRowsHeight(rows: rows)
            + Self.bottomPad
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: totalHeight))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static func rowHeight(for usage: UsageSnapshot?) -> CGFloat {
        if usage == nil { return primaryLineHeight }
        return primaryLineHeight + interLineGap + secondaryLineHeight
    }

    private static func totalRowsHeight(rows: [Row]) -> CGFloat {
        let sum = rows.reduce(CGFloat(0)) { $0 + rowHeight(for: $1.usage) }
        let gaps = CGFloat(max(0, rows.count - 1)) * rowSpacing
        return sum + gaps
    }

    // NSMenuItem sometimes routes clicks through the view; returning nil
    // makes the row passive so clicks pass through to the menu rather
    // than getting caught on the custom view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        drawTitle(in: bounds)

        // Rows stack top-to-bottom under the title. Each row may be one
        // or two lines tall, so we advance `y` by its computed height.
        var y = bounds.height - Self.topPad - Self.titleHeight - Self.titleRowGap
        for row in rows {
            let h = Self.rowHeight(for: row.usage)
            y -= h
            drawRow(row, in: NSRect(x: 0, y: y, width: bounds.width, height: h))
            y -= Self.rowSpacing
        }
    }

    // MARK: - Title

    private func drawTitle(in bounds: NSRect) {
        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = "Usage · 5-hour window" as NSString
        let rect = NSRect(
            x: Self.hPad,
            y: bounds.height - Self.topPad - Self.titleHeight,
            width: bounds.width - 2 * Self.hPad,
            height: Self.titleHeight
        )
        text.draw(in: rect, withAttributes: attrs)
    }

    // MARK: - Row

    private func drawRow(_ row: Row, in rect: NSRect) {
        let stale = Self.isStale(row.usage)
        let primaryRect = NSRect(
            x: rect.minX,
            y: rect.maxY - Self.primaryLineHeight,
            width: rect.width,
            height: Self.primaryLineHeight
        )
        drawPrimaryLine(row, in: primaryRect, stale: stale)

        guard row.usage != nil else { return }

        let secondaryRect = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: Self.secondaryLineHeight
        )
        drawSecondaryLine(row, in: secondaryRect, stale: stale)
    }

    // MARK: - Primary line

    private func drawPrimaryLine(_ row: Row, in rect: NSRect, stale: Bool) {
        let centerY = rect.midY

        // Profile swatch
        let swatchRect = NSRect(
            x: Self.hPad,
            y: centerY - Self.swatchSize / 2,
            width: Self.swatchSize,
            height: Self.swatchSize
        )
        let swatchColor = row.colorHex.flatMap { NSColor(hexString: $0) }
            ?? NSColor.systemGray
        swatchColor.setFill()
        NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2).fill()
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(
            roundedRect: swatchRect.insetBy(dx: 0.25, dy: 0.25),
            xRadius: 2, yRadius: 2
        )
        outline.lineWidth = 0.5
        outline.stroke()

        // Name — bold for active, regular otherwise. Stale dims the
        // text so the row reads as lower-confidence.
        let nameFont: NSFont = row.isActive
            ? .boldSystemFont(ofSize: NSFont.systemFontSize - 1)
            : .menuFont(ofSize: NSFont.systemFontSize - 1)
        let nameColor: NSColor = stale
            ? NSColor.labelColor.withAlphaComponent(Self.staleDimming)
            : NSColor.labelColor
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: nameColor
        ]
        let nameX = swatchRect.maxX + Self.swatchNameGap
        let nameStr = truncate(row.name, toFit: Self.nameWidth, attributes: nameAttrs)
        let nameSize = (nameStr as NSString).size(withAttributes: nameAttrs)
        let nameRect = NSRect(
            x: nameX,
            y: centerY - nameSize.height / 2 - 1,
            width: Self.nameWidth,
            height: nameSize.height
        )
        (nameStr as NSString).draw(in: nameRect, withAttributes: nameAttrs)

        // When the row has no usage data, skip the bar and just render
        // a muted "no data" label where the bar/label would sit.
        guard row.usage != nil else {
            drawNoDataLabel(in: rect, after: nameRect.maxX, stale: stale)
            return
        }

        // Gauge bar
        let barX = rect.maxX - Self.hPad - Self.labelWidth - Self.barLabelGap - Self.barWidth
        let barRect = NSRect(
            x: barX,
            y: centerY - Self.barHeight / 2,
            width: Self.barWidth,
            height: Self.barHeight
        )
        drawGauge(for: row, in: barRect, stale: stale)

        // Trailing label (% or ✓)
        let labelRect = NSRect(
            x: barRect.maxX + Self.barLabelGap,
            y: rect.minY,
            width: Self.labelWidth,
            height: rect.height
        )
        drawTrailingLabel(for: row, in: labelRect, stale: stale)
    }

    private func drawNoDataLabel(in rect: NSRect, after x: CGFloat, stale: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let s = "no data" as NSString
        let size = s.size(withAttributes: attrs)
        let drawRect = NSRect(
            x: rect.maxX - Self.hPad - size.width,
            y: rect.midY - size.height / 2 - 1,
            width: size.width,
            height: size.height
        )
        s.draw(in: drawRect, withAttributes: attrs)
    }

    // MARK: - Secondary line

    private func drawSecondaryLine(_ row: Row, in rect: NSRect, stale: Bool) {
        guard let usage = row.usage else { return }
        let text = Self.secondaryLineText(usage: usage, isActive: row.isActive)
        guard !text.isEmpty else { return }

        // Secondary line aligns under the account name (indented past
        // swatch) so the page has a clear two-column rhythm.
        let indent = Self.hPad + Self.swatchSize + Self.swatchNameGap
        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let color: NSColor = stale
            ? NSColor.secondaryLabelColor.withAlphaComponent(Self.staleDimming)
            : NSColor.secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let truncated = truncate(
            text,
            toFit: rect.width - indent - Self.hPad,
            attributes: attrs
        )
        let size = (truncated as NSString).size(withAttributes: attrs)
        let drawRect = NSRect(
            x: indent,
            y: rect.midY - size.height / 2 - 1,
            width: rect.width - indent - Self.hPad,
            height: size.height
        )
        (truncated as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    /// Compose the "plan · warning-detail · freshness" chain. Elements
    /// are joined with " · " and any empty segment is skipped so we
    /// don't end up with doubled separators.
    private static func secondaryLineText(usage: UsageSnapshot, isActive: Bool) -> String {
        var chunks: [String] = []

        if let tier = usage.rateLimitTier {
            chunks.append(prettyTier(tier))
        }

        // Warning detail, only when status carries live numbers.
        if usage.status == .approachingLimit || usage.status == .limitReached {
            if let remaining = usage.remaining {
                chunks.append("\(remaining) msg\(remaining == 1 ? "" : "s") left")
            }
            if let reset = usage.resetsAt {
                chunks.append("resets \(shortResetDelta(to: reset))")
            }
            if usage.overageInUse {
                chunks.append("overage in use")
            }
        }

        // Freshness tag — always for inactive (snapshots are
        // definitionally old), conditionally for active (only when
        // the live cache has aged out).
        let age = Date().timeIntervalSince(usage.dataUpdatedAt)
        if !isActive {
            chunks.append("snapshot \(compactAge(seconds: age))")
        } else if age > 5 * 60 {
            chunks.append("refreshed \(compactAge(seconds: age))")
        }

        return chunks.joined(separator: " · ")
    }

    // MARK: - Label formatters

    /// Short "time-until-reset" used in the warning detail chunk.
    ///   >= 1h  → "1h 47m" or "2h" when minutes are zero
    ///   1m–59m → "47m"
    ///   <= 0   → "due"
    private static func shortResetDelta(to reset: Date) -> String {
        let delta = reset.timeIntervalSince(Date())
        if delta <= 0 { return "due" }
        if delta < 60 { return "<1m" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        let h = Int(delta / 3600)
        let m = Int((delta - Double(h) * 3600) / 60)
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    /// Short "how long ago" used in freshness tags.
    ///   >= 24h → "4d ago"
    ///   >= 1h  → "4h ago"
    ///   >= 1m  → "47m ago"
    ///   < 1m   → "just now"
    private static func compactAge(seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    /// Turn Claude's internal plan id into a short label.
    ///   "default_claude_max_5x"  → "Claude Max 5x"
    ///   "default_claude_pro"      → "Claude Pro"
    ///   "default_claude_free"     → "Claude Free"
    /// Unknown shapes pass through title-cased so we don't render a
    /// raw id at the user.
    private static func prettyTier(_ raw: String) -> String {
        let trimmed = raw.hasPrefix("default_") ? String(raw.dropFirst("default_".count)) : raw
        let parts = trimmed.split(separator: "_").map { String($0) }
        let cased = parts.map { token -> String in
            // Preserve short tier markers like "5x" as-is.
            if token.range(of: #"^\d+x$"#, options: .regularExpression) != nil { return token }
            return token.prefix(1).uppercased() + token.dropFirst()
        }
        return cased.joined(separator: " ")
    }

    // MARK: - Gauge

    private func drawGauge(for row: Row, in rect: NSRect, stale: Bool) {
        let radius = rect.height / 2
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        guard let usage = row.usage else { return }
        guard usage.status == .approachingLimit || usage.status == .limitReached,
              let util = usage.utilization else {
            return
        }
        let clamped = max(0.0, min(1.0, util))
        let fillWidth = rect.width * CGFloat(clamped)
        guard fillWidth > 0.5 else { return }
        let fillRect = NSRect(
            x: rect.minX, y: rect.minY,
            width: fillWidth, height: rect.height
        )
        var fillColor = Self.gaugeColor(status: usage.status, utilization: clamped)
        if stale { fillColor = fillColor.withAlphaComponent(Self.staleDimming) }
        fillColor.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }

    private static func gaugeColor(
        status: UsageSnapshot.Status,
        utilization: Double
    ) -> NSColor {
        switch status {
        case .limitReached: return .systemRed
        case .approachingLimit:
            return utilization >= 0.9 ? .systemRed : .systemOrange
        default: return .secondaryLabelColor
        }
    }

    // MARK: - Trailing label (% / ✓)

    private func drawTrailingLabel(for row: Row, in rect: NSRect, stale: Bool) {
        let font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let (text, rawColor): (String, NSColor) = {
            guard let usage = row.usage else {
                return ("—", .tertiaryLabelColor)
            }
            switch usage.status {
            case .approachingLimit, .limitReached:
                let pct = Int(((usage.utilization ?? 0) * 100).rounded())
                return (
                    "\(pct)%",
                    Self.gaugeColor(status: usage.status, utilization: usage.utilization ?? 0)
                )
            case .ok:
                return ("✓", .systemGreen.withAlphaComponent(0.75))
            case .unknown:
                return ("—", .tertiaryLabelColor)
            }
        }()

        let color = stale ? rawColor.withAlphaComponent(Self.staleDimming) : rawColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let drawRect = NSRect(
            x: rect.minX,
            y: rect.midY - size.height / 2 - 1,
            width: rect.width,
            height: size.height
        )
        (text as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    // MARK: - Helpers

    private static func isStale(_ usage: UsageSnapshot?) -> Bool {
        guard let u = usage else { return false }
        return Date().timeIntervalSince(u.dataUpdatedAt) > Self.staleAfter
    }

    private func truncate(
        _ s: String,
        toFit width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> String {
        let ns = s as NSString
        if ns.size(withAttributes: attributes).width <= width { return s }
        var cut = s
        while !cut.isEmpty {
            let candidate = cut + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                return candidate
            }
            cut.removeLast()
        }
        return "…"
    }
}

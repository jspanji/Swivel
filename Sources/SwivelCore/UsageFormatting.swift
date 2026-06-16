import SwiftUI

/// Display logic for rate-limit snapshots, shared by the popover and the
/// desktop widget so both surfaces describe usage identically. Ported
/// verbatim from the retired `UsageHeaderView` — the formats here are
/// load-bearing UX ("Claude Max 5x · 1 msg left · resets in 2h 47m"),
/// not incidental strings.
enum UsageFormatting {

    /// If Claude last refetched this profile's data more than this long
    /// ago, the row dims and surfaces the age on line 2.
    static let staleAfter: TimeInterval = 30 * 60    // 30 minutes
    static let staleDimming: Double = 0.55           // 55% opacity

    static func isStale(_ usage: UsageSnapshot?) -> Bool {
        guard let u = usage else { return false }
        return Date().timeIntervalSince(u.dataUpdatedAt) > staleAfter
    }

    /// Compose the "plan · warning-detail · freshness" chain. Elements
    /// are joined with " · " and any empty segment is skipped so we
    /// don't end up with doubled separators.
    static func secondaryLine(usage: UsageSnapshot, isActive: Bool) -> String {
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

    /// Short "time-until-reset" used in the warning detail chunk.
    ///   >= 24h → "3d 21h" or "4d" when hours are zero (weekly windows)
    ///   >= 1h  → "1h 47m" or "2h" when minutes are zero
    ///   1m–59m → "47m"
    ///   <= 0   → "due"
    static func shortResetDelta(to reset: Date) -> String {
        let delta = reset.timeIntervalSince(Date())
        if delta <= 0 { return "due" }
        if delta < 60 { return "<1m" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86400 {
            let h = Int(delta / 3600)
            let m = Int((delta - Double(h) * 3600) / 60)
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        let d = Int(delta / 86400)
        let h = Int((delta - Double(d) * 86400) / 3600)
        return h > 0 ? "\(d)d \(h)h" : "\(d)d"
    }

    /// Short "how long ago" used in freshness tags.
    ///   >= 24h → "4d ago"
    ///   >= 1h  → "4h ago"
    ///   >= 1m  → "47m ago"
    ///   < 1m   → "just now"
    static func compactAge(seconds: TimeInterval) -> String {
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
    static func prettyTier(_ raw: String) -> String {
        let trimmed = raw.hasPrefix("default_") ? String(raw.dropFirst("default_".count)) : raw
        let parts = trimmed.split(separator: "_").map { String($0) }
        let cased = parts.map { token -> String in
            // Preserve short tier markers like "5x" as-is.
            if token.range(of: #"^\d+x$"#, options: .regularExpression) != nil { return token }
            return token.prefix(1).uppercased() + token.dropFirst()
        }
        return cased.joined(separator: " ")
    }

    /// Human-readable time label like "2m ago" / "3h ago" / "Apr 17,
    /// 14:22" for backup entries.
    static func relativeTimeLabel(for date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }

    // MARK: - Gauge

    /// Whether the gauge fill should be drawn at all — only when the
    /// account is approaching/over a limit. Healthy rows show an empty
    /// track; signal-by-absence keeps the list calm.
    static func gaugeFillFraction(_ usage: UsageSnapshot?) -> Double? {
        guard let usage = usage,
              usage.status == .approachingLimit || usage.status == .limitReached,
              let util = usage.utilization else { return nil }
        return max(0.0, min(1.0, util))
    }

    // MARK: - Trailing label (% / ✓ / —)

    // MARK: - Live usage (opt-in claude.ai fetch)

    /// Short plan label for the row header, e.g.
    /// "default_claude_max_5x" → "Max 5x". Only **recognized** plans are
    /// returned; unknown internal codenames (e.g. "raven") return nil so we
    /// never show users a raw codename — the em-dash principle.
    static func compactTier(_ raw: String?) -> String? {
        guard var t = raw?.lowercased(), !t.isEmpty else { return nil }
        if t.hasPrefix("default_") { t = String(t.dropFirst("default_".count)) }
        if t.hasPrefix("claude_max") || t == "max" {
            let suffix = t.replacingOccurrences(of: "claude_max", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            // "5x", "20x" → "Max 5x"; bare → "Max".
            if suffix.range(of: "^\\d+x$", options: .regularExpression) != nil {
                return "Max \(suffix)"
            }
            return "Max"
        }
        if t.contains("claude_pro") || t == "pro" { return "Pro" }
        if t.contains("claude_free") || t == "free" { return "Free" }
        if t.contains("claude_team") || t == "team" { return "Team" }
        if t.contains("enterprise") { return "Enterprise" }
        return nil
    }

    /// Single source of truth for usage→color. Calm by default: a quiet
    /// neutral in the healthy band so a list of low-usage rows doesn't read
    /// as a wall of green; amber and red are reserved for genuine pressure
    /// (signal by exception, matching the menu-bar icon's philosophy).
    static func usageColor(_ util: Double) -> Color {
        if util >= 0.9 { return Color(.systemRed) }
        if util >= 0.75 { return Color(.systemOrange) }
        return Color(.secondaryLabelColor)
    }

    static func trailingLabel(_ usage: UsageSnapshot?) -> (text: String, color: Color) {
        guard let usage = usage else {
            return ("—", Color(.tertiaryLabelColor))
        }
        switch usage.status {
        case .approachingLimit, .limitReached:
            let pct = Int(((usage.utilization ?? 0) * 100).rounded())
            // limitReached always reads red even if utilization rounds low.
            let color = usage.status == .limitReached
                ? Color(.systemRed)
                : usageColor(usage.utilization ?? 0)
            return ("\(pct)%", color)
        case .ok:
            return ("✓", Color(.systemGreen).opacity(0.75))
        case .unknown:
            return ("—", Color(.tertiaryLabelColor))
        }
    }
}

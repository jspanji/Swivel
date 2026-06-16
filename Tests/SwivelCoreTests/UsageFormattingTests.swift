import Testing
@testable import SwivelCore

@Suite("UsageFormatting")
struct UsageFormattingTests {

    // MARK: - compactTier (the "Raven" codename guard)

    @Test func compactTierKnownPlans() {
        #expect(UsageFormatting.compactTier("default_claude_max_5x") == "Max 5x")
        #expect(UsageFormatting.compactTier("default_claude_max_20x") == "Max 20x")
        #expect(UsageFormatting.compactTier("claude_max") == "Max")
        #expect(UsageFormatting.compactTier("default_claude_pro") == "Pro")
        #expect(UsageFormatting.compactTier("default_claude_free") == "Free")
        #expect(UsageFormatting.compactTier("default_claude_team") == "Team")
        #expect(UsageFormatting.compactTier("some_enterprise_tier") == "Enterprise")
    }

    @Test func compactTierHidesUnknownCodenames() {
        // The whole point: internal codenames must not leak to the UI.
        #expect(UsageFormatting.compactTier("raven") == nil)
        #expect(UsageFormatting.compactTier("default_raven") == nil)
        #expect(UsageFormatting.compactTier("iguana_necktie") == nil)
        #expect(UsageFormatting.compactTier(nil) == nil)
        #expect(UsageFormatting.compactTier("") == nil)
    }

    // MARK: - usageColor (calm-by-default thresholds)

    @Test func usageColorBands() {
        // Healthy band = neutral, not green.
        #expect(UsageFormatting.usageColor(0.0) == Color(.secondaryLabelColor))
        #expect(UsageFormatting.usageColor(0.5) == Color(.secondaryLabelColor))
        #expect(UsageFormatting.usageColor(0.74) == Color(.secondaryLabelColor))
        // Warning band.
        #expect(UsageFormatting.usageColor(0.75) == Color(.systemOrange))
        #expect(UsageFormatting.usageColor(0.89) == Color(.systemOrange))
        // Critical band.
        #expect(UsageFormatting.usageColor(0.9) == Color(.systemRed))
        #expect(UsageFormatting.usageColor(1.0) == Color(.systemRed))
    }

    // MARK: - shortResetDelta (the "93h 43m" → "3d 21h" fix)

    @Test func shortResetDeltaTiers() {
        let now = Date()
        // +5s buffer keeps the values just above each flooring boundary, so
        // the few ms that elapse before the call don't drop "47m" to "46m".
        // (shortResetDelta floors by design.)
        #expect(UsageFormatting.shortResetDelta(to: now.addingTimeInterval(-10)) == "due")
        #expect(UsageFormatting.shortResetDelta(to: now.addingTimeInterval(30)) == "<1m")
        #expect(UsageFormatting.shortResetDelta(to: now.addingTimeInterval(47 * 60 + 5)) == "47m")
        #expect(UsageFormatting.shortResetDelta(to: now.addingTimeInterval(2 * 3600 + 5)) == "2h")
        #expect(UsageFormatting.shortResetDelta(to: now.addingTimeInterval(3600 + 47 * 60 + 5)) == "1h 47m")
        // Days tier — the bug was showing "93h 43m" for a weekly window.
        #expect(UsageFormatting.shortResetDelta(to: now.addingTimeInterval(93 * 3600 + 43 * 60 + 5)) == "3d 21h")
        #expect(UsageFormatting.shortResetDelta(to: now.addingTimeInterval(4 * 86400 + 5)) == "4d")
    }

    // MARK: - prettyTier

    @Test func prettyTierPreservesMultiplier() {
        #expect(UsageFormatting.prettyTier("default_claude_max_5x") == "Claude Max 5x")
        #expect(UsageFormatting.prettyTier("default_claude_pro") == "Claude Pro")
    }
}

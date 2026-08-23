import Testing
@testable import SwivelCore

/// Covers the `/usage` JSON parsing — the exact logic that shipped the
/// utilization-scale bug (treating 0–100 as 0–1) and the empty-window bug.
@Suite("LiveUsage parsing")
struct LiveUsageParsingTests {
    private let client = LiveUsageClient()

    /// A realistic payload captured from the probe: integer percentages,
    /// some windows null, overage off.
    private let sample: [String: Any] = [
        "five_hour": ["utilization": 48, "resets_at": "2026-06-12T18:20:00.438991+00:00"],
        "seven_day": ["utilization": 6, "resets_at": "2026-06-18T04:00:00.439016+00:00"],
        "seven_day_opus": NSNull(),
        "seven_day_sonnet": ["utilization": 0, "resets_at": NSNull()],
        "extra_usage": ["is_enabled": false, "utilization": NSNull()]
    ]

    @Test func utilizationIsPercentNotFraction() {
        let usage = client.parseUsage(sample, tier: nil)
        // 48 (percent) must become 0.48 — the bug rendered everything 100%.
        #expect(abs((usage.fiveHour?.utilization ?? -1) - 0.48) < 0.0001)
        #expect(abs((usage.sevenDay?.utilization ?? -1) - 0.06) < 0.0001)
    }

    @Test func nullWindowsAreNil() {
        let usage = client.parseUsage(sample, tier: nil)
        #expect(usage.sevenDayOpus == nil)   // null window → nil, not a 0% gauge
    }

    @Test func resetsAtParsesFractionalISO8601() {
        let usage = client.parseUsage(sample, tier: nil)
        #expect(usage.fiveHour?.resetsAt != nil)   // fractional-seconds ISO8601
    }

    @Test func overageOffWhenDisabled() {
        #expect(client.parseUsage(sample, tier: nil).overageActive == false)
    }

    @Test func overageEnabledButUnusedIsNotActive() {
        // is_enabled means "available", not "in use" — must NOT show the chip.
        let json: [String: Any] = ["extra_usage": ["is_enabled": true, "utilization": NSNull()]]
        #expect(client.parseUsage(json, tier: nil).overageActive == false)
    }

    @Test func overageActiveOnlyWhenCurrentlyDrawn() {
        // Current utilization of the extra-usage bucket is the only signal.
        #expect(client.parseUsage(["extra_usage": ["utilization": 5]], tier: nil).overageActive == true)
        #expect(client.parseUsage(["extra_usage": ["utilization": 0]], tier: nil).overageActive == false)
        // used_credits is cumulative — historical spend must NOT light the chip.
        #expect(client.parseUsage(
            ["extra_usage": ["is_enabled": true, "used_credits": 200, "utilization": NSNull()]],
            tier: nil
        ).overageActive == false)
    }

    @Test func utilizationClampedToOne() {
        // Defensive: a malformed >100 value must clamp, not overflow the bar.
        let json: [String: Any] = ["five_hour": ["utilization": 150]]
        #expect((client.parseUsage(json, tier: nil).fiveHour?.utilization ?? -1) == 1.0)
    }

    @Test func tierPassedThrough() {
        #expect(client.parseUsage(sample, tier: "default_claude_max_5x").tier == "default_claude_max_5x")
    }
}

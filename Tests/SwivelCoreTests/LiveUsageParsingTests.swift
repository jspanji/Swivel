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

    @Test func overageOnWhenEnabled() {
        let json: [String: Any] = ["extra_usage": ["is_enabled": true]]
        #expect(client.parseUsage(json, tier: nil).overageActive == true)
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

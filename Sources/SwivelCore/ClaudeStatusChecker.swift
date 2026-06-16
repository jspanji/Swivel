import Foundation

/// Status indicator values returned by Anthropic's status page API.
/// https://status.anthropic.com/api/v2/status.json
enum ClaudeStatusLevel: String {
    case none = "none"                // all operational
    case minor = "minor"              // minor issues
    case major = "major"              // major issues
    case critical = "critical"        // critical outage
    case maintenance = "maintenance"  // scheduled maintenance
    case unknown = "unknown"          // fetch failed
}

struct ClaudeStatusSnapshot {
    let level: ClaudeStatusLevel
    let description: String           // e.g. "All Systems Operational"
    let checkedAt: Date
}

/// Periodically fetches the public Anthropic status page JSON and reports
/// the current indicator. No auth required — this is the same endpoint
/// status.anthropic.com's own widget hits.
///
/// Polling is **adaptive**:
///   - healthy (`.none`) → 5 min  (server-friendly when nothing is wrong)
///   - degraded (anything else) → 30 sec  (catch state transitions quickly)
///   - unknown / network error → 60 sec  (faster recovery than the healthy rate)
///
/// Call `checkNow()` on user interaction (menu open, app activation) for a
/// nearly-instant refresh — throttled so rapid re-opens don't spam the API.
final class ClaudeStatusChecker {
    // Canonical URL as of 2026. status.anthropic.com 302-redirects here.
    private let endpoint = URL(string: "https://status.claude.com/api/v2/status.json")!

    // Adaptive polling intervals, picked by current state.
    private let healthyInterval: TimeInterval = 300    // 5 minutes
    private let degradedInterval: TimeInterval = 30    // 30 seconds
    private let unknownInterval: TimeInterval = 60     // 1 minute

    // Minimum gap between network checks. Protects against a user mashing
    // the menu open/close while we're already fresh.
    private let userTriggerThrottle: TimeInterval = 10

    private var timer: Timer?
    private var stopped = false
    private var lastCheckStartedAt: Date?
    private var inFlight = false

    /// Called on the main thread whenever a new snapshot arrives. Fires on
    /// first successful fetch, and on each subsequent poll (even if level
    /// hasn't changed — caller can compare against `latest` if they want).
    var onUpdate: ((ClaudeStatusSnapshot) -> Void)?

    private(set) var latest: ClaudeStatusSnapshot?

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = false
        check()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    /// Trigger an immediate check on user interaction. No-op if a request is
    /// already in flight or if the last check started less than
    /// `userTriggerThrottle` seconds ago — the data is already fresh.
    func checkNow() {
        dispatchPrecondition(condition: .onQueue(.main))
        if inFlight { return }
        if let last = lastCheckStartedAt,
           Date().timeIntervalSince(last) < userTriggerThrottle { return }
        check()
    }

    private func currentInterval() -> TimeInterval {
        guard let level = latest?.level else { return unknownInterval }
        switch level {
        case .none: return healthyInterval
        case .unknown: return unknownInterval
        case .minor, .major, .critical, .maintenance: return degradedInterval
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        guard !stopped else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: currentInterval(),
            repeats: false
        ) { [weak self] _ in
            self?.check()
        }
    }

    private func check() {
        inFlight = true
        lastCheckStartedAt = Date()

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            let snap = Self.parse(data) ?? ClaudeStatusSnapshot(
                level: .unknown,
                description: "Couldn't reach status page",
                checkedAt: Date()
            )
            DispatchQueue.main.async {
                self.inFlight = false
                self.latest = snap
                self.onUpdate?(snap)
                self.scheduleNext()
            }
        }.resume()
    }

    private static func parse(_ data: Data?) -> ClaudeStatusSnapshot? {
        guard
            let data = data,
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let status = obj["status"] as? [String: Any],
            let indicator = status["indicator"] as? String
        else { return nil }

        return ClaudeStatusSnapshot(
            level: ClaudeStatusLevel(rawValue: indicator) ?? .unknown,
            description: (status["description"] as? String) ?? indicator.capitalized,
            checkedAt: Date()
        )
    }
}

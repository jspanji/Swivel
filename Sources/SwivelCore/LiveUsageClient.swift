import Foundation
import CommonCrypto
import os.log

/// Live rate-limit utilization for one account, fetched from claude.ai.
///
/// **This is the only part of Swivel that makes an authenticated network
/// request.** It is gated behind an explicit opt-in (`liveUsageEnabled`,
/// off by default). When disabled, Swivel touches the network only for the
/// public status page, exactly as before.
///
/// Mechanism (the same data the claude.ai web app shows on its usage page):
///   1. Read the account's `sessionKey` + `lastActiveOrg` cookies from the
///      profile's Chromium cookie store.
///   2. Decrypt them with the device-local "Claude Safe Storage" key (the
///      same key Swivel already reads to swap cookies on a switch).
///   3. `GET /api/organizations/<org>/usage` with that cookie.
///
/// Read-only, the user's own session, the user's own account — the network
/// equivalent of opening claude.ai in a browser. Nothing is written, and the
/// decrypted cookie never leaves the process except as the `Cookie` header on
/// that one request to claude.ai.
struct LiveUsage {
    struct Window {
        let utilization: Double    // 0.0–1.0
        let resetsAt: Date?
    }
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    /// Plan / rate-limit tier, raw form e.g. "default_claude_max_5x".
    /// Fetched from the org endpoint and cached long-term (it rarely
    /// changes), so it's reliable for every account — unlike the local
    /// cache, which only carries it for the active one.
    let tier: String?
    /// True when the account has paid overage / extra usage active.
    let overageActive: Bool
    let fetchedAt: Date
}

final class LiveUsageClient {

    // Per-profile cache so a popover open / widget tick doesn't refetch on
    // every refresh. Keyed by the cookie store's path; TTL keeps the
    // reset countdowns honest without hammering the API.
    private struct CacheEntry { let usage: LiveUsage; let at: Date }
    private var cache: [String: CacheEntry] = [:]
    private let cacheQueue = DispatchQueue(label: "com.swivel.liveusage.cache")
    private let ttl: TimeInterval = 120

    // Plan tier changes rarely, so it gets its own long-lived cache keyed
    // by org — most usage refreshes reuse it and skip the extra request.
    private struct TierEntry { let tier: String?; let at: Date }
    private var tierCache: [String: TierEntry] = [:]
    private let tierTTL: TimeInterval = 3600

    /// Fetch live usage for the account whose Claude profile lives at
    /// `claudeDir` (the live dir for the active account, or a snapshot dir
    /// for an inactive one). Blocking — call off the main thread. Returns
    /// nil on any failure (no cookie, expired session → 401, key mismatch,
    /// network error); callers fall back to the local snapshot.
    func fetch(claudeDir: URL, safeStorageKey: String) -> LiveUsage? {
        let cookiesPath = claudeDir.appendingPathComponent("Cookies").path
        guard FileManager.default.fileExists(atPath: cookiesPath) else { return nil }

        if let cached = cacheQueue.sync(execute: { cache[cookiesPath] }),
           Date().timeIntervalSince(cached.at) < ttl {
            return cached.usage
        }

        guard let session = decryptCookie(named: "sessionKey", cookiesPath: cookiesPath, key: safeStorageKey),
              !session.isEmpty else { return nil }
        let org = resolveOrg(cookiesPath: cookiesPath, key: safeStorageKey, sessionCookie: session)
        guard let org = org, !org.isEmpty else { return nil }

        guard let json = getJSON(
            "https://claude.ai/api/organizations/\(org)/usage",
            sessionCookie: session
        ) as? [String: Any] else { return nil }

        let usage = LiveUsage(
            fiveHour: window(json["five_hour"]),
            sevenDay: window(json["seven_day"]),
            sevenDayOpus: window(json["seven_day_opus"]),
            tier: tier(org: org, sessionCookie: session),
            overageActive: overageActive(json["extra_usage"]),
            fetchedAt: Date()
        )
        cacheQueue.sync { cache[cookiesPath] = CacheEntry(usage: usage, at: Date()) }
        return usage
    }

    /// `extra_usage` ships inside the usage payload — no extra request.
    /// Treat "enabled" (or any nonzero utilization) as active.
    private func overageActive(_ any: Any?) -> Bool {
        guard let d = any as? [String: Any] else { return false }
        if let enabled = d["is_enabled"] as? Bool { return enabled }
        if let u = d["utilization"] as? Double { return u > 0 }
        return false
    }

    /// Plan tier from the org endpoint, cached for an hour per org.
    private func tier(org: String, sessionCookie: String) -> String? {
        if let e = cacheQueue.sync(execute: { tierCache[org] }),
           Date().timeIntervalSince(e.at) < tierTTL {
            return e.tier
        }
        let t = (getJSON("https://claude.ai/api/organizations/\(org)", sessionCookie: sessionCookie)
            as? [String: Any])?["rate_limit_tier"] as? String
        cacheQueue.sync { tierCache[org] = TierEntry(tier: t, at: Date()) }
        return t
    }

    // MARK: - Response parsing

    /// Pure parse of a `/usage` JSON body (+ already-resolved tier) into a
    /// `LiveUsage`, with no network or cache. Exposed for unit tests — this
    /// is the logic that shipped the utilization-scale and prefix bugs.
    func parseUsage(_ json: [String: Any], tier: String?) -> LiveUsage {
        LiveUsage(
            fiveHour: window(json["five_hour"]),
            sevenDay: window(json["seven_day"]),
            sevenDayOpus: window(json["seven_day_opus"]),
            tier: tier,
            overageActive: overageActive(json["extra_usage"]),
            fetchedAt: Date()
        )
    }

    private func window(_ any: Any?) -> LiveUsage.Window? {
        guard let dict = any as? [String: Any] else { return nil }
        // The endpoint reports utilization as a PERCENTAGE (0–100), e.g.
        // 48.0 for 48%. Store it as a 0–1 fraction for the gauges.
        let rawUtil: Double
        if let d = dict["utilization"] as? Double { rawUtil = d }
        else if let i = dict["utilization"] as? Int { rawUtil = Double(i) }
        else { return nil }
        var reset: Date?
        if let s = dict["resets_at"] as? String { reset = parseISO(s) }
        return LiveUsage.Window(utilization: max(0, min(1, rawUtil / 100)), resetsAt: reset)
    }

    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()
    private func parseISO(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - Org resolution

    /// The usage endpoint is org-scoped. Prefer the cheap `lastActiveOrg`
    /// cookie; fall back to the org list if it's absent.
    private func resolveOrg(cookiesPath: String, key: String, sessionCookie: String) -> String? {
        if let last = decryptCookie(named: "lastActiveOrg", cookiesPath: cookiesPath, key: key),
           !last.isEmpty {
            let decoded = last.removingPercentEncoding ?? last
            // Cookie is sometimes the bare UUID, sometimes JSON-ish; pull the
            // first UUID-shaped token out to be safe.
            if let uuid = firstUUID(in: decoded) { return uuid }
        }
        if let arr = getJSON("https://claude.ai/api/organizations", sessionCookie: sessionCookie) as? [Any] {
            for case let o as [String: Any] in arr {
                if let u = o["uuid"] as? String { return u }
            }
        }
        return nil
    }

    private func firstUUID(in s: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let r = s.range(of: pattern, options: .regularExpression) else {
            // No dashes? Accept a bare 32-hex too, unlikely but cheap.
            return s.range(of: "[0-9a-fA-F]{32}", options: .regularExpression).map { String(s[$0]) }
        }
        return String(s[r])
    }

    // MARK: - Networking

    private func getJSON(_ urlStr: String, sessionCookie: String) -> Any? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("sessionKey=\(sessionCookie)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        var result: Any?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sema.signal() }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data else { return }
            result = try? JSONSerialization.jsonObject(with: data)
        }.resume()
        _ = sema.wait(timeout: .now() + 20)
        return result
    }

    // MARK: - Cookie decryption (Chromium v10, macOS scheme)

    /// Decrypt one cookie value by name from the profile's cookie store.
    /// Returns nil if the cookie is absent or the Safe Storage key doesn't
    /// match (e.g. Claude was reinstalled since the snapshot was saved).
    private func decryptCookie(named name: String, cookiesPath: String, key: String) -> String? {
        // Copy out so we never lock the live DB Claude may be using.
        let tmp = NSTemporaryDirectory() + "swivel-cookie-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard (try? FileManager.default.copyItem(atPath: cookiesPath, toPath: tmp)) != nil else { return nil }
        // The copy holds (already-encrypted) cookie data; tighten to owner-only
        // as defense-in-depth.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)

        let hex = sqliteScalar(
            db: tmp,
            query: "SELECT hex(encrypted_value) FROM cookies WHERE host_key LIKE '%claude.ai%' AND name='\(name)' LIMIT 1;"
        )
        guard let hex = hex, !hex.isEmpty else { return nil }
        let blob = dataFromHex(hex)
        guard blob.count > 3 else { return nil }

        let derived = pbkdf2(password: key)
        guard let raw = aesCBCDecrypt(Data(blob.dropFirst(3)), key: derived) else { return nil }
        // Newer Chromium prepends a 32-byte SHA256(domain); the value is the
        // printable tail. Try whole first, then drop the prefix.
        return printableUTF8(raw) ?? (raw.count > 32 ? printableUTF8(Data(raw.dropFirst(32))) : nil)
    }

    private func printableUTF8(_ d: Data) -> String? {
        guard let s = String(data: d, encoding: .utf8), !s.isEmpty,
              s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) else { return nil }
        return s
    }

    private func dataFromHex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let n = s.index(i, offsetBy: 2)
            if n <= s.endIndex, let b = UInt8(s[i..<n], radix: 16) { d.append(b) }
            i = n
        }
        return d
    }

    private func pbkdf2(password: String) -> Data {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { kb in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003, kb.bindMemory(to: UInt8.self).baseAddress, 16
            )
        }
        return key
    }

    private func aesCBCDecrypt(_ ct: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: 16)
        let outLen = ct.count + kCCBlockSizeAES128
        var out = Data(count: outLen)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            ct.withUnsafeBytes { c in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, 16, v.baseAddress,
                    c.baseAddress, ct.count,
                    o.baseAddress, outLen, &moved
                )
            }}}
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    private func sqliteScalar(db: String, query: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, query]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return out?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

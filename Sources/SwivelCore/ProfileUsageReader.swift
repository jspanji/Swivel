import Foundation
import os.log

/// One slice of Claude's live rate-limit state, recovered from the
/// Chromium LocalStorage that Claude Desktop persists its React Query
/// cache into. **Swivel never makes a network request for this data.**
/// Claude.app writes this object to disk whenever it refetches the
/// `current_account` query; we read the file back.
///
/// There are three meaningful states to represent:
///
/// 1. **No snapshot at all** (`read` returns nil) — we couldn't find
///    Claude's cache, or it doesn't contain `current_account`. We have
///    no signal either way.
///
/// 2. **Healthy** (`status == .ok`, detail fields nil) — Claude has a
///    fresh `current_account` cache but it contains no `messageLimits`
///    object. The server omits that object when the user is comfortably
///    below every rate-limit window, so its absence is an affirmative
///    "nothing to worry about", not missing data.
///
/// 3. **Warning** (`status == .approachingLimit` / `.limitReached`,
///    detail fields populated) — Claude is reporting active rate-limit
///    pressure. We surface the full picture: utilization, remaining
///    messages, reset time.
///
/// Schema reference (Claude Desktop ≥ 1.1.x):
///
///   account.settings.messageLimits[<org-uuid>] = {
///     "type": "ok" | "approaching_limit" | "limit_reached",
///     "resetsAt": <unix-seconds>,
///     "remaining": <int>,
///     "windows": { "5h": { "utilization": 0.0–1.0, "resets_at": ... } },
///     "representativeClaim": "five_hour" | "seven_day" | ...,
///     "overageInUse": false
///   }
///
/// If Anthropic renames any of these keys in a future release, `read`
/// returns nil and the menu falls back silently — the rest of Swivel
/// is unaffected.
struct UsageSnapshot {
    enum Status: String {
        case ok
        case approachingLimit = "approaching_limit"
        case limitReached = "limit_reached"
        case unknown
    }

    let status: Status
    let dataUpdatedAt: Date        // when Claude last refetched `current_account`
    let rateLimitTier: String?     // e.g. "default_claude_max_5x"

    // Populated only when `status != .ok` (i.e. Claude returned a
    // `messageLimits` object). In the healthy case these are nil.
    let utilization: Double?       // 0.0–1.0
    let remaining: Int?
    let resetsAt: Date?
    let window: String?            // "5h", "7d", …
    let overageInUse: Bool
}

/// Parses Claude Desktop's LocalStorage LevelDB for the usage snapshot.
///
/// All heavy lifting is a pure function of `(claudeDir URL) -> UsageSnapshot?`.
/// Results are cached per path+mtime so repeated menu opens don't re-parse
/// a ~1MB blob on every click.
enum ProfileUsageReader {
    private static let log = Logger(subsystem: "com.swivel.app", category: "ProfileUsageReader")

    /// Key for the React Query persisted cache inside Chromium LocalStorage.
    /// Format: `_<origin>\x00\x01<key-name>`. Bytes, not a Swift string, so
    /// the NUL isn't mishandled.
    private static let targetKey: Data = {
        var d = Data()
        d.append(UInt8(ascii: "_"))
        d.append(contentsOf: Array("https://claude.ai".utf8))
        d.append(0x00)
        d.append(0x01)
        d.append(contentsOf: Array("react-query-cache-ls".utf8))
        return d
    }()

    // MARK: - Caching

    private struct CacheKey: Hashable {
        let path: String
        let mtime: Date
    }
    private static var cache: [CacheKey: UsageSnapshot?] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.swivel.usage.cache")

    /// Read usage from `claudeDir` — which must be a directory that
    /// contains `Local Storage/leveldb/`. Pass the live
    /// `~/Library/Application Support/Claude` for fresh data, or a
    /// snapshot path for inactive profiles.
    static func read(claudeDir: URL) -> UsageSnapshot? {
        let leveldbDir = claudeDir
            .appendingPathComponent("Local Storage")
            .appendingPathComponent("leveldb")

        let fm = FileManager.default
        guard fm.fileExists(atPath: leveldbDir.path) else { return nil }

        // Cache key: most-recently-modified file in the leveldb dir.
        // If nothing in there changed, the last parse is still valid.
        let newest = latestMtime(in: leveldbDir) ?? Date.distantPast
        let key = CacheKey(path: leveldbDir.path, mtime: newest)
        if let cached = cacheQueue.sync(execute: { cache[key] }) {
            return cached
        }

        let parsed = parse(leveldbDir: leveldbDir)
        cacheQueue.sync {
            // Evict any older cache entries for the same path so the dict
            // doesn't grow unbounded as the DB gets rewritten.
            for k in cache.keys where k.path == key.path && k.mtime < key.mtime {
                cache.removeValue(forKey: k)
            }
            cache[key] = parsed
        }
        return parsed
    }

    private static func latestMtime(in dir: URL) -> Date? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var newest: Date?
        for u in entries {
            if let m = try? u.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate {
                if newest == nil || m > newest! { newest = m }
            }
        }
        return newest
    }

    // MARK: - Top-level parse

    private static func parse(leveldbDir: URL) -> UsageSnapshot? {
        guard let rawValue = latestReactQueryCacheValue(in: leveldbDir) else {
            log.info("no react-query-cache-ls value at \(leveldbDir.path, privacy: .public)")
            return nil
        }
        guard let jsonData = decodeChromiumLocalStorageValue(rawValue) else {
            log.error("failed to decode LocalStorage value")
            return nil
        }
        guard let cache = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            log.error("failed to parse React Query cache JSON")
            return nil
        }
        return extract(from: cache)
    }

    // MARK: - LevelDB .log parsing
    //
    // Chromium's LocalStorage writes to `*.log` files first; compaction
    // migrates entries to `*.ldb` (SSTable) later. We fully parse .log
    // because that's where the latest values live. For .ldb we fall
    // back to a byte-level scan for the React Query signature — good
    // enough to recover data after compaction, without implementing
    // the full SSTable block format.

    private static func latestReactQueryCacheValue(in dir: URL) -> Data? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let logs = entries.filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ldbs = entries.filter { $0.pathExtension == "ldb" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var latest: Data?
        for file in logs {
            guard let ops = try? parseLogFile(file) else { continue }
            // Later PUTs override earlier ones — keep iterating and
            // hold onto the last match rather than breaking early.
            for op in ops {
                if case .put(let key, let val) = op, key == targetKey {
                    latest = val
                }
            }
        }

        if latest == nil {
            // Compacted. Scan .ldb files for the UTF-16LE React Query
            // signature as a last resort.
            for file in ldbs {
                if let v = scanSSTableForReactQueryCache(file: file) {
                    latest = v
                }
            }
        }

        return latest
    }

    private enum LogOp {
        case put(key: Data, value: Data)
        case del(key: Data)
    }

    private static func parseLogFile(_ url: URL) throws -> [LogOp] {
        let raw = try Data(contentsOf: url)
        let bytes = [UInt8](raw)
        let blockSize = 32768
        let headerSize = 7

        var batches: [Data] = []
        var currentBatch = Data()

        var blockStart = 0
        while blockStart < bytes.count {
            let blockEnd = min(blockStart + blockSize, bytes.count)
            var pos = blockStart
            while pos + headerSize < blockEnd {
                // checksum(4) + length(2 LE) + type(1)
                let length = Int(bytes[pos + 4]) | (Int(bytes[pos + 5]) << 8)
                let typ = bytes[pos + 6]
                if length == 0 && typ == 0 { break }   // block trailer (zeros)
                let payloadStart = pos + headerSize
                let payloadEnd = payloadStart + length
                if payloadEnd > blockEnd { break }
                let payload = Data(bytes[payloadStart..<payloadEnd])

                switch typ {
                case 1:   // FULL
                    batches.append(payload)
                    currentBatch = Data()
                case 2:   // FIRST
                    currentBatch = payload
                case 3:   // MIDDLE
                    currentBatch.append(payload)
                case 4:   // LAST
                    currentBatch.append(payload)
                    batches.append(currentBatch)
                    currentBatch = Data()
                default:
                    break
                }
                pos = payloadEnd
            }
            blockStart = blockEnd
        }

        var ops: [LogOp] = []
        for batch in batches {
            ops.append(contentsOf: parseBatch(batch))
        }
        return ops
    }

    /// LevelDB batch format: seq(8 LE) + count(4 LE) + ops.
    /// Each op: type(1) + key_varint + key_bytes + [value_varint + value_bytes].
    private static func parseBatch(_ batch: Data) -> [LogOp] {
        let bytes = [UInt8](batch)
        guard bytes.count >= 12 else { return [] }
        let count = Int(bytes[8]) | (Int(bytes[9]) << 8) | (Int(bytes[10]) << 16) | (Int(bytes[11]) << 24)

        var pos = 12
        var ops: [LogOp] = []
        for _ in 0..<count {
            guard pos < bytes.count else { break }
            let typ = bytes[pos]
            pos += 1
            guard let (klen, afterK) = readVarint(bytes, at: pos) else { break }
            pos = afterK
            guard pos + klen <= bytes.count else { break }
            let key = Data(bytes[pos..<pos + klen])
            pos += klen

            if typ == 1 {    // kTypeValue
                guard let (vlen, afterV) = readVarint(bytes, at: pos) else { break }
                pos = afterV
                guard pos + vlen <= bytes.count else { break }
                let val = Data(bytes[pos..<pos + vlen])
                pos += vlen
                ops.append(.put(key: key, value: val))
            } else {
                ops.append(.del(key: key))
            }
        }
        return ops
    }

    private static func readVarint(_ bytes: [UInt8], at start: Int) -> (Int, Int)? {
        var result = 0
        var shift = 0
        var pos = start
        while pos < bytes.count {
            let b = Int(bytes[pos])
            pos += 1
            result |= (b & 0x7f) << shift
            if (b & 0x80) == 0 { return (result, pos) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    // MARK: - SSTable (.ldb) fallback scan
    //
    // Rather than implement the full LevelDB SSTable block format, we
    // look for the UTF-16LE signature of the React Query JSON inside
    // the raw file bytes. This works because the JSON is stored as a
    // large UTF-16LE run, and SSTable blocks don't fragment it badly
    // (values up to several MB stay in one block for us). Not
    // bulletproof, but a reasonable recovery path when the .log has
    // been fully compacted.

    private static let utf16Marker: [UInt8] = {
        let s = "{\"buster\":\"conversations_v2\""
        var out: [UInt8] = []
        for u in s.utf16 {
            out.append(UInt8(u & 0xff))
            out.append(UInt8((u >> 8) & 0xff))
        }
        return out
    }()

    private static func scanSSTableForReactQueryCache(file: URL) -> Data? {
        guard let raw = try? Data(contentsOf: file) else { return nil }
        let bytes = [UInt8](raw)
        guard let start = findSubsequence(utf16Marker, in: bytes) else { return nil }
        var end = start
        while end + 1 < bytes.count {
            let lo = bytes[end], hi = bytes[end + 1]
            let asciiOK = hi == 0 && (lo == 0x09 || lo == 0x0a || lo == 0x0d || (lo >= 0x20 && lo < 0x7f))
            let bmpOK = hi > 0 && hi < 0x08
            let puncOK = hi == 0x20 || hi == 0x21
            if asciiOK || bmpOK || puncOK {
                end += 2
            } else {
                break
            }
        }
        // Return with a leading \x00 so the downstream decoder treats
        // this as UTF-16LE, matching Chromium's LocalStorage format.
        var out = Data([0x00])
        out.append(Data(bytes[start..<end]))
        return out
    }

    private static func findSubsequence(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count, !needle.isEmpty else { return nil }
        let last = haystack.count - needle.count
        outer: for i in 0...last {
            for j in 0..<needle.count {
                if haystack[i + j] != needle[j] { continue outer }
            }
            return i
        }
        return nil
    }

    // MARK: - Chromium LocalStorage value decoding
    //
    // Format: 1-byte tag + payload.
    //   0x00 → UTF-16LE
    //   0x01 → UTF-8
    //   anything else → best-effort UTF-16LE (seen in some build variants)

    private static func decodeChromiumLocalStorageValue(_ data: Data) -> Data? {
        guard let tag = data.first else { return nil }
        let body = data.dropFirst()

        switch tag {
        case 0x00:
            guard let s = String(data: body, encoding: .utf16LittleEndian) else { return nil }
            return s.data(using: .utf8)
        case 0x01:
            return Data(body)
        default:
            if let s = String(data: data, encoding: .utf16LittleEndian) {
                return s.data(using: .utf8)
            }
            return nil
        }
    }

    // MARK: - Extract usage snapshot from parsed JSON

    private static func extract(from cache: [String: Any]) -> UsageSnapshot? {
        let client = cache["clientState"] as? [String: Any]
        let queries = client?["queries"] as? [[String: Any]] ?? []

        for q in queries {
            let qh = q["queryHash"] as? String ?? ""
            guard qh.contains("current_account") else { continue }

            let state = q["state"] as? [String: Any]
            let dataUpdatedAtMs = (state?["dataUpdatedAt"] as? Double) ?? 0
            let dataUpdatedAt = Date(timeIntervalSince1970: dataUpdatedAtMs / 1000)
            let root = state?["data"]
            let tier = findFirst(key: "rate_limit_tier", in: root) as? String

            // Helper for the "all clear" branch. Claude represents
            // healthy in two observed variants:
            //   1. `messageLimits` absent entirely (older clients)
            //   2. `messageLimits[<org>] = {"type": "within_limit", ...}`
            //      with no detail fields (newer clients, as of April 2026)
            // We treat both the same: return a snapshot with status
            // `.ok` and nil detail fields. The UI renders this as the
            // small green "all fine" checkmark.
            func healthySnapshot(overage: Bool = false) -> UsageSnapshot {
                UsageSnapshot(
                    status: .ok,
                    dataUpdatedAt: dataUpdatedAt,
                    rateLimitTier: tier,
                    utilization: nil,
                    remaining: nil,
                    resetsAt: nil,
                    window: nil,
                    overageInUse: overage
                )
            }

            // Variant 1: messageLimits missing entirely.
            guard let ml = findFirst(key: "messageLimits", in: root) as? [String: Any],
                  !ml.isEmpty
            else {
                return healthySnapshot()
            }

            // `ml` is keyed by org UUID. Pick the worst status across
            // memberships. Only `approaching_limit` and `limit_reached`
            // are considered warnings; everything else (including
            // `within_limit` and any future "all-clear" status names)
            // is healthy.
            let snapshots = ml.values.compactMap { $0 as? [String: Any] }
            let warnings = snapshots.filter { s in
                let t = (s["type"] as? String) ?? ""
                return t == "approaching_limit" || t == "limit_reached"
            }

            // Variant 2: entries exist but none is a warning → healthy.
            // Preserve overage flag since it's useful even in healthy state.
            guard let snap = warnings.max(by: {
                (($0["resetsAt"] as? Double) ?? 0) < (($1["resetsAt"] as? Double) ?? 0)
            }) else {
                let overage = snapshots.contains { ($0["overageInUse"] as? Bool) == true }
                return healthySnapshot(overage: overage)
            }

            let rep = (snap["representativeClaim"] as? String) ?? "five_hour"
            let windowLabel = normalizeWindow(rep)

            let windows = snap["windows"] as? [String: Any] ?? [:]
            let windowDict = (windows[windowLabel] as? [String: Any])
                ?? (windows.values.first as? [String: Any])
                ?? [:]

            let utilization = (windowDict["utilization"] as? Double) ?? 0
            let remaining = snap["remaining"] as? Int
            let resetsRaw = (windowDict["resets_at"] as? Double)
                ?? (snap["resetsAt"] as? Double)
                ?? 0

            let statusStr = (windowDict["status"] as? String)
                ?? (snap["type"] as? String)
                ?? "unknown"
            let status = UsageSnapshot.Status(rawValue: statusStr) ?? .unknown
            let overage = (snap["overageInUse"] as? Bool) ?? false

            return UsageSnapshot(
                status: status,
                dataUpdatedAt: dataUpdatedAt,
                rateLimitTier: tier,
                utilization: utilization,
                remaining: remaining,
                resetsAt: Date(timeIntervalSince1970: resetsRaw),
                window: windowLabel,
                overageInUse: overage
            )
        }

        return nil
    }

    private static func normalizeWindow(_ s: String) -> String {
        switch s {
        case "five_hour": return "5h"
        case "seven_day", "week", "weekly": return "7d"
        case "thirty_day", "month", "monthly": return "30d"
        default: return s
        }
    }

    /// Recursive first-match search for a key anywhere in a nested
    /// `[String: Any] / [Any]` JSON tree. Used because Claude's client
    /// sometimes wraps `messageLimits` under `account.settings`, under
    /// `account` directly, or at the top level depending on the
    /// endpoint version. Cheap — the structures are small.
    private static func findFirst(key target: String, in obj: Any?) -> Any? {
        if let dict = obj as? [String: Any] {
            if let v = dict[target] { return v }
            for v in dict.values {
                if let r = findFirst(key: target, in: v) { return r }
            }
        } else if let arr = obj as? [Any] {
            for v in arr {
                if let r = findFirst(key: target, in: v) { return r }
            }
        }
        return nil
    }
}

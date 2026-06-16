import Foundation

/// Coordinates per-account usage so the view model doesn't touch the fetch
/// mechanism. Two sources:
///   - **local**: `ProfileUsageReader` — cheap disk read of Claude's cache.
///   - **live** (opt-in): `LiveUsageClient` — authenticated claude.ai fetch.
///
/// Responsibilities the view model used to carry inline:
///   - **Parallel fetch.** Per-account live requests run concurrently rather
///     than serially, so N accounts cost ~one round-trip instead of N.
///   - **One keychain read** for the whole batch, off the main thread.
///   - **Single-flight.** Overlapping refresh triggers (status poll, widget
///     timer, popover open, switches) coalesce: if a load is running, the
///     newest request is held and run once on completion instead of stacking
///     duplicate network work.
final class UsageService {
    struct AccountUsage {
        let local: UsageSnapshot?
        let live: LiveUsage?
    }

    /// Owns the live client (and therefore its caches) — no global static
    /// state, and a test can use a fresh instance.
    private let liveClient = LiveUsageClient()
    private let queue = DispatchQueue(
        label: "com.swivel.usage", qos: .utility, attributes: .concurrent
    )

    // Single-flight bookkeeping — touched on the main thread only.
    private var loading = false
    private var pending: (() -> Void)?

    /// Load usage for `accounts` (ordered name + Claude dir). `wantLive`
    /// gates the network entirely. `completion` runs on the main thread with
    /// a name→usage map.
    func load(
        accounts: [(name: String, dir: URL?)],
        wantLive: Bool,
        completion: @escaping ([String: AccountUsage]) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let work: () -> Void = { [weak self] in
            self?.run(accounts: accounts, wantLive: wantLive, completion: completion)
        }
        if loading {
            pending = work        // coalesce — newest wins, runs after current
            return
        }
        loading = true
        work()
    }

    private func run(
        accounts: [(name: String, dir: URL?)],
        wantLive: Bool,
        completion: @escaping ([String: AccountUsage]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            // One keychain read for the batch, on a background thread.
            let key = wantLive ? try? KeychainHelper.readSafeStorageKey() : nil

            var results = [String: AccountUsage](minimumCapacity: accounts.count)
            let lock = NSLock()
            let group = DispatchGroup()

            for acct in accounts {
                group.enter()
                self.queue.async {
                    let local = acct.dir.flatMap { ProfileUsageReader.read(claudeDir: $0) }
                    let live: LiveUsage? = key.flatMap { k in
                        acct.dir.flatMap { self.liveClient.fetch(claudeDir: $0, safeStorageKey: k) }
                    }
                    lock.lock()
                    results[acct.name] = AccountUsage(local: local, live: live)
                    lock.unlock()
                    group.leave()
                }
            }

            group.notify(queue: .main) { [weak self] in
                completion(results)
                guard let self = self else { return }
                self.loading = false
                if let next = self.pending {
                    self.pending = nil
                    self.loading = true
                    next()
                }
            }
        }
    }
}

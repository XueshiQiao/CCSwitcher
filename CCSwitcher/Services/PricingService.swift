import Foundation

private let log = FileLog("Pricing")

/// Tiered model pricing in dollars-per-token, matching the shape of the
/// LiteLLM `model_prices_and_context_window.json` entries we care about.
///
/// 200k tier: Anthropic charges roughly double per token once a request's
/// input exceeds 200,000 tokens. LiteLLM encodes this as the
/// `*_above_200k_tokens` family of fields.
///
/// Fast multiplier: lives under `provider_specific_entry.fast` for the
/// models that support it. Applied to the entire base cost when
/// `usage.speed == "fast"`. Most rows in real data have `speed == "standard"`,
/// so the multiplier is rarely exercised — but it's a real billing line.
struct LiteLLMModelPricing: Sendable {
    let inputPerToken: Double
    let outputPerToken: Double
    let cacheCreatePerToken: Double
    /// 1-hour-TTL cache-write rate (2x base input). See `LiteLLMEntry.toPricing`.
    let cacheCreate1hPerToken: Double?
    let cacheReadPerToken: Double
    let inputAbove200k: Double?
    let outputAbove200k: Double?
    let cacheCreateAbove200k: Double?
    let cacheReadAbove200k: Double?
    let fastMultiplier: Double?

    func cost(input: Int, output: Int, cacheCreate: Int, cacheCreate1h: Int, cacheRead: Int, isFast: Bool) -> Double {
        // Cache-creation cost: 1-hour-TTL writes (cacheCreate1h) bill at the higher
        // 1h rate; the remainder stays at the 5-minute rate, which carries the 200k
        // long-context tier when the model defines one. No first-party Claude Code
        // model defines BOTH a 1h rate and a 200k tier, so this split is exact for
        // every model CCSwitcher ingests (bare ids from ~/.claude/projects). The
        // combined 1h+200k rate a few Bedrock/legacy ids publish is not modeled —
        // those ids never appear here. `min` guards a malformed cw1h > cw.
        let cacheCreateCost: Double
        if let r1h = cacheCreate1hPerToken, cacheCreate1h > 0 {
            let oneHour = min(cacheCreate1h, cacheCreate)
            cacheCreateCost = Self.tiered(tokens: cacheCreate - oneHour, rate: cacheCreatePerToken, hi: cacheCreateAbove200k)
                            + Self.tiered(tokens: oneHour, rate: r1h, hi: cacheCreateAbove200k)
        } else {
            cacheCreateCost = Self.tiered(tokens: cacheCreate, rate: cacheCreatePerToken, hi: cacheCreateAbove200k)
        }
        let base = Self.tiered(tokens: input, rate: inputPerToken, hi: inputAbove200k)
                 + Self.tiered(tokens: output, rate: outputPerToken, hi: outputAbove200k)
                 + cacheCreateCost
                 + Self.tiered(tokens: cacheRead, rate: cacheReadPerToken, hi: cacheReadAbove200k)
        let mult = isFast ? (fastMultiplier ?? 1.0) : 1.0
        return base * mult
    }

    private static func tiered(tokens: Int, rate: Double, hi: Double?) -> Double {
        let n = Double(tokens)
        guard let hi, hi > 0, tokens > 200_000 else { return n * rate }
        return 200_000 * rate + (n - 200_000) * hi
    }
}

/// Source of the currently-loaded pricing table. Surfaced in logs and in
/// the cache envelope's `pricing` block so divergent answers can be traced
/// back to which snapshot was used.
enum PricingSource: Sendable {
    case bundle(commit: String)         // litellm-pricing.json in the app bundle
    case fresh(fetchedAt: Date)         // ~/Library/Application Support/CCSwitcher/litellm-pricing-fresh.json

    var marker: String {
        switch self {
        case .bundle(let commit): return "bundle:\(commit)"
        case .fresh(let date):
            let f = ISO8601DateFormatter()
            return "fresh:\(f.string(from: date))"
        }
    }
}

/// Loads model pricing from the bundled LiteLLM snapshot, optionally
/// refreshed by a background fetch (24h TTL). Thread-safe via an actor;
/// callers should resolve once at refresh time and cache the result for
/// the duration of one parse pass.
actor PricingService {
    static let shared = PricingService()

    private struct LiteLLMEnvelope: Decodable {
        struct Meta: Decodable {
            let source_commit: String?
            let fetched_at: String?
        }
        let _meta: Meta?
        let models: [String: LiteLLMEntry]
    }

    private struct LiteLLMEntry: Decodable {
        let input_cost_per_token: Double?
        let output_cost_per_token: Double?
        let cache_creation_input_token_cost: Double?
        let cache_read_input_token_cost: Double?
        let input_cost_per_token_above_200k_tokens: Double?
        let output_cost_per_token_above_200k_tokens: Double?
        let cache_creation_input_token_cost_above_200k_tokens: Double?
        let cache_read_input_token_cost_above_200k_tokens: Double?
        let cache_creation_input_token_cost_above_1hr: Double?
        let provider_specific_entry: ProviderEntry?

        struct ProviderEntry: Decodable {
            let fast: Double?
        }

        func toPricing() -> LiteLLMModelPricing? {
            let input  = input_cost_per_token ?? 0
            let output = output_cost_per_token ?? 0
            let cw     = cache_creation_input_token_cost ?? 0
            let cr     = cache_read_input_token_cost ?? 0
            // LiteLLM contains metadata-only rows with no pricing — skip those.
            if input == 0 && output == 0 && cw == 0 && cr == 0 { return nil }
            // 1-hour cache writes bill at 2x base input (the 5-minute default is
            // 1.25x). LiteLLM publishes this as *_above_1hr for some models but
            // omits it for others (e.g. claude-sonnet-4-6); ccusage applies the
            // 2x-input rule universally, so fall back to it when absent.
            let cw1h: Double? = cache_creation_input_token_cost_above_1hr ?? (input > 0 ? input * 2 : nil)
            return LiteLLMModelPricing(
                inputPerToken: input, outputPerToken: output,
                cacheCreatePerToken: cw, cacheCreate1hPerToken: cw1h, cacheReadPerToken: cr,
                inputAbove200k: input_cost_per_token_above_200k_tokens,
                outputAbove200k: output_cost_per_token_above_200k_tokens,
                cacheCreateAbove200k: cache_creation_input_token_cost_above_200k_tokens,
                cacheReadAbove200k: cache_read_input_token_cost_above_200k_tokens,
                fastMultiplier: provider_specific_entry?.fast
            )
        }
    }

    private var pricing: [String: LiteLLMModelPricing] = [:]
    private var source: PricingSource = .bundle(commit: "unknown")
    private var loaded = false
    /// mtime of the fresh file currently held in memory, or nil when the
    /// in-memory table came from the bundle. Used by `reloadIfFreshChanged()`
    /// to detect when a background download has produced a newer snapshot.
    private var loadedFreshMtime: Date?
    /// Wall-clock of the last network revalidation attempt, for throttling.
    private var lastNetworkCheck: Date?

    private static let freshURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("litellm-pricing-fresh.json")
    }()
    /// Sidecar next to the fresh JSON holding the last ETag and the time we last
    /// confirmed (via 200 or 304) that the cached file is current. Kept separate
    /// from the JSON so a 304 re-stamp doesn't change the JSON's mtime — that
    /// mtime is the "content actually changed" signal `reloadIfFreshChanged()`
    /// relies on.
    private static let metaURL: URL = freshURL
        .deletingLastPathComponent()
        .appendingPathComponent("litellm-pricing-fresh.meta.json")
    /// How long a downloaded snapshot stays trusted over the bundle without a
    /// successful revalidation. While the app runs we revalidate every refresh
    /// cycle via a cheap conditional GET, so this only bites after a long
    /// offline stretch — at which point we fall back to the bundled snapshot.
    private static let freshValiditySeconds: TimeInterval = 30 * 24 * 60 * 60
    /// Floor between network revalidations; guards against manual-refresh
    /// storms. The CDN caches for 5 min, so sub-minute rechecks see nothing new.
    private static let minCheckInterval: TimeInterval = 60
    /// A usable LiteLLM payload yields dozens of Claude pricing rows (~44 at
    /// time of writing). Anything below this floor means the bytes parsed as
    /// JSON but aren't the pricing table — reject rather than trust them.
    private static let minClaudeModels = 10
    private static let liteLLMURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// Loads pricing if not already loaded. Preference order:
    ///   1. fresh file on disk, if last revalidated within the validity window
    ///   2. bundled snapshot
    /// Bundle is the fallback path and is guaranteed present (committed to the repo).
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true

        // Try fresh first.
        if let fresh = loadFresh() {
            pricing = fresh.models
            source = .fresh(fetchedAt: fresh.fetchedAt)
            loadedFreshMtime = fresh.fetchedAt
            log.info("loaded \(pricing.count) models from fresh (\(fresh.fetchedAt))")
            return
        }

        // Fall back to bundled snapshot.
        if let bundled = loadBundled() {
            pricing = bundled.models
            source = .bundle(commit: bundled.commit)
            log.info("loaded \(pricing.count) models from bundle (commit \(bundled.commit))")
            return
        }

        log.error("no pricing source available — cost calc will return 0")
    }

    /// Hot-reload the in-memory pricing table if the background download has
    /// written a newer fresh snapshot since we last loaded. Without this, a
    /// long-running session (the menu bar app can run for weeks) stays pinned
    /// to the snapshot present at launch — so a model released mid-session
    /// (e.g. a new Opus) has no pricing entry and every one of its rows is
    /// valued at $0. Called from the periodic refresh cycle, so a fresh
    /// download takes effect within one cycle (~5 min) with no app restart.
    func reloadIfFreshChanged() {
        guard loaded else { ensureLoaded(); return }

        // The JSON file's mtime is the "content actually changed" signal: it
        // only advances on a real 200 download, never on a 304 re-stamp.
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: Self.freshURL.path),
              let mtime = attrs[.modificationDate] as? Date
        else { return }

        // Already serving this exact fresh snapshot? Nothing to do. (When the
        // current table is from the bundle, loadedFreshMtime is nil, so a
        // newly-appeared fresh file always triggers a load.)
        if let loadedAt = loadedFreshMtime, loadedAt == mtime {
            return
        }

        // loadFresh() enforces the validity window; a stale file won't load.
        guard let fresh = loadFresh() else { return }
        pricing = fresh.models
        source = .fresh(fetchedAt: fresh.fetchedAt)
        loadedFreshMtime = fresh.fetchedAt
        log.info("reloadIfFreshChanged: picked up newer fresh snapshot (\(fresh.fetchedAt)), \(pricing.count) models")
    }

    /// Resolve pricing for a model id. Tries exact match first, then common
    /// provider prefixes, then longest-prefix fuzzy match. Returns nil for
    /// `<synthetic>` and other models with no LiteLLM entry — callers
    /// should treat those as zero-cost.
    func pricing(for model: String) -> LiteLLMModelPricing? {
        if let exact = pricing[model] { return exact }
        for prefix in ["anthropic/", "anthropic."] {
            if let v = pricing[prefix + model] { return v }
        }
        // Fuzzy: longest prefix match in either direction. Handles dated
        // suffixes like "claude-sonnet-4-5-20250929" → "claude-sonnet-4-5".
        var best: (String, LiteLLMModelPricing)?
        for (k, v) in pricing {
            if (model.hasPrefix(k) || k.hasPrefix(model))
                && (best == nil || k.count > best!.0.count) {
                best = (k, v)
            }
        }
        return best?.1
    }

    /// Resolve prices for many models in a single actor hop. Batch callers
    /// should use this instead of awaiting `pricing(for:)` per row: it snapshots
    /// the table atomically, so a concurrent `reloadIfFreshChanged()` can't swap
    /// pricing partway through and mix old and new values into one result.
    func prices(for models: [String]) -> [String: LiteLLMModelPricing?] {
        var out: [String: LiteLLMModelPricing?] = [:]
        for m in models { out[m] = pricing(for: m) }
        return out
    }

    /// Snapshot of which source the cache is currently serving from.
    /// Used by SessionParseCacheV2 to stamp the cache envelope.
    func currentSource() -> PricingSource { source }

    /// Trigger a background revalidation of the LiteLLM pricing JSON. Returns
    /// immediately; the work is fire-and-forget. A freshly-downloaded snapshot
    /// is hot-loaded by `reloadIfFreshChanged()` on the same refresh cycle — no
    /// app restart needed.
    nonisolated func refreshInBackground() {
        Task.detached(priority: .background) {
            await self.conditionalRefresh()
        }
    }

    /// Conditional GET against LiteLLM. Sends `If-None-Match` with the last
    /// ETag, so an unchanged file comes back as a 0-byte 304 (no re-download).
    /// Called every refresh cycle; a sub-minute throttle guards against
    /// manual-refresh storms.
    ///   304 → re-stamp `verifiedAt` (keeps the cache trusted) and stop.
    ///   200 → validate, overwrite the JSON, record the new ETag. The JSON
    ///         mtime changes, which is what triggers the hot-reload.
    private func conditionalRefresh() async {
        if let last = lastNetworkCheck, Date().timeIntervalSince(last) < Self.minCheckInterval {
            return
        }
        lastNetworkCheck = Date()

        var request = URLRequest(url: Self.liteLLMURL)
        // Drive revalidation with our own ETag rather than URLSession's cache.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = loadMeta()?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.warning("conditionalRefresh: non-HTTP response")
                return
            }
            let now = Date().timeIntervalSince1970
            switch http.statusCode {
            case 304:
                // Unchanged. Re-stamp so the on-disk cache stays trusted over
                // the bundle without re-downloading; keep the existing ETag.
                saveMeta(etag: loadMeta()?.etag, verifiedAt: now)
                log.debug("conditionalRefresh: 304 not-modified, re-stamped verifiedAt")
            case 200:
                // Require a usable pricing table, not just valid JSON, before
                // replacing the cache — a wrong-schema 200 must not zero prices.
                guard let models = Self.claudeModels(from: data), models.count >= Self.minClaudeModels else {
                    log.warning("conditionalRefresh: 200 body not a usable pricing table (claude rows=\(Self.claudeModels(from: data)?.count ?? -1)), keeping previous cache")
                    return
                }
                try data.write(to: Self.freshURL, options: .atomic)
                let etag = http.value(forHTTPHeaderField: "ETag")
                saveMeta(etag: etag, verifiedAt: now)
                log.info("conditionalRefresh: 200 updated, wrote \(data.count) bytes, \(models.count) claude rows, etag=\(etag ?? "nil")")
            default:
                log.warning("conditionalRefresh: unexpected status \(http.statusCode)")
            }
        } catch {
            log.warning("conditionalRefresh: fetch failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Loaders

    private struct LoadedPricing {
        let models: [String: LiteLLMModelPricing]
    }
    private struct LoadedBundle {
        let models: [String: LiteLLMModelPricing]
        let commit: String
    }
    private struct LoadedFresh {
        let models: [String: LiteLLMModelPricing]
        let fetchedAt: Date
    }

    /// Sidecar persisted next to the fresh JSON. `verifiedAt` is updated on
    /// every successful revalidation (200 or 304); `etag` is the validator we
    /// send back as `If-None-Match`.
    private struct FreshMeta: Codable {
        let etag: String?
        let verifiedAt: Double   // unix seconds
    }

    private func loadMeta() -> FreshMeta? {
        guard let data = try? Data(contentsOf: Self.metaURL),
              let m = try? JSONDecoder().decode(FreshMeta.self, from: data) else { return nil }
        return m
    }

    private func saveMeta(etag: String?, verifiedAt: Double) {
        guard let data = try? JSONEncoder().encode(FreshMeta(etag: etag, verifiedAt: verifiedAt)) else { return }
        try? data.write(to: Self.metaURL, options: .atomic)
    }

    private func loadBundled() -> LoadedBundle? {
        guard let url = Bundle.main.url(forResource: "litellm-pricing", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let env = try? JSONDecoder().decode(LiteLLMEnvelope.self, from: data)
        else {
            log.warning("bundled pricing JSON not found or unparseable")
            return nil
        }
        let models = env.models.compactMapValues { $0.toPricing() }
        return LoadedBundle(models: models, commit: env._meta?.source_commit ?? "unknown")
    }

    private func loadFresh() -> LoadedFresh? {
        let path = Self.freshURL.path
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        // Trust window keys off the sidecar's verifiedAt (re-stamped on every
        // 200/304 revalidation), so a file unchanged-but-revalidated for weeks
        // stays valid. Pre-sidecar installs fall back to the file's mtime.
        let verifiedAt = loadMeta().map { Date(timeIntervalSince1970: $0.verifiedAt) } ?? mtime
        guard Date().timeIntervalSince(verifiedAt) < Self.freshValiditySeconds,
              let data = try? Data(contentsOf: Self.freshURL),
              let models = Self.claudeModels(from: data),
              models.count >= Self.minClaudeModels
        else {
            return nil
        }
        return LoadedFresh(models: models, fetchedAt: mtime)
    }

    /// Decode a raw LiteLLM payload (the on-disk/network shape, not our
    /// envelope) into Claude pricing rows — the same filter `fetch_litellm.sh`
    /// applies at build time. Returns nil when the bytes aren't the expected
    /// object-of-entries schema, so callers can reject a wrong-shape 200 body.
    private static func claudeModels(from data: Data) -> [String: LiteLLMModelPricing]? {
        guard let raw = try? JSONDecoder().decode([String: LiteLLMEntry].self, from: data) else { return nil }
        let claude = raw.filter { name, _ in
            name.hasPrefix("claude-")
                || name.hasPrefix("anthropic/claude-")
                || name.hasPrefix("anthropic.claude-")
        }
        return claude.compactMapValues { $0.toPricing() }
    }
}

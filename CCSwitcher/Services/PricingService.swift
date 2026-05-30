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
    let cacheReadPerToken: Double
    let inputAbove200k: Double?
    let outputAbove200k: Double?
    let cacheCreateAbove200k: Double?
    let cacheReadAbove200k: Double?
    let fastMultiplier: Double?

    func cost(input: Int, output: Int, cacheCreate: Int, cacheRead: Int, isFast: Bool) -> Double {
        let base = Self.tiered(tokens: input, rate: inputPerToken, hi: inputAbove200k)
                 + Self.tiered(tokens: output, rate: outputPerToken, hi: outputAbove200k)
                 + Self.tiered(tokens: cacheCreate, rate: cacheCreatePerToken, hi: cacheCreateAbove200k)
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
            return LiteLLMModelPricing(
                inputPerToken: input, outputPerToken: output,
                cacheCreatePerToken: cw, cacheReadPerToken: cr,
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

    private static let freshURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = appSupport.appendingPathComponent("CCSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("litellm-pricing-fresh.json")
    }()
    private static let freshTTLSeconds: TimeInterval = 24 * 60 * 60
    private static let liteLLMURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// Loads pricing if not already loaded. Preference order:
    ///   1. fresh file on disk, if mtime within TTL
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

        // A valid (within-TTL) fresh file must exist to consider reloading.
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: Self.freshURL.path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < Self.freshTTLSeconds
        else { return }

        // Already serving this exact fresh snapshot? Nothing to do. (When the
        // current table is from the bundle, loadedFreshMtime is nil, so a
        // newly-appeared fresh file always triggers a load.)
        if let loadedAt = loadedFreshMtime, loadedAt == mtime {
            return
        }

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

    /// Trigger a background refresh from LiteLLM. Idempotent; no-op if the
    /// fresh file is younger than TTL. Returns immediately; the refresh is
    /// fire-and-forget. The next app launch will pick up the new file.
    nonisolated func refreshInBackground() {
        Task.detached(priority: .background) {
            await self.refreshIfStale()
        }
    }

    private func refreshIfStale() async {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: Self.freshURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < Self.freshTTLSeconds {
            log.debug("refreshInBackground: fresh file still within TTL, skipping")
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: Self.liteLLMURL)
            // Validate parseable before writing.
            _ = try JSONSerialization.jsonObject(with: data)
            try data.write(to: Self.freshURL, options: .atomic)
            log.info("refreshInBackground: wrote \(data.count) bytes to \(Self.freshURL.lastPathComponent)")
        } catch {
            log.warning("refreshInBackground: fetch failed — \(error.localizedDescription)")
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
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < Self.freshTTLSeconds,
              let data = try? Data(contentsOf: Self.freshURL),
              let raw = try? JSONDecoder().decode([String: LiteLLMEntry].self, from: data)
        else {
            return nil
        }
        // Fresh file is the raw LiteLLM payload (not our envelope). Filter to
        // Claude rows the same way fetch_litellm.sh does at build time.
        let claude = raw.filter { name, _ in
            name.hasPrefix("claude-")
                || name.hasPrefix("anthropic/claude-")
                || name.hasPrefix("anthropic.claude-")
        }
        let models = claude.compactMapValues { $0.toPricing() }
        return LoadedFresh(models: models, fetchedAt: mtime)
    }
}

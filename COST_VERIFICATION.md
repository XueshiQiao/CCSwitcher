# Cost Calculation Verification

CCSwitcher computes today's API spend from the JSONL session logs in
`~/.claude/projects/`. The math has to stay aligned with [ccusage], the
canonical community tool — if our numbers drift from ccusage, users will
notice and lose trust in everything else in the menu bar.

This document describes how to verify alignment and what to do if it fails.

## The contract

For any window of recent days, the totals reported by our parser
(`CCSwitcher/Services/SessionParseCacheV2.swift` → `costSummary()`) must
match `npx ccusage@latest daily --since YYYYMMDD --json` exactly, on:

- `inputTokens`, `outputTokens`, `cacheCreationTokens`, `cacheReadTokens`
  for every `(date, model)` pair, AND
- `cost` per `(date, model)`, within $0.01 per row (float-rounding slack).

`<synthetic>` rows are filtered from the comparison — ccusage excludes
them from breakdowns; we display them as zero-token rows but never sum
them into anything visible.

## Required before every release

Run this before tagging a new app version:

```bash
Tools/verify_cost.sh 30
```

The script:

1. Runs `Tools/recalc_cost.swift` over the last 30 days of your local data.
2. Runs `npx -y ccusage@latest daily --since … --json` (always pulling the
   latest published ccusage, so you can't silently drift on a stale cache).
3. Compares every `(date, model)` row and every daily total.
4. Exits `0` if everything matches, `1` if not, `2` on setup failure.

**Required**: PASS before `git tag` / before invoking the `release` skill.
If it fails, **do not release.** Find and fix the divergence first.

## What "fails" means and how to react

`verify_cost.sh` fails on any of:

1. **A `(date, model)` key exists on one side but not the other.**
   Usually means we either dropped a row ccusage kept, or kept one
   ccusage filtered. Inspect `/tmp/ccswitcher-verify-cost/ours.json`
   vs `ccusage.json`, find the missing row, trace it back to JSONL.

2. **Token counts disagree.**
   Almost always a dedup-logic or file-ordering issue. ccusage's
   `(messageId, requestId)` dedup is sensitive to the order files are
   visited and the order of lines within them. See
   "Surprising things we learned" below.

3. **Cost disagrees but tokens match.**
   Pricing-table drift. Either ccusage changed its LiteLLM snapshot or
   we changed our pricing source. Check
   `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`
   for tier or per-token-cost changes; `/tmp/litellm-pricing.json` is
   our local cache.

### When ccusage changes its algorithm

This has happened: ccusage 18.0.11's published bundle uses "first-wins"
dedup, but the git HEAD source uses a "max-tokenTotal-wins" rule.
Whichever version is on npm becomes our target — `Tools/verify_cost.sh`
runs `npx -y ccusage@latest`, so it'll detect the change automatically.

Fix order when ccusage changes:

1. **Update `Tools/recalc_cost.swift` first** to mirror the new
   algorithm. Iterate until `verify_cost.sh` passes again.
2. **Then port the change into `CCSwitcher/Services/SessionParseCacheV2.swift`.**
3. Re-run `verify_cost.sh` and run the app to confirm the UI shows
   matching numbers.
4. Then release.

Never port to the app without going through `recalc_cost.swift` first —
that script is the single place where our algorithm is tested against
ccusage in isolation.

## What lives where

| Path | Purpose |
|---|---|
| `Tools/verify_cost.sh` | One-shot verification — what you run before releasing. |
| `Tools/recalc_cost.swift` | Standalone reparser that mirrors ccusage's algorithm. Single source of truth for "what's the right answer." |
| `CCSwitcher/Services/SessionParseCacheV2.swift` | The in-app version that the UI consumes. Must match the recalc script's outputs. |
| `CCSwitcher/Models/CostData.swift` → `ModelPricing` | App's pricing table. Should track LiteLLM. |
| `/tmp/litellm-pricing.json` | Cached LiteLLM pricing snapshot (auto-refreshed by `recalc_cost.swift` once per hour). |
| `/tmp/ccswitcher-verify-cost/` | Raw JSON outputs from the last verification run — keep around for debugging. |

## Surprising things we learned

These are the non-obvious facts the algorithm depends on. Future-you
will rediscover all of these the hard way if they aren't written down.

1. **`costUSD` in the JSONL is essentially dead.** Out of ~4,669 assistant
   rows in a recent 5-day window, exactly 1 had a `costUSD` field.
   Claude Code stopped writing it years ago. We compute cost from tokens.

2. **Pricing comes from LiteLLM, not Anthropic.** Anthropic doesn't
   publish a structured pricing JSON; LiteLLM's `model_prices_and_context_window.json`
   is the community standard. ccusage fetches it at runtime (with a
   build-time prefetched fallback). We do the same.

3. **Dedup is *global*, by `(message.id, requestId)`.** Not per-file.
   Across all `~/.claude/projects/` data, ~70 `requestIds` appear in
   multiple JSONL files (session resume/fork). Without global dedup
   they'd be summed twice. Rows missing either id are *not* deduped —
   they're all kept.

4. **Files must be visited in earliest-timestamp order.** ccusage sorts
   files by the oldest timestamp inside each file, not by filename.
   Because dedup is first-wins, file order changes the outcome when the
   same `(messageId, requestId)` straddles files.

5. **Within a file, dedup is also first-wins.** A streaming assistant
   message produces multiple rows with the same `(messageId, requestId)`
   and growing `output_tokens`. ccusage 18.0.11 keeps the **first** row
   (smallest), not the last (largest). The newer ccusage source has a
   `max-tokenTotal-wins` tiebreaker, but that hasn't shipped to npm.

6. **Subagent JSONLs live in `<project>/<sessionUUID>/subagents/` — two
   directories deeper than the parent session.** Their `requestId`s do
   NOT collide with the parent's (per-session intersection is zero on
   real data), so summing both is safe under global dedup.

7. **`<synthetic>` rows are real assistant rows with `model: "<synthetic>"`
   and zero tokens.** ccusage strips them from `modelBreakdowns` but
   still counts them in totals (zero contribution). We display them as
   visible zero-token rows in `recalc_cost.swift` output for debugging,
   and filter them in `verify_cost.sh` for comparison.

8. **LiteLLM pricing has a 200k context-window tier** for Opus/Sonnet —
   input/output/cache prices roughly double once a request crosses
   200k tokens. The fields are named `*_above_200k_tokens`. Easy to miss.

9. **There's also a "fast" speed multiplier** (`provider_specific_entry.fast`)
   that scales cost when `usage.speed == "fast"`. We've seen zero `fast`
   rows in real data so far, but the code path is wired up.

10. **ccusage installed via `npx -y ccusage@latest` and ccusage cloned
    from GitHub HEAD can disagree.** They're literally different
    algorithms. Always verify against the published version — that's
    what users compare us to.

[ccusage]: https://github.com/ryoppippi/ccusage

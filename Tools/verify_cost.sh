#!/usr/bin/env bash
# verify_cost.sh — Cross-check CCSwitcher's JSONL cost calculation against
# the latest ccusage release. Run before tagging a new app version.
#
# Exit codes:
#   0  → token + cost numbers match ccusage to the cent across the window
#   1  → mismatch (block the release; investigate Tools/recalc_cost.swift)
#   2  → setup error (missing swift, npx, jq, etc.)
#
# Usage:
#   Tools/verify_cost.sh              # default: 30 days
#   Tools/verify_cost.sh 7            # custom window
#   COST_DIFF_TOLERANCE=0.05 Tools/verify_cost.sh
#
# Environment:
#   COST_DIFF_TOLERANCE   per-row cost delta allowed (default 0.01 USD)

set -euo pipefail

DAYS="${1:-30}"
TOL="${COST_DIFF_TOLERANCE:-0.01}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="${TMPDIR:-/tmp}/ccswitcher-verify-cost"
mkdir -p "$TMP"

red()    { printf "\033[0;31m%s\033[0m\n" "$*"; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        red "verify_cost: missing required tool '$1' — install it and retry"
        exit 2
    fi
}
require swift
require npx
require python3
require jq
require date

# Compute --since in YYYYMMDD (ccusage's format). N-1 because ccusage's window is inclusive.
SINCE=$(date -v"-$((DAYS - 1))d" +%Y%m%d 2>/dev/null || date -d "$((DAYS - 1)) days ago" +%Y%m%d)

bold "[1/3] Running our reparser on the last $DAYS days..."
swift "$ROOT/Tools/recalc_cost.swift" --json --days "$DAYS" \
    > "$TMP/ours.json" 2> "$TMP/ours.log"
OUR_ROWS=$(jq '.rows | length' "$TMP/ours.json")
echo "  → $OUR_ROWS (date × model) rows written to $TMP/ours.json"

bold "[2/3] Running latest ccusage (npx -y ccusage@latest)..."
# Always pull latest published ccusage so we never silently drift on cached versions.
if ! npx -y ccusage@latest daily --since "$SINCE" --json \
    > "$TMP/ccusage.json" 2> "$TMP/ccusage.log"; then
    red "verify_cost: ccusage fetch/run failed. See $TMP/ccusage.log"
    yellow "Common causes: offline, npm registry blip, ccusage moved versions."
    exit 2
fi
CC_DAYS=$(jq '.daily | length' "$TMP/ccusage.json")
# The native-binary ccusage prints "ccusage 20.0.9"; older JS builds printed a
# bare "18.0.11". Take the last whitespace token so we always store just the
# number (the UI already prepends the word "ccusage").
CC_VERSION=$(npx -y ccusage@latest --version 2>/dev/null | tail -1 | awk '{print $NF}' || echo "?")
echo "  → ccusage $CC_VERSION, $CC_DAYS days written to $TMP/ccusage.json"

bold "[3/3] Diffing..."
python3 - "$TMP/ours.json" "$TMP/ccusage.json" "$TOL" <<'PY'
import json, sys, datetime
ours_path, theirs_path, tol = sys.argv[1], sys.argv[2], float(sys.argv[3])

# The current local day is still being written to ~/.claude/projects while this
# runs, so our reparser and a separately-invoked ccusage scan it at different
# instants and disagree by whatever was appended in between. That's a live-file
# race, not an algorithm difference — exclude today from the pass/fail gate (it
# still appears in the summary table below, flagged).
TODAY = datetime.date.today().isoformat()

ours = {(r['date'], r['model']): r for r in json.load(open(ours_path))['rows']
        # ccusage strips <synthetic>; Claude-only mirrors the theirs-side filter
        # so a stray non-Claude id (shouldn't occur from ~/.claude/projects) can't
        # show up as a one-sided "EXTRA in ours" mismatch.
        if r['model'] != '<synthetic>' and 'claude' in r['model']}
theirs = {}
for day in json.load(open(theirs_path))['daily']:
    # ccusage renamed the daily bucket key 'date' -> 'period' in 19.x/20.x.
    day_key = day.get('period') or day.get('date')
    for m in day['modelBreakdowns']:
        # Claude-only: ccusage 20.x became a multi-provider tracker (Codex/Kilo/
        # Kimi/OpenCode/...). CCSwitcher is a Claude account tool and only counts
        # Claude usage, so non-Claude models are out of scope for this diff.
        if 'claude' not in m['modelName']:
            continue
        theirs[(day_key, m['modelName'])] = {
            'input_tokens': m['inputTokens'],
            'output_tokens': m['outputTokens'],
            'cache_creation_tokens': m['cacheCreationTokens'],
            'cache_read_tokens': m['cacheReadTokens'],
            'cost_usd': m['cost'],
        }

# Exclude the in-progress current day from the comparison keys (still shown in
# the daily-totals table further down, which reads the unfiltered dicts).
ours_keys = {k for k in ours if k[0] != TODAY}
theirs_keys = {k for k in theirs if k[0] != TODAY}
mismatches = []

# Missing-key checks (asymmetric: a key only on one side is itself a mismatch)
for k in sorted(theirs_keys - ours_keys):
    mismatches.append((k, "MISSING in ours (only in ccusage)"))
for k in sorted(ours_keys - theirs_keys):
    mismatches.append((k, "EXTRA in ours (not in ccusage)"))

# Field-by-field for shared keys
for k in sorted(ours_keys & theirs_keys):
    o, t = ours[k], theirs[k]
    field_diffs = []
    for f in ('input_tokens', 'output_tokens', 'cache_creation_tokens', 'cache_read_tokens'):
        if o[f] != t[f]:
            field_diffs.append(f"{f}: ours={o[f]} ccusage={t[f]} delta={o[f]-t[f]:+d}")
    cd = o['cost_usd'] - t['cost_usd']
    if abs(cd) > tol:
        field_diffs.append(f"cost_usd: ours={o['cost_usd']:.4f} ccusage={t['cost_usd']:.4f} delta={cd:+.4f}")
    if field_diffs:
        mismatches.append((k, "; ".join(field_diffs)))

# Daily totals (excluding <synthetic>) for the summary table
def daily_totals(d):
    out = {}
    for (date, _), r in d.items():
        b = out.setdefault(date, {'in':0,'out':0,'cw':0,'cr':0,'cost':0.0})
        b['in']   += r['input_tokens']
        b['out']  += r['output_tokens']
        b['cw']   += r['cache_creation_tokens']
        b['cr']   += r['cache_read_tokens']
        b['cost'] += r['cost_usd']
    return out

ours_d = daily_totals(ours)
theirs_d = daily_totals(theirs)

print()
print(f"{'date':12} {'ours $':>12} {'ccusage $':>12} {'Δ':>10}")
print("-" * 50)
for date in sorted(set(ours_d) | set(theirs_d), reverse=True):
    o = ours_d.get(date, {'cost':0})
    t = theirs_d.get(date, {'cost':0})
    delta = o['cost'] - t['cost']
    marker = " " if abs(delta) <= tol else "*"
    print(f"{date:12} {o['cost']:>12.4f} {t['cost']:>12.4f} {delta:>+10.4f} {marker}")
print("-" * 50)
total_o = sum(b['cost'] for b in ours_d.values())
total_t = sum(b['cost'] for b in theirs_d.values())
print(f"{'TOTAL':12} {total_o:>12.4f} {total_t:>12.4f} {total_o - total_t:>+10.4f}")
print()

if mismatches:
    print(f"\n--- {len(mismatches)} MISMATCH(es) ---")
    for k, msg in mismatches[:50]:
        print(f"  {k}: {msg}")
    if len(mismatches) > 50:
        print(f"  ... (+{len(mismatches) - 50} more)")
    sys.exit(1)
else:
    print("All (date × model × {4 token types, cost}) match within tolerance.")
    sys.exit(0)
PY

EXIT=$?
if [ $EXIT -eq 0 ]; then
    # Stamp the verification result into a bundled resource so the Cost tab
    # can show "Verified against ccusage X on Y" without a runtime fetch.
    # Regenerated on every successful run, including pre-release.
    STAMP="$ROOT/CCSwitcher/Resources/verified-against.json"
    TODAY=$(date -u +"%Y-%m-%d")
    TOTAL=$(python3 -c "
import json, sys
d = json.load(open('$TMP/ours.json'))
total = sum(r['cost_usd'] for r in d['rows'] if r['model'] != '<synthetic>')
print(f'{total:.4f}')
")
    # Atomic write: temp file in same dir + rename, so Xcode resource copy
    # never sees a half-written file mid-build.
    python3 -c "
import json, os
out = {
    'ccusageVersion': '$CC_VERSION',
    'verifiedOn': '$TODAY',
    'windowDays': $DAYS,
    'totalDollars': float('$TOTAL'),
}
stamp = '$STAMP'
tmp = stamp + '.tmp'
with open(tmp, 'w') as f:
    json.dump(out, f, indent=2, sort_keys=True)
    f.write('\n')
os.replace(tmp, stamp)
print(f'[stamp] wrote {out}')
"
    echo "        → $STAMP"
    green "PASS — safe to release."
else
    red "FAIL — DO NOT RELEASE."
    yellow "Investigate: compare $TMP/ours.json against $TMP/ccusage.json"
    yellow "If ccusage changed its algorithm, update Tools/recalc_cost.swift first,"
    yellow "then port the change into CCSwitcher/Services/SessionParseCacheV2.swift."
fi
exit $EXIT

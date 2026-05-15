#!/usr/bin/env bash
# fetch_litellm.sh — Pull the latest LiteLLM model-pricing JSON, filter it
# down to Claude rows, and write the result into CCSwitcher/Resources/ so
# it bundles with the app.
#
# Run this before tagging a release. The result is committed to the repo
# so end-users never need to fetch over the network on first launch.
#
# Usage:
#   Tools/fetch_litellm.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DEST_DIR="$ROOT/CCSwitcher/Resources"
DEST="$DEST_DIR/litellm-pricing.json"
URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

mkdir -p "$DEST_DIR"

echo "[fetch] $URL"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP"

# Filter to Claude rows + capture the upstream commit hash for traceability.
# Provider prefixes covered: bare claude-*, anthropic.claude-* (Bedrock),
# anthropic/claude-* (Anthropic via LiteLLM router).
SOURCE_HASH=$(curl -fsSL "https://api.github.com/repos/BerriAI/litellm/commits?path=model_prices_and_context_window.json&per_page=1" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:12] if isinstance(d,list) and d else 'unknown')" 2>/dev/null || echo "unknown")
FETCHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 - "$TMP" "$DEST" "$SOURCE_HASH" "$FETCHED_AT" <<'PY'
import json, sys
src, dest, source_hash, fetched_at = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(src) as f:
    data = json.load(f)

def is_claude(name: str) -> bool:
    return (name.startswith('claude-')
            or name.startswith('anthropic.claude-')
            or name.startswith('anthropic/claude-'))

claude = {k: v for k, v in data.items() if is_claude(k)}

# Wrap in an envelope so consumers know the provenance.
wrapped = {
    '_meta': {
        'source': 'https://github.com/BerriAI/litellm',
        'source_commit': source_hash,
        'fetched_at': fetched_at,
        'model_count': len(claude),
    },
    'models': claude,
}

with open(dest, 'w') as f:
    json.dump(wrapped, f, indent=2, sort_keys=True)
    f.write('\n')

print(f"[wrote] {dest}")
print(f"  models: {len(claude)}")
print(f"  source_commit: {source_hash}")
print(f"  fetched_at: {fetched_at}")
PY

echo
echo "Next: commit CCSwitcher/Resources/litellm-pricing.json before tagging the release."

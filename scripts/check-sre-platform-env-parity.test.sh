#!/usr/bin/env bash
# Self-test the parity comparison while the first public contract is unavailable.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/sre-platform"
gate="$repo_root/scripts/check-sre-platform-env-parity.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Resolved from this script's repository root.
# shellcheck disable=SC1090
source "$gate"
missing_contract_is_bootstrap 0.0.0
if missing_contract_is_bootstrap 1.0.0; then
  echo "FAIL real release accepted a missing contract" >&2
  exit 1
fi
echo "PASS only bootstrap may omit the public contract"

render_chart_env "$chart" "$tmp/render.yaml"
grep -E '(^  [A-Z][A-Z0-9_]{2,}:)|(name: [A-Z][A-Z0-9_]{2,}$)' "$tmp/render.yaml" \
  | sed -E 's/.*name: //; s/^[[:space:]]*//; s/:.*$//' \
  | sort -u \
  | jq -Rn '[inputs | {env: .}]' >"$tmp/matching.json"

ENV_CONTRACT_FILE="$tmp/matching.json" bash "$gate" >/dev/null
echo "PASS matching contract"

jq 'map(select(.env != "DATABASE_URL"))' "$tmp/matching.json" >"$tmp/missing.json"
if ENV_CONTRACT_FILE="$tmp/missing.json" bash "$gate" >/dev/null 2>&1; then
  echo "FAIL missing chart key passed" >&2
  exit 1
fi
echo "PASS missing chart key fails"

jq '. + [{"env":"UNMIRRORED_TEST_KEY"}]' "$tmp/matching.json" >"$tmp/added.json"
if ENV_CONTRACT_FILE="$tmp/added.json" bash "$gate" >/dev/null 2>&1; then
  echo "FAIL unmirrored contract key passed" >&2
  exit 1
fi
echo "PASS unmirrored contract key fails"

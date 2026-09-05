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
chart_env_keys "$tmp/render.yaml" | jq -Rn '[inputs | {env: .}]' >"$tmp/matching.json"

ENV_CONTRACT_FILE="$tmp/matching.json" bash "$gate" >/dev/null
echo "PASS matching contract"

# The gate skips ignored chart keys before the orphan check, so adding
# DATABASE_URL to .env-contract-ignore would make the case below pass without
# ever reaching that branch. Assert the premise rather than assume it.
if grep -qxF DATABASE_URL "$chart/.env-contract-ignore"; then
  echo "FAIL DATABASE_URL is ignored, so the orphan case proves nothing" >&2
  exit 1
fi
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

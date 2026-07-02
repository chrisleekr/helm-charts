#!/usr/bin/env bash
#
# Self-test for check-env-parity.sh. Exercises the gate's comparison logic against
# a synthetic env-contract derived from the chart itself, so it needs no static
# fixture and stays valid as the chart evolves. This gives the gate CI coverage
# even during the bootstrap window, when the live contract at v<appVersion> 404s
# and the gate's own run short-circuits to SKIP.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
chart="$here/../charts/github-app"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
contract="$tmp/contract.json"
orphan="$tmp/orphan.json"
unmirrored="$tmp/unmirrored.json"

# Derive the chart's env keys exactly as the gate does, minus DOCKER_HOST (a
# chart-only infra var carried in .env-contract-ignore, not the contract). The
# result is a contract that should match the chart perfectly.
keys=$(grep -rhoE '(^[[:space:]]*[A-Z][A-Z0-9_]{2,}:)|(name: [A-Z][A-Z0-9_]{2,})' \
  "$chart/templates/configmap.yaml" \
  "$chart/templates/secret.yaml" \
  "$chart/templates/daemon-deployment.yaml" \
  | sed -E 's/name: //; s/[[:space:]:]//g' | sort -u | grep -vx DOCKER_HOST)
printf '%s\n' "$keys" | jq -R 'select(length > 0) | {env: ., group: "test", kind: "config"}' | jq -s . > "$contract"

fail=0

# Positive: contract matches the chart -> gate passes.
if ! ENV_CONTRACT_FILE="$contract" bash "$here/check-env-parity.sh" >/dev/null; then
  echo "FAIL: gate should pass when the contract matches the chart"
  fail=1
fi

# Negative (orphan): drop a real chart key from the contract -> the chart now
# references a key absent from the contract -> gate must fail (Direction 1).
jq 'map(select(.env != "GITHUB_APP_ID"))' "$contract" > "$orphan"
if ENV_CONTRACT_FILE="$orphan" bash "$here/check-env-parity.sh" >/dev/null 2>&1; then
  echo "FAIL: gate should fail on an orphan chart key"
  fail=1
fi

# Negative (unmirrored): add a contract key the chart does not surface and that is
# not in .env-contract-ignore -> gate must fail (Direction 2).
jq '. + [{env: "TOTALLY_NEW_VAR", group: "test", kind: "config"}]' "$contract" > "$unmirrored"
if ENV_CONTRACT_FILE="$unmirrored" bash "$here/check-env-parity.sh" >/dev/null 2>&1; then
  echo "FAIL: gate should fail on an unmirrored contract key"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "OK: check-env-parity self-test passed (positive + orphan + unmirrored)"
fi
exit "$fail"

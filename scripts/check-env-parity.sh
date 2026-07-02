#!/usr/bin/env bash
#
# Deterministic parity gate for the github-app chart's env surface.
#
# The chart's configmap.yaml + secret.yaml (plus the daemon Deployment's literal
# env) mirror github-app's src/config.ts. github-app publishes the authoritative
# list as env-contract.json at each release tag. This gate fails when the two
# drift, catching the case `helm template` cannot: a var that config.ts added but
# the chart never mirrored just does not render, so the template still succeeds.
#
#   Direction 1 (no orphans):     every chart-referenced env key exists in the contract.
#   Direction 2 (completeness):   every contract key is mirrored in the chart OR listed
#                                 in charts/github-app/.env-contract-ignore.
#
# .env-contract-ignore is a single allowlist covering BOTH directions: contract
# keys intentionally not mirrored (rely on app defaults), and chart-only infra
# vars that are not app config (e.g. DOCKER_HOST). One name per line; `#` comments.
#
# Contract source: env-contract.json at v<appVersion> on raw.githubusercontent,
# overridable via ENV_CONTRACT_FILE for local runs / CI fixtures. A 404 (the
# pinned appVersion predates env-contract.json) is a skip, not a failure, so the
# gate does not block chart PRs during the bootstrap window before the first
# github-app release that ships the contract.
set -euo pipefail

chart="charts/github-app"
appver=$(yq '.appVersion' "$chart/Chart.yaml" | tr -d '"')

contract_json=$(mktemp)
trap 'rm -f "$contract_json"' EXIT

if [ -n "${ENV_CONTRACT_FILE:-}" ]; then
  cp "$ENV_CONTRACT_FILE" "$contract_json"
else
  url="https://raw.githubusercontent.com/chrisleekr/github-app/v${appver}/env-contract.json"
  code=$(curl -sSL -o "$contract_json" -w '%{http_code}' "$url" || echo 000)
  if [ "$code" = "404" ]; then
    echo "SKIP: no env-contract.json at v${appver} (pre-contract release); parity gate not enforced"
    exit 0
  fi
  if [ "$code" != "200" ]; then
    echo "ERROR: fetching $url returned HTTP $code" >&2
    exit 1
  fi
fi

contract=$(jq -r '.[].env' "$contract_json" | sort -u)
# Chart-referenced env keys: `KEY:` map entries (configmap/secret data) plus
# `name: KEY` literal env entries (daemon Deployment). Both restricted to
# UPPER_SNAKE so templated/metadata `name:` values do not match.
chart_keys=$(grep -rhoE '(^[[:space:]]*[A-Z][A-Z0-9_]{2,}:)|(name: [A-Z][A-Z0-9_]{2,})' \
  "$chart/templates/configmap.yaml" \
  "$chart/templates/secret.yaml" \
  "$chart/templates/daemon-deployment.yaml" \
  | sed -E 's/name: //; s/[[:space:]:]//g' | sort -u)
ignore=""
if [ -f "$chart/.env-contract-ignore" ]; then
  ignore=$(grep -vE '^[[:space:]]*(#|$)' "$chart/.env-contract-ignore" | tr -d ' ' | sort -u)
fi

fail=0
# Direction 1: a chart key absent from the contract is an orphan / typo / var
# removed upstream (unless explicitly ignored as non-app infra).
for k in $chart_keys; do
  grep -qxF "$k" <<<"$ignore" && continue
  grep -qxF "$k" <<<"$contract" || { echo "orphan: chart references $k, absent from contract"; fail=1; }
done
# Direction 2: a contract key neither mirrored nor ignored is an unhandled new var.
for k in $contract; do
  grep -qxF "$k" <<<"$chart_keys" && continue
  grep -qxF "$k" <<<"$ignore" && continue
  echo "unmirrored: contract has $k, not in chart or .env-contract-ignore"; fail=1
done

if [ "$fail" -eq 0 ]; then
  echo "OK: github-app chart env surface matches contract v${appver}"
fi
exit "$fail"

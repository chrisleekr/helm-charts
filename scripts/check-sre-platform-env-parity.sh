#!/usr/bin/env bash
# Compare the chart's rendered environment with the pinned application's public contract.
set -euo pipefail

missing_contract_is_bootstrap() {
  [ "$1" = "0.0.0" ]
}

# Renders both the default and the bootstrap-enabled path into one stream.
# BOOTSTRAP_STAFF_PROVIDER and BOOTSTRAP_PLATFORM_ADMINS exist only when bootstrap is
# enabled, so a single default render would check the chart's two most
# consequential variable names against the contract in neither direction.
# Shared with check-sre-platform-env-parity.test.sh, which sources this file, so
# the self-test's synthetic contract is built from the same key set.
render_chart_env() {
  local chart=$1 out=$2
  helm template sre "$chart" -f "$chart/ci/ct-values.yaml" >"$out"
  helm template sre "$chart" -f "$chart/ci/ct-values.yaml" \
    --set bootstrap.enabled=true \
    --set-string 'bootstrap.staffProvider.displayName=Staff sign-in' \
    --set-string 'bootstrap.staffProvider.issuer=https://idp.example.com/' \
    --set-string 'bootstrap.staffProvider.browserClientId=browser-client' \
    --set-string 'bootstrap.staffProvider.audience=https://api.sre.example.com/' \
    --set-string 'bootstrap.platformAdmins[0].subject=directory|000000000000000000000001' \
    >>"$out"
  # Every remaining conditional branch. Keys behind a `with`/`if` are absent from
  # a render that does not enable the feature, and this gate reads keys from the
  # render rather than the templates, so an unrendered branch reads as a key the
  # chart never mirrored. That failure would surface on the first real release,
  # not here, because a missing contract SKIPs while appVersion is 0.0.0.
  helm template sre "$chart" -f "$chart/ci/ct-values.yaml" \
    --set smtp.enabled=true \
    --set-string 'smtp.host=smtp.example.com' \
    --set-string 'smtp.from=sre@example.com' \
    --set-string 'smtp.username=smtp-user' \
    --set-string 'public.supportUrl=https://support.example.com' \
    --set-string 'public.termsUrl=https://terms.example.com' \
    --set-string 'public.termsVersion=2026-01-01' \
    --set llm.provider=openai \
    --set-string 'llm.openaiModel=gpt-4o-mini' \
    >>"$out"
}

# The single definition of "which keys the chart mirrors". Shared with the
# self-test so its synthetic contract cannot drift from what the gate enforces:
# two copies would let the "matching contract" case pass against a different key
# set than the gate checks, and stop proving anything.
chart_env_keys() { # <render-file>
  grep -E '(^  [A-Z][A-Z0-9_]{2,}:)|(name: [A-Z][A-Z0-9_]{2,}$)' "$1" \
    | sed -E 's/.*name: //; s/^[[:space:]]*//; s/:.*$//' \
    | sort -u
}

main() {
repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/sre-platform"
appver=$(yq '.appVersion' "$chart/Chart.yaml" | tr -d '"')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

contract_file="$tmp/contract.json"
if [ -n "${ENV_CONTRACT_FILE:-}" ]; then
  cp "$ENV_CONTRACT_FILE" "$contract_file"
else
  url="https://raw.githubusercontent.com/chrisleekr/sre-platform/v${appver}/env-contract.json"
  # Bounded and retried: an unbounded fetch hangs the job to the runner-level
  # timeout instead of failing, and the comparison below is what validates the body.
  code=$(curl -sSL --connect-timeout 10 --max-time 60 \
    --retry 3 --retry-delay 2 --retry-all-errors \
    -o "$contract_file" -w '%{http_code}' "$url" || echo 000)
  if [ "$code" = 404 ] && missing_contract_is_bootstrap "$appver"; then
    echo "SKIP: no public SRE Platform env-contract.json at v${appver}"
    exit 0
  fi
  if [ "$code" != 200 ]; then
    echo "ERROR: fetching $url returned HTTP $code" >&2
    exit 1
  fi
fi

render_chart_env "$chart" "$tmp/render.yaml"

# ConfigMap data keys and explicit env names. Rendering expands ranged Secret
# keys, so this also sees credentials that are not string literals in templates.
chart_keys=$(chart_env_keys "$tmp/render.yaml")
contract_keys=$(jq -r '.[].env' "$contract_file" | sort -u)
ignore_file="$chart/.env-contract-ignore"
if [ ! -r "$ignore_file" ]; then
  echo "ERROR: $ignore_file is missing or unreadable" >&2
  exit 1
fi
# grep exits 1 when the file holds only comments and blank lines, which is a valid
# empty ignore list; under pipefail that killed the assignment and set -e ended the
# run before any comparison, with no output at all. Only that status is tolerated:
# a blanket `|| true` would let an unreadable file pass as "nothing is ignored",
# which silently turns every ignored key into a gate the chart no longer has.
ignore_status=0
ignore=$(grep -vE '^[[:space:]]*(#|$)' "$ignore_file" | tr -d ' ' | sort -u) || ignore_status=$?
if [ "$ignore_status" -gt 1 ]; then
  echo "ERROR: reading $ignore_file failed with status $ignore_status" >&2
  exit 1
fi

fail=0
for key in $chart_keys; do
  grep -qxF "$key" <<<"$ignore" && continue
  grep -qxF "$key" <<<"$contract_keys" || {
    echo "orphan: chart references $key, absent from the application contract"
    fail=1
  }
done
for key in $contract_keys; do
  grep -qxF "$key" <<<"$chart_keys" && continue
  grep -qxF "$key" <<<"$ignore" && continue
  echo "unmirrored: application contract has $key, absent from the chart and ignore list"
  fail=1
done

if [ "$fail" -eq 0 ]; then
  echo "OK: SRE Platform chart env surface matches contract v${appver}"
fi
exit "$fail"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi

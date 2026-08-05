#!/usr/bin/env bash
#
# Memory invariant gate for the omniroute chart.
#
# values.yaml requires limits.memory to clear the V8 heap ceiling
# (OMNIROUTE_MEMORY_MB) by the >=250Mi that lives outside the heap. Breaking it
# fails quietly: V8 aborts and the container ends up exiting 0 ("Completed"),
# which never reaches CrashLoopBackOff and so fires no crash-loop alert. See
# issue #53. Enforced in CI because appVersion patch bumps auto-merge with no
# human reading the values.yaml comment.
#
# Dependencies: helm and yq. Unlike check-binance-trading-bot-render.sh this one
# cannot drop yq, because the invariant is a numeric comparison between two
# values buried in different rendered resources.
#
# The ::error lines are GitHub Actions workflow commands, which turn a failure
# into an inline annotation on values.yaml. They are inert plain text anywhere
# else, so the script stays portable.
#
# Run from anywhere:  bash scripts/check-omniroute-memory.sh
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart_dir=charts/omniroute
chart="$repo_root/$chart_dir"

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

helm template "$chart" -f "$chart/ci/ct-values.yaml" > "$rendered"

cap=$(yq e 'select(.kind == "ConfigMap") | .data.OMNIROUTE_MEMORY_MB' "$rendered")
limit=$(yq e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits.memory' "$rendered")

# yq prints "null" for a missing key and bash arithmetic reads that as 0, which
# would pass this check. Reject non-numeric up front so a renamed or deleted key
# fails closed. Also catches multi-line (duplicate resource).
require_int() {
  case "$2" in ''|*[!0-9]*)
    echo "::error file=$chart_dir/values.yaml::$1 is not a plain integer: '$2'"; exit 1 ;;
  esac
}
require_int OMNIROUTE_MEMORY_MB "$cap"
case "$limit" in
  *Gi) mib=${limit%Gi}; require_int limits.memory "$mib"; limit_mi=$(( mib * 1024 )) ;;
  *Mi) mib=${limit%Mi}; require_int limits.memory "$mib"; limit_mi=$mib ;;
  *) echo "::error file=$chart_dir/values.yaml::unhandled limits.memory unit: '$limit'"; exit 1 ;;
esac
headroom=$(( limit_mi - cap ))
echo "heap ceiling ${cap}Mi, limit ${limit_mi}Mi, headroom ${headroom}Mi"
if [ "$headroom" -lt 250 ]; then
  echo "::error file=$chart_dir/values.yaml::limits.memory ($limit) must exceed OMNIROUTE_MEMORY_MB ($cap) by >=250Mi, got ${headroom}Mi"
  exit 1
fi

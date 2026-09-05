#!/usr/bin/env bash
#
# Self-test for check-policy-parity.sh. Builds a synthetic "upstream" example from
# the chart's own rendered policy, so it needs no static fixture and stays valid as
# the policy evolves. This gives the gate CI coverage even during the bootstrap
# window, when the live example at v<appVersion> 404s and the gate SKIPs.
#
# The fixture is extracted textually, never re-serialised through yq: yq rewrites
# the multi-line CEL block scalars, which the gate would then correctly report as
# drift and the positive case would fail for the wrong reason.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/github-app"
# Same reason as check-policy-parity.sh: the chart's namespace guards read
# .Release.Namespace, so an unpinned local namespace fails this for the wrong reason.
export HELM_NAMESPACE=github-app

cd "$root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

helm template parity "$chart" -f "$chart/ci/workflow-runner-values.yaml" > "$tmp/rendered.yaml"
awk -v out="$tmp/doc" 'BEGIN { n = 0 } /^---$/ { n++; next } { print > (out n ".yaml") }' "$tmp/rendered.yaml"
good=$(grep -lx 'kind: ValidatingAdmissionPolicy' "$tmp"/doc*.yaml || true)
if [ -z "$good" ] || [ "$(printf '%s\n' "$good" | wc -l)" -ne 1 ]; then
  echo "FAIL: expected exactly one ValidatingAdmissionPolicy document in the render"
  exit 1
fi

fail=0
expect_pass() {
  local out
  if ! out=$(POLICY_SOURCE_FILE="$2" bash "$here/check-policy-parity.sh" 2>&1); then
    echo "FAIL: $1"
    printf '%s\n' "$out"
    fail=1
  fi
}
# A malformed fixture, a missing tool or a set -u bug also exit non-zero, so match
# the gate's own message or the case proves nothing about the diff logic.
expect_fail() {
  local out
  # A mutation that stops matching leaves the fixture identical to the chart's own
  # render, so the gate passes for the right reason and the case proves nothing.
  if cmp -s "$2" "$good"; then
    echo "FAIL: $1 (fixture identical to the chart render, mutation did not apply)"
    fail=1
    return
  fi
  if out=$(POLICY_SOURCE_FILE="$2" bash "$here/check-policy-parity.sh" 2>&1); then
    echo "FAIL: $1 (gate passed)"
    fail=1
    return
  fi
  if ! printf '%s\n' "$out" | grep -qF "$3"; then
    echo "FAIL: $1 (wrong failure reason)"
    printf '%s\n' "$out"
    fail=1
  fi
}

expect_pass "gate should pass when the chart matches upstream" "$good"

# The real upstream is a five-document file, and the gate reads it with `yq ea`.
# Feeding it the whole render exercises that path, which the single-document
# fixtures above never reach.
expect_pass "gate should pass on a multi-document upstream" "$tmp/rendered.yaml"

# Changed expression: the substance of the boundary.
sed -E 's/size\(params\.data\) == [0-9]+/size(params.data) == 0/' "$good" > "$tmp/expression.yaml"
expect_fail "gate should fail on a changed policy expression" "$tmp/expression.yaml" "policy drift:"

# Changed message: operator-facing text is part of the contract too.
sed 's/must carry one exact v4 attempt identity/must carry a changed message/' "$good" > "$tmp/message.yaml"
expect_fail "gate should fail on a changed validation message" "$tmp/message.yaml" "policy drift:"

# Extra validation: `validations` is the last key in the policy spec, so an
# upstream that grew a rule the chart lacks appends cleanly here.
{ cat "$good"; printf '    - expression: "true"\n      message: "added upstream"\n'; } > "$tmp/extra.yaml"
expect_fail "gate should fail when upstream has a validation the chart lacks" "$tmp/extra.yaml" "policy drift:"

# Renamed policy: github-app's harness asserts denials by policy name.
sed 's/github-app-workflow-runner-boundary/renamed-policy/' "$good" > "$tmp/renamed.yaml"
expect_fail "gate should fail on a renamed policy" "$tmp/renamed.yaml" "policy name drift:"

if [ "$fail" -eq 0 ]; then
  echo "OK: check-policy-parity self-test passed (positive + multi-doc + expression + message + extra-rule + rename)"
fi
exit "$fail"

#!/usr/bin/env bash
#
# Deterministic parity gate for the workflow-runner admission policy.
#
# github-app owns the ValidatingAdmissionPolicy: it is derived from
# buildWorkflowRunnerPod and tested there against the real renderer by
# `bun run test:admission`. The chart carries an installable copy so the boundary
# can ship through GitOps instead of a hand-run `kubectl apply`.
#
# The policy has no deployment inputs. Every site-specific value reaches it via
# the boundary ConfigMap params, so the two copies of `.spec` must agree. The
# comparison is after JSON normalisation: expressions, messages, variables,
# matchConstraints and failurePolicy must match, while key order and the line
# wrapping of the folded CEL scalars are normalised away. This gate fails on the
# case `helm template` cannot see: a stale chart copy renders fine and then denies
# every runner Pod at admission time.
#
# The Binding is NOT compared: its paramRef and namespaceSelector are templated
# on workflowRunner.namespace by design.
#
# Policy source: examples/workflow-runner-admission.yaml at v<appVersion> on
# raw.githubusercontent, overridable via POLICY_SOURCE_FILE for local runs / CI
# fixtures. A 404 (the pinned appVersion predates the example) is a skip, not a
# failure, so the gate does not block chart PRs during the bootstrap window.
set -euo pipefail

chart="charts/github-app"
values="$chart/ci/workflow-runner-values.yaml"
appver=$(yq '.appVersion' "$chart/Chart.yaml" | tr -d '"')

upstream=$(mktemp)
rendered=$(mktemp)
trap 'rm -f "$upstream" "$rendered"' EXIT

if [ -n "${POLICY_SOURCE_FILE:-}" ]; then
  cp "$POLICY_SOURCE_FILE" "$upstream"
else
  url="https://raw.githubusercontent.com/chrisleekr/github-app/v${appver}/examples/workflow-runner-admission.yaml"
  code=$(curl -sSL -o "$upstream" -w '%{http_code}' "$url" || true)
  if [ "$code" = "404" ]; then
    echo "SKIP: no examples/workflow-runner-admission.yaml at v${appver} (pre-example release); policy parity not enforced"
    exit 0
  fi
  if [ "$code" != "200" ]; then
    code=${code:-000}
    echo "ERROR: fetching $url returned HTTP $code" >&2
    exit 1
  fi
fi

helm template parity "$chart" -f "$values" > "$rendered"

select_policy='select(.kind == "ValidatingAdmissionPolicy")'

# The policy name is part of the contract: github-app's kind harness asserts
# denials by policy name.
upstream_name=$(yq ea -r "$select_policy | .metadata.name" "$upstream")
rendered_name=$(yq ea -r "$select_policy | .metadata.name" "$rendered")
if [ -z "$upstream_name" ] || [ "$upstream_name" = "null" ]; then
  echo "ERROR: no ValidatingAdmissionPolicy found in the upstream example" >&2
  exit 1
fi
if [ "$upstream_name" != "$rendered_name" ]; then
  echo "policy name drift: upstream '$upstream_name', chart '$rendered_name'" >&2
  exit 1
fi

# jq -S normalises key order so a reordered but equivalent spec is not a failure;
# any difference in expressions, variables, matchConstraints or failurePolicy is.
if ! diff -u \
  <(yq ea -o=json "$select_policy | .spec" "$upstream" | jq -S .) \
  <(yq ea -o=json "$select_policy | .spec" "$rendered" | jq -S .); then
  cat >&2 <<'MSG'

policy drift: the chart's ValidatingAdmissionPolicy .spec differs from the copy
published by github-app at the pinned appVersion.

github-app is canonical. Copy its examples/workflow-runner-admission.yaml policy
document into charts/github-app/templates/workflow-runner-admission.yaml,
preserving the Helm metadata block, and re-run. If the upstream policy changed
because the runner Pod shape changed, the boundary ConfigMap in
templates/workflow-runner-boundary.yaml may need matching keys.
MSG
  exit 1
fi

echo "workflow-runner policy parity: chart matches github-app v${appver} ($(yq ea -o=json "$select_policy | .spec.validations | length" "$upstream") validations)"

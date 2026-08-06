#!/usr/bin/env bash
#
# Render matrix for the omniroute chart.
#
# Exercises every conditional branch in the chart so a template error in any
# mode surfaces on the MR, not after publish. `helm lint` and a single
# `helm template` run only prove the default path renders; they say nothing
# about the ingress, TLS, existingSecret, persistence or serviceAccount
# branches.
#
# Lived inline in the GitLab CI config until the two CIs were brought to parity.
# GitHub never ran it, so a branch that failed to render there merged and only
# broke on the GitLab side.
#
# Every --set flag is a static literal. Nothing interpolates a CI context, so
# the script has no injection surface when driven from CI.
#
# Dependencies: helm and yq. yq is needed for the extraConfig merge assertion,
# which is a value comparison rather than a render check.
#
# Run from anywhere:  bash scripts/check-omniroute-render.sh
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/omniroute"
# ct-values supplies the required auth.initialPassword for rendering.
values="$chart/ci/ct-values.yaml"

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

# 1. Defaults.
helm lint "$chart" -f "$values"
helm template "$chart" -f "$values" > /dev/null
# 2. Ingress without TLS.
helm template "$chart" -f "$values" \
  --set ingress.enabled=true \
  --set ingress.className=nginx > /dev/null
# 3. Ingress with a tls entry, so the tls block and the NOTES https branch render.
helm template "$chart" -f "$values" \
  --set ingress.enabled=true \
  --set 'ingress.tls[0].secretName=omniroute-tls' \
  --set 'ingress.tls[0].hosts[0]=omniroute.example.com' > /dev/null
# 4. Caller-supplied auth Secret.
helm template "$chart" -f "$values" \
  --set auth.existingSecret=omniroute-auth > /dev/null
# 5. Persistence off.
helm template "$chart" -f "$values" \
  --set persistence.enabled=false > /dev/null
# 6. serviceAccount.create=false exercises the serviceAccountName else-branch.
helm template "$chart" -f "$values" \
  --set serviceAccount.create=false > /dev/null
# 7. extraConfig overlapping a config key must merge (extraConfig wins), not emit
#    a duplicate key. Assert the effective value rather than only that it renders.
helm template "$chart" -f "$values" \
  --set config.PORT=20128 \
  --set extraConfig.PORT=9000 > "$rendered"
port=$(yq e 'select(.kind == "ConfigMap") | .data.PORT' "$rendered")
if [ "$port" != "9000" ]; then
  echo "::error file=charts/omniroute/templates/configmap.yaml::extraConfig.PORT must override config.PORT, got '$port'"
  exit 1
fi

echo "omniroute render matrix: 7/7 cases rendered"

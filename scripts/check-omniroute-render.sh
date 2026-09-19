#!/usr/bin/env bash
#
# Render matrix for the omniroute chart.
#
# Exercises every conditional branch in the chart so a template error in any
# mode surfaces on the MR, not after publish. `helm lint` and a single
# `helm template` run only prove the default path renders; they say nothing
# about the route, existingSecret, persistence, serviceAccount or extraObjects
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
# 2. Route off. ct-values enables it, so this is the only cover for the
#    route-disabled template branches. helm template does not render NOTES.txt.
helm template "$chart" -f "$values" \
  --set route.enabled=false > /dev/null
# 3. Route with caller-supplied rules, which replace the default catch-all.
#    helm template defaults the release to "release-name", so the chart's Service
#    is release-name-omniroute. Point the backendRef there so the fixture models
#    a working route rather than one to a Service that does not exist.
helm template "$chart" -f "$values" \
  --set-json 'route.rules=[{"matches":[{"path":{"type":"PathPrefix","value":"/v1"}}],"backendRefs":[{"name":"release-name-omniroute","port":20128}]}]' > "$rendered"
service=$(yq e 'select(.kind == "Service") | .metadata.name' "$rendered")
backend=$(yq e 'select(.kind == "HTTPRoute") | .spec.rules[0].backendRefs[0].name' "$rendered")
if [ "$backend" != "$service" ]; then
  echo "::error file=scripts/check-omniroute-render.sh::route.rules backendRef '$backend' does not match the rendered Service '$service'"
  exit 1
fi
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

# 8. Route enabled with no parentRefs must fail the render. The API server
#    accepts a parentless HTTPRoute that then serves nothing, so the guard is the
#    only thing standing between that and a silent outage.
if out=$(helm template "$chart" -f "$values" --set route.parentRefs=null 2>&1); then
  echo "::error file=charts/omniroute/templates/httproute.yaml::route.enabled with empty route.parentRefs must fail to render"
  exit 1
fi
if ! grep -q "route.parentRefs is empty" <<<"$out"; then
  echo "::error file=charts/omniroute/templates/httproute.yaml::empty route.parentRefs failed for the wrong reason: $out"
  exit 1
fi
# 9. extraObjects entries run through tpl. Assert both render and that the
#    release name was substituted, not emitted literally.
helm template "$chart" -f "$values" \
  --set-json 'extraObjects=[{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"{{ .Release.Name }}-a"}},{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"b"}}]' > "$rendered"
for name in release-name-a b; do
  if [ "$(yq e "select(.kind == \"ConfigMap\" and .metadata.name == \"$name\") | .metadata.name" "$rendered")" != "$name" ]; then
    echo "::error file=charts/omniroute/templates/extra-objects.yaml::extraObjects entry '$name' did not render"
    exit 1
  fi
done

echo "omniroute render matrix: 9/9 cases passed"

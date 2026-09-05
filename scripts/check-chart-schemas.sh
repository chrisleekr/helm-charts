#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
# Renovate does not manage any of the four pins below: renovate.json sets
# enabledManagers to custom.regex with managers only for the omniroute appVersion
# and the binance-trading-bot images. Bump them by hand. The two checksums belong
# to kubeconform_version and must be re-derived together whenever it moves.
kubeconform_version="v0.8.0"
kubernetes_version="1.31.0"
schema_revision="14355cdd490a43d21e05985668815a36a6f97da6"
schema_location="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$schema_revision/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
# Kinds with no schema in the pinned catalog above. Listed explicitly rather than
# passing -ignore-missing-schemas, which would also swallow a typo in a core
# apiVersion. Their shape is asserted by check-binance-trading-bot-render.sh
# instead. A chart introducing another custom resource fails here until it is
# added, which is the loud failure this gate is for.
skip_kinds="ServiceMonitor,PrometheusRule"
platform="$(uname -s)/$(uname -m)"

case "$platform" in
  Linux/x86_64)
    asset="kubeconform-linux-amd64.tar.gz"
    expected_sha256="9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883"
    ;;
  Darwin/arm64)
    asset="kubeconform-darwin-arm64.tar.gz"
    expected_sha256="f84f4dfbebf4a6b0b230385fa065a39ea35e02608c2b50d025dcf64775a69d67"
    ;;
  *)
    printf 'Unsupported kubeconform platform: %s\n' "$platform" >&2
    exit 1
    ;;
esac

schema_tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-chart-schemas.XXXXXX")
trap 'rm -rf "$schema_tmp"' EXIT

archive="$schema_tmp/$asset"
# Retried because this gate feeds the required `lint` check on both hosts, and a
# transient CDN failure here says nothing about chart correctness. The checksum
# below is what makes a retry safe to accept.
curl --fail --location --silent --show-error \
  --retry 3 --retry-delay 2 --retry-all-errors \
  "https://github.com/yannh/kubeconform/releases/download/$kubeconform_version/$asset" \
  --output "$archive"

case "$platform" in
  Linux/*) actual_sha256=$(sha256sum "$archive" | awk '{print $1}') ;;
  Darwin/*) actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}') ;;
esac
if [ "$actual_sha256" != "$expected_sha256" ]; then
  printf 'Checksum mismatch for %s: expected %s, got %s\n' \
    "$asset" "$expected_sha256" "$actual_sha256" >&2
  exit 1
fi

tar -xzf "$archive" -C "$schema_tmp" kubeconform
kubeconform="$schema_tmp/kubeconform"

# The glob is the chart inventory. LC_ALL=C makes its order stable in local and
# CI output, while a new charts/*/Chart.yaml is included without another list.
export LC_ALL=C
charts=()
for chart_yaml in "$repo_root"/charts/*/Chart.yaml; do
  [ -f "$chart_yaml" ] || continue
  charts+=("${chart_yaml%/Chart.yaml}")
done
if [ "${#charts[@]}" -eq 0 ]; then
  printf 'No charts/*/Chart.yaml files found\n' >&2
  exit 1
fi

# --kube-version pins Capabilities.KubeVersion to the version the schemas below
# describe. Without it Helm falls back to its binary's built-in default, which
# moves with each Helm release and differs between the two CI hosts:
# chart-testing-action does not install Helm, so GitHub uses the runner image's,
# while GitLab uses the one bundled in the chart-testing image. charts/woodle-map
# branches on Capabilities.KubeVersion.GitVersion, so that is a live input.
#
# --include-crds because helm template omits crds/ without it. No chart ships a
# crds/ directory today; the flag is here so the one that does is not silently
# half-validated, the same reason the chart inventory above is a glob.
render() { # <chart-dir> [-f values...]
  helm template schema-check "$@" \
    --kube-version "$kubernetes_version" \
    --include-crds >>"$rendered"
}

rendered="$schema_tmp/rendered.yaml"
: >"$rendered"
printf 'Discovered %s charts\n' "${#charts[@]}"
fixtures=0
for chart_dir in "${charts[@]}"; do
  chart_name=${chart_dir##*/}
  # ct installs every file under ci/ independently, so each one is a distinct
  # rendered shape. Validating ct-values.yaml alone would leave exactly the
  # branches that add API surface unchecked: the binance-trading-bot
  # observability fixture is the only source of a NetworkPolicy, its split
  # fixture the only source of the role-suffixed Deployments, and github-app has
  # no ct-values.yaml at all, so its one fixture would never have been rendered.
  values_files=()
  for values_file in "$chart_dir"/ci/*-values.yaml; do
    [ -f "$values_file" ] || continue
    values_files+=("$values_file")
  done
  if [ "${#values_files[@]}" -eq 0 ]; then
    printf '  %s: chart defaults\n' "$chart_name"
    render "$chart_dir"
    fixtures=$((fixtures + 1))
    continue
  fi
  for values_file in "${values_files[@]}"; do
    printf '  %s: ci/%s\n' "$chart_name" "${values_file##*/}"
    render "$chart_dir" -f "$values_file"
    fixtures=$((fixtures + 1))
  done
done
printf 'Rendered %s fixtures\n' "$fixtures"

"$kubeconform" \
  -strict \
  -n 1 \
  -summary \
  -kubernetes-version "$kubernetes_version" \
  -schema-location "$schema_location" \
  -skip "$skip_kinds" \
  "$rendered"

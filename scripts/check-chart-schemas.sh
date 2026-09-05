#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
kubeconform_version="v0.8.0"
kubernetes_version="1.31.0"
schema_revision="14355cdd490a43d21e05985668815a36a6f97da6"
schema_location="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$schema_revision/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json"
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
curl --fail --location --silent --show-error \
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

rendered="$schema_tmp/rendered.yaml"
: >"$rendered"
printf 'Discovered %s charts\n' "${#charts[@]}"
for chart_dir in "${charts[@]}"; do
  chart_name=${chart_dir##*/}
  values_file="$chart_dir/ci/ct-values.yaml"
  helm_args=(template schema-check "$chart_dir")
  if [ -f "$values_file" ]; then
    helm_args+=(-f "$values_file")
    printf 'Rendering %s with ci/ct-values.yaml\n' "$chart_name"
  else
    printf 'Rendering %s with chart defaults\n' "$chart_name"
  fi
  helm "${helm_args[@]}" >>"$rendered"
done

"$kubeconform" \
  -strict \
  -n 1 \
  -summary \
  -kubernetes-version "$kubernetes_version" \
  -schema-location "$schema_location" \
  "$rendered"

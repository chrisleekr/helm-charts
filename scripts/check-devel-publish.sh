#!/usr/bin/env bash
# Check CI packaging with real Git history and Helm, without registry writes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
yq -r '.publish-devel.script[0]' "$root/.gitlab/ci/publish-devel.yml" > "$tmp/publish.sh"
cd "$tmp"
git init -q
git config user.name 'Chart test'
git config user.email chart-test@example.com
git config commit.gpgsign false
git config core.hooksPath /dev/null
git commit -q --allow-empty -m baseline
mkdir -p charts/sre-platform
printf 'apiVersion: v2\nname: sre-platform\nversion: 1.0.0\n' > charts/sre-platform/Chart.yaml
# A second placeholder chart under a different name. Without it the name test in
# the withholding rule is unobserved: dropping it would publish every 0.0.0 chart
# to devel and every assertion below would still pass.
mkdir -p charts/other-chart
printf 'apiVersion: v2\nname: other-chart\nversion: 2.0.0\nappVersion: "0.0.0"\n' > charts/other-chart/Chart.yaml

export CI_COMMIT_SHORT_SHA=01234567 CI_PROJECT_ID=42 CI_JOB_TOKEN=test-token
export CI_API_V4_URL=https://registry.example/api/v4
curl() { printf 'uploaded\n' >> uploads; }
export -f curl

for appversion in 0.0.0 1.2.3; do
  export CI_COMMIT_BEFORE_SHA=$(git rev-parse HEAD)
  appversion="$appversion" yq -i '.appVersion = strenv(appversion)' charts/sre-platform/Chart.yaml
  git add charts
  git commit -q -m "Application $appversion"
  bash publish.sh
  # The packaged appVersion is the one on disk. Substituting a different value
  # would flip the chart's bootstrap predicate off and break its render.
  [ "$(helm show chart sre-platform-1.0.0-dev-01234567.tgz | yq '.appVersion')" = "$appversion" ]
  [ "$(yq '.appVersion' charts/sre-platform/Chart.yaml)" = "$appversion" ]
  # other-chart changed in the same commit and is still withheld at 0.0.0.
  [ ! -e other-chart-2.0.0-dev-01234567.tgz ]
done
[ "$(wc -l < uploads | tr -d ' ')" = 2 ]
echo 'PASS: placeholder published, real release version, on-disk metadata untouched, other placeholder charts withheld'

export CI_COMMIT_BEFORE_SHA=$(git rev-parse HEAD)
mkdir -p .gitlab/ci
cp "$root/.gitlab/ci/publish-devel.yml" .gitlab/ci/publish-devel.yml
git add .gitlab
git commit -q -m 'Publishing policy only'
bash publish.sh
[ "$(wc -l < uploads | tr -d ' ')" = 2 ]
echo 'PASS: CI-only changes do not republish SRE Platform'

# The fixture above is metadata with no templates, so it cannot show whether the
# artifact the job uploads actually renders. Package the real chart the way the
# job does and template it under default CI values.
helm package "$root/charts/sre-platform" --version 1.0.0-dev-01234567 --destination "$tmp/real" >/dev/null
helm template sre "$tmp/real/sre-platform-1.0.0-dev-01234567.tgz" \
  -f "$root/charts/sre-platform/ci/ct-values.yaml" >/dev/null
echo 'PASS: the packaged SRE Platform chart renders under default values'

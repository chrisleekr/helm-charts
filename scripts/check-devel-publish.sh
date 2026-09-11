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
  expected=$appversion
  [ "$appversion" != 0.0.0 ] || expected=0.0.1
  [ "$(helm show chart sre-platform-1.0.0-dev-01234567.tgz | yq '.appVersion')" = "$expected" ]
  [ "$(yq '.appVersion' charts/sre-platform/Chart.yaml)" = "$appversion" ]
done
[ "$(wc -l < uploads | tr -d ' ')" = 2 ]
echo 'PASS: placeholder override, real release version and unchanged source metadata'

export CI_COMMIT_BEFORE_SHA=$(git rev-parse HEAD)
mkdir -p .gitlab/ci
cp "$root/.gitlab/ci/publish-devel.yml" .gitlab/ci/publish-devel.yml
git add .gitlab
git commit -q -m 'Publishing policy only'
bash publish.sh
[ "$(wc -l < uploads | tr -d ' ')" = 2 ]
echo 'PASS: CI-only changes do not republish SRE Platform'

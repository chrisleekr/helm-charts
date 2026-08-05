#!/usr/bin/env bash
#
# Render matrix for the github-app chart.
#
# Exercises every conditional branch in the chart so a template error in any
# mode surfaces on the PR, not after publish. `helm lint` and a single
# `helm template` run only prove the default path renders; they say nothing
# about the seven other combinations of provider, datastore and RBAC.
#
# Every --set flag is a static literal. Nothing here interpolates a github.*
# context, so the script has no injection surface when driven from CI.
#
# Dependencies: helm and bash only.
#
# Run from anywhere:  bash scripts/check-github-app-render.sh
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/github-app"

# 1. Defaults — daemon-only dispatch, no ephemeral spawn knobs overridden.
helm template "$chart" > /dev/null
# 2. Bedrock provider path.
helm template "$chart" \
  --set config.provider=bedrock \
  --set config.awsRegion=us-east-1 \
  --set config.model=us.anthropic.claude-sonnet-4-5-v1:0 > /dev/null
# 3. In-chart Postgres + Valkey + RBAC (rbac.create=true now provisions
#    a Role for ephemeral daemon Pod spawning — see upstream PR #35).
helm template "$chart" \
  --set postgres.enabled=true --set valkey.enabled=true \
  --set rbac.create=true > /dev/null
# 4. External Postgres + Valkey (literal password path).
helm template "$chart" \
  --set postgres.external.enabled=true \
  --set postgres.external.host=pg \
  --set postgres.external.username=u \
  --set postgres.external.database=d \
  --set postgres.external.password=p \
  --set valkey.external.enabled=true \
  --set valkey.external.host=r \
  --set valkey.external.auth.password=p > /dev/null
# 5. User-supplied URLs (neither in-chart nor external enabled).
helm template "$chart" \
  --set config.databaseUrl=postgres://u:p@h/d \
  --set config.valkeyUrl=redis://h:6379 > /dev/null
# 6. Daemon pools: default (no DinD) + docker-heavy (rootless DinD).
helm template "$chart" \
  --values "$chart/ci/daemon-pools-values.yaml" > /dev/null
# 7. Ephemeral daemon scale-up (chart-managed RBAC): namespace stays at
#    the release namespace so role.yaml's cross-namespace guard is happy.
helm template "$chart" \
  --set rbac.create=true \
  --set config.ephemeralDaemon.orchestratorPublicUrl=ws://orchestrator.example:3002/ws \
  --set config.ephemeralDaemon.spawnQueueThreshold=5 > /dev/null
# 8. Ephemeral daemon scale-up (operator-managed RBAC): rbac.create=false
#    releases the namespace lock, so cross-namespace spawn is allowed.
helm template "$chart" \
  --set rbac.create=false \
  --set config.ephemeralDaemon.namespace=agents > /dev/null
# 9. Negative case for the guard case 7 and 8 straddle: chart-managed RBAC
#    grants a Role in the release namespace only, so a cross-namespace spawn
#    target must be rejected at render time. Cases 7 and 8 both take the
#    passing side, so without this the guard could be deleted and CI stay green.
if helm template "$chart" \
  --set rbac.create=true \
  --set config.ephemeralDaemon.namespace=agents > /dev/null 2>&1; then
  echo "::error file=charts/github-app/templates/role.yaml::rbac.create=true with a cross-namespace config.ephemeralDaemon.namespace rendered instead of failing; the namespace guard is gone" >&2
  exit 1
fi

echo "github-app render matrix: 9/9 cases rendered"

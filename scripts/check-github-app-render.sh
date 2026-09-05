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

# 10. Isolated workflow runners on: the capability root must land in the
#     controller-only Secret (mounted on the orchestrator alone) and never in
#     the shared app Secret, which every daemon pool envFrom-mounts.
out=$(helm template "$chart" \
  --set rbac.create=true \
  --set secrets.workflowRunnerCapabilitySecret=0123456789abcdef0123456789abcdef \
  --values "$chart/ci/daemon-pools-values.yaml")
# Secret document that carries the key vs. the Secret documents that must not.
if ! printf '%s\n' "$out" | awk '/^# Source: github-app\/templates\/controller-secret.yaml/,/^---/' \
  | grep -q '^  WORKFLOW_RUNNER_CAPABILITY_SECRET:'; then
  echo "::error file=charts/github-app/templates/controller-secret.yaml::WORKFLOW_RUNNER_CAPABILITY_SECRET missing from the controller-only Secret" >&2
  exit 1
fi
if printf '%s\n' "$out" | awk '/^# Source: github-app\/templates\/secret.yaml/,/^---/' \
  | grep -q '^  WORKFLOW_RUNNER_CAPABILITY_SECRET'; then
  echo "::error file=charts/github-app/templates/secret.yaml::WORKFLOW_RUNNER_CAPABILITY_SECRET leaked into the shared app Secret that daemon pools mount" >&2
  exit 1
fi
if printf '%s\n' "$out" | awk '/^# Source: github-app\/templates\/daemon-deployment.yaml/,/^---/' \
  | grep -q 'controller-secret'; then
  echo "::error file=charts/github-app/templates/daemon-deployment.yaml::daemon Deployment references the controller-only Secret" >&2
  exit 1
fi
if ! printf '%s\n' "$out" | awk '/^# Source: github-app\/templates\/deployment.yaml/,/^---/' \
  | grep -q 'controller-secret'; then
  echo "::error file=charts/github-app/templates/deployment.yaml::orchestrator Deployment does not mount the controller-only Secret" >&2
  exit 1
fi
# 11. Legacy-only repo-config override: a pre-1.17 `config.schedulerConfigFile`
#     override must still reach the app. The app prefers REPO_CONFIG_FILE, so
#     the chart must not render that key with a default alongside it.
out=$(helm template "$chart" --set config.schedulerConfigFile=legacy.yaml \
  | awk '/^# Source: github-app\/templates\/configmap.yaml/,/^---/')
if ! printf '%s\n' "$out" | grep -q '^  SCHEDULER_CONFIG_FILE: "legacy.yaml"$'; then
  echo "::error file=charts/github-app/templates/configmap.yaml::config.schedulerConfigFile=legacy.yaml did not render SCHEDULER_CONFIG_FILE" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -q '^  REPO_CONFIG_FILE:'; then
  echo "::error file=charts/github-app/templates/configmap.yaml::REPO_CONFIG_FILE rendered alongside a legacy-only schedulerConfigFile override; the app would ignore the override" >&2
  exit 1
fi

echo "github-app render matrix: 11/11 cases rendered"

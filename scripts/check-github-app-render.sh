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
# Dependencies: helm, yq and bash.
#
# Run from anywhere:  bash scripts/check-github-app-render.sh
set -euo pipefail

# helm template takes the release namespace from the ambient kube context, and
# several chart guards compare against it, so pin it. Without this the matrix
# passes or fails depending on whoever ran it last, and a developer whose current
# namespace happens to be github-app-runners sees a failure CI does not.
export HELM_NAMESPACE=github-app

repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/github-app"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. Defaults — daemon-only dispatch, no ephemeral spawn knobs overridden.
helm template contract "$chart" > "$tmp/default.yaml"
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
helm template contract "$chart" \
  --values "$chart/ci/daemon-pools-values.yaml" > "$tmp/pools.yaml"
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

# 10. The capability root is present on the controller and absent from daemon Pods.
controller_deploy=contract-github-app
controller_secret=$controller_deploy-controller-secret
shared_secret=$controller_deploy-secret

# Three cases below ask which Secret the controller's capability-root env var
# points at; two of them also ask whether the chart-managed controller Secret
# carries a root. The external-controller case renders no such Secret, so it asks
# only the first. Both queries derive their names from the variables above: a
# hardcoded literal would silently return empty if the release name ever changed,
# and the failure would read as a chart bug rather than a script one.
capability_ref() {
  yq ea -r \
    "select(.kind == \"Deployment\" and .metadata.name == \"$controller_deploy\") | .spec.template.spec.containers[0].env[] | select(.name == \"WORKFLOW_RUNNER_CAPABILITY_SECRET\") | .valueFrom.secretKeyRef.name" \
    "$1"
}
capability_root() {
  yq ea -r \
    "select(.kind == \"Secret\" and .metadata.name == \"$controller_secret\") | .data.WORKFLOW_RUNNER_CAPABILITY_SECRET // \"\"" \
    "$1"
}
daemon_secret_refs() {
  yq ea -r \
    'select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" == "daemon") | .spec.template.spec.containers[0].envFrom[].secretRef.name' \
    "$1"
}
controller_ref=$(capability_ref "$tmp/default.yaml")
previous_optional=$(yq ea -r \
  'select(.kind == "Deployment" and .metadata.name == "contract-github-app") | .spec.template.spec.containers[0].env[] | select(.name == "WORKFLOW_RUNNER_CAPABILITY_SECRET_PREVIOUS") | .valueFrom.secretKeyRef.optional' \
  "$tmp/default.yaml")
controller_root=$(capability_root "$tmp/default.yaml")
daemon_refs=$(daemon_secret_refs "$tmp/pools.yaml")
if [ "$controller_ref" != "$controller_secret" ] || [ "$previous_optional" != "true" ] || \
  [ -z "$controller_root" ] || \
  ! grep -qxF "$shared_secret" <<<"$daemon_refs" || grep -qxF "$controller_secret" <<<"$daemon_refs"; then
  echo "controller-only capability Secret wiring is invalid" >&2
  exit 1
fi

helm template contract "$chart" \
  --set-string secrets.workflowRunnerCapabilitySecret=11111111111111111111111111111111 \
  --set-string secrets.workflowRunnerCapabilitySecretPrevious=22222222222222222222222222222222 \
  > "$tmp/inline.yaml"
inline_current=$(yq ea -r \
  'select(.kind == "Secret" and .metadata.name == "contract-github-app-controller-secret") | .data.WORKFLOW_RUNNER_CAPABILITY_SECRET' \
  "$tmp/inline.yaml" | base64 -d)
inline_previous=$(yq ea -r \
  'select(.kind == "Secret" and .metadata.name == "contract-github-app-controller-secret") | .data.WORKFLOW_RUNNER_CAPABILITY_SECRET_PREVIOUS' \
  "$tmp/inline.yaml" | base64 -d)
if [ "$inline_current" != "11111111111111111111111111111111" ] || \
  [ "$inline_previous" != "22222222222222222222222222222222" ]; then
  echo "inline capability roots did not render exactly" >&2
  exit 1
fi

helm template contract "$chart" \
  --values "$chart/ci/daemon-pools-values.yaml" \
  --set secrets.existingSecret=external-shared \
  --set secrets.existingControllerSecret=external-controller > "$tmp/external.yaml"
external_ref=$(capability_ref "$tmp/external.yaml")
external_daemon_refs=$(daemon_secret_refs "$tmp/external.yaml")
if [ "$external_ref" != "external-controller" ] || \
  ! grep -qxF external-shared <<<"$external_daemon_refs" || \
  grep -qxF external-controller <<<"$external_daemon_refs"; then
  echo "external capability Secret wiring is invalid" >&2
  exit 1
fi

# An external shared Secret no longer has to be paired with an explicit
# controller-only source: the chart generates the capability root itself into the
# controller-only Secret, which daemon pools never mount. Assert it renders AND
# that the root still lands off the shared Secret.
# The daemon pools have to be rendered here, or the "off the shared Secret" half
# of the claim is not actually asserted: without them there is no daemon envFrom
# to inspect and a leak would pass unnoticed.
helm template contract "$chart" \
  --values "$chart/ci/daemon-pools-values.yaml" \
  --set secrets.existingSecret=external-shared > "$tmp/extshared.yaml"
extshared_ref=$(capability_ref "$tmp/extshared.yaml")
extshared_root=$(capability_root "$tmp/extshared.yaml")
if [ "$extshared_ref" != "$controller_secret" ] || [ -z "$extshared_root" ] || \
  daemon_secret_refs "$tmp/extshared.yaml" | grep -qxF "$controller_secret"; then
  echo "existingSecret did not auto-generate a controller-only capability root off the shared Secret" >&2
  exit 1
fi
if helm template contract "$chart" \
  --set secrets.existingSecret=shared \
  --set secrets.existingControllerSecret=shared > /dev/null 2>&1; then
  echo "shared and controller Secret names may not be equal" >&2
  exit 1
fi
# The mirror route into the same collision: existingSecret pointed at the
# chart-managed controller Secret name makes both resolve to one Secret, which
# every daemon pool envFrom-mounts. Guarding only the existingControllerSecret
# direction leaves the capability root reachable by agent-authored code.
if helm template contract "$chart" \
  --set secrets.existingSecret="$controller_secret" > /dev/null 2>&1; then
  echo "existingSecret naming the chart's controller Secret rendered instead of failing" >&2
  exit 1
fi
# Rotation and cross-domain traps: an ignored inline root looks like a working
# config until every capability signed with the previous one is rejected, and a
# capability root equal to a daemon-auth root is refused by the controller at boot.
if helm template contract "$chart" \
  --set secrets.existingControllerSecret=ext-controller \
  --set secrets.workflowRunnerCapabilitySecretPrevious=00000000000000000000000000000000 > /dev/null 2>&1; then
  echo "existingControllerSecret silently discarded an inline capability root" >&2
  exit 1
fi
if helm template contract "$chart" \
  --set secrets.daemonAuthToken=11111111111111111111111111111111 \
  --set secrets.workflowRunnerCapabilitySecret=11111111111111111111111111111111 > /dev/null 2>&1; then
  echo "capability root equal to the daemon-auth root rendered instead of failing" >&2
  exit 1
fi
# The ephemeral-daemon Secret is envFrom-mounted on Pods running agent-authored
# code, so it must not be allowed to name one of the chart's own Secrets.
for forbidden in "$controller_secret" "$shared_secret"; do
  if helm template contract "$chart" \
    --set config.ephemeralDaemon.secretName="$forbidden" > /dev/null 2>&1; then
    echo "config.ephemeralDaemon.secretName=$forbidden rendered instead of failing" >&2
    exit 1
  fi
done

# 11. Isolated workflow runners. The boundary ConfigMap must carry exactly the 13
#     keys the policy asserts with size(params.data) == 13, and runnerImage must
#     equal the controller's DAEMON_IMAGE: a mismatch denies every runner Pod at
#     admission time, which no amount of template validity would reveal.
helm template contract "$chart" --values "$chart/ci/workflow-runner-values.yaml" > "$tmp/runners.yaml"
boundary_keys=$(yq ea -r \
  'select(.kind == "ConfigMap" and .metadata.name == "workflow-runner-boundary") | .data | length' \
  "$tmp/runners.yaml")
runner_image=$(yq ea -r \
  'select(.kind == "ConfigMap" and .metadata.name == "workflow-runner-boundary") | .data.runnerImage' \
  "$tmp/runners.yaml")
daemon_image=$(yq ea -r \
  'select(.kind == "ConfigMap" and .metadata.name == "contract-github-app-config") | .data.DAEMON_IMAGE' \
  "$tmp/runners.yaml")
runner_ns=$(yq ea -r \
  'select(.kind == "ConfigMap" and .metadata.name == "contract-github-app-config") | .data.WORKFLOW_RUNNER_NAMESPACE' \
  "$tmp/runners.yaml")
binding_ns=$(yq ea -r \
  'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.paramRef.namespace' \
  "$tmp/runners.yaml")
if [ "$boundary_keys" != "13" ]; then
  echo "::error file=charts/github-app/templates/workflow-runner-boundary.yaml::boundary ConfigMap has $boundary_keys data keys; the policy asserts size(params.data) == 13 and denies every runner Pod otherwise" >&2
  exit 1
fi
if [ "$runner_image" != "$daemon_image" ]; then
  echo "boundary runnerImage ($runner_image) does not equal DAEMON_IMAGE ($daemon_image); admission would deny every runner Pod" >&2
  exit 1
fi
if [ "$runner_ns" != "$binding_ns" ]; then
  echo "controller WORKFLOW_RUNNER_NAMESPACE ($runner_ns) does not equal the binding paramRef namespace ($binding_ns)" >&2
  exit 1
fi
# The controller stamps imagePullSecrets onto the Pod while the policy pins the
# allowed name from its own ConfigMap. Disagreement denies every runner Pod.
boundary_pull_secret=$(yq ea -r \
  'select(.kind == "ConfigMap" and .metadata.name == "workflow-runner-boundary") | .data.runnerImagePullSecret' \
  "$tmp/runners.yaml")
controller_pull_secret=$(yq ea -r \
  'select(.kind == "ConfigMap" and .metadata.name == "contract-github-app-config") | .data.WORKFLOW_RUNNER_IMAGE_PULL_SECRET' \
  "$tmp/runners.yaml")
if [ "$boundary_pull_secret" != "$controller_pull_secret" ]; then
  echo "boundary runnerImagePullSecret ($boundary_pull_secret) does not equal WORKFLOW_RUNNER_IMAGE_PULL_SECRET ($controller_pull_secret); admission would deny every runner Pod" >&2
  exit 1
fi
# A runner dials the wss:// front door, not the orchestrator Pod. When that host is
# a Service or LoadBalancer VIP the CNI evaluates egress after DNAT, so an ipBlock
# naming the VIP never matches and the private-range exclusions drop it. The
# Pod-selected rule is the only thing that admits the dial-back, and losing it costs
# a 4200s deadline per attempt with nothing logged.
egress_selector=$(yq ea -r \
  'select(.kind == "NetworkPolicy") | [.spec.egress[] | select([.ports[].port] | contains([443])) | .to[] | select(has("podSelector")) | .podSelector.matchLabels["app.kubernetes.io/name"]] | join(",")' \
  "$tmp/runners.yaml")
if [ "$egress_selector" != "ingress-nginx" ]; then
  echo "::error file=charts/github-app/templates/workflow-runner-networkpolicy.yaml::extraEgressSelectors rendered no HTTPS peer (got '$egress_selector'); a runner dialling a private VIP would hang until its deadline" >&2
  exit 1
fi
# Equality above is satisfied by two identical tags, which the controller and the
# policy both reject. The digest is the part that has to hold.
case "$runner_image" in
  *@sha256:*) ;;
  *)
    echo "boundary runnerImage ($runner_image) is not digest-pinned; the controller refuses it and the policy denies every runner Pod" >&2
    exit 1
    ;;
esac
# The one param derived by non-trivial logic. WHATWG drops a default port and
# lowercases the host; Go's urlParse does neither, so the helper has to.
for pair in \
  "wss://github.example.com/ws|wss://github.example.com" \
  "wss://github.example.com:443/ws|wss://github.example.com" \
  "wss://GitHub.Example.com/ws|wss://github.example.com" \
  "wss://github.example.com:3002/ws|wss://github.example.com:3002|--set=workflowRunner.ingress.enabled=false" \
  "ws://github-app.github-app.svc.cluster.local:3002/ws|ws://github-app.github-app.svc.cluster.local:3002|--set=workflowRunner.ingress.enabled=false" \
  "ws://github-app.github-app.svc:80/ws|ws://github-app.github-app.svc|--set=workflowRunner.ingress.enabled=false"; do
  IFS='|' read -r url want extra <<<"$pair"
  # shellcheck disable=SC2086  # deliberate word split: a single static flag or empty
  got=$(helm template contract "$chart" --values "$chart/ci/workflow-runner-values.yaml" \
    --set config.ephemeralDaemon.orchestratorPublicUrl="$url" $extra |
    yq ea -r 'select(.metadata.name == "workflow-runner-boundary") | .data.orchestratorOrigin')
  if [ "$got" != "$want" ]; then
    echo "orchestratorOrigin($url) rendered $got, want $want; the policy compares it against the runner's own URL" >&2
    exit 1
  fi
done
# None of these are templated, so check-policy-parity.sh does not compare them.
# validationActions downgrades the boundary to audit-only, a paramRef.name typo
# denies every Pod, parameterNotFoundAction: Allow skips validation entirely, and
# a policyName or namespaceSelector that misses installs an inert boundary.
binding_actions=$(yq ea -o=json -I=0 \
  'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.validationActions' "$tmp/runners.yaml")
binding_pnf=$(yq ea -r \
  'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.paramRef.parameterNotFoundAction' "$tmp/runners.yaml")
binding_name=$(yq ea -r \
  'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.paramRef.name' "$tmp/runners.yaml")
if [ "$binding_actions" != '["Deny","Audit"]' ] || [ "$binding_pnf" != "Deny" ] || [ "$binding_name" != "workflow-runner-boundary" ]; then
  echo "the runner binding is not fail-closed (validationActions=$binding_actions parameterNotFoundAction=$binding_pnf paramRef.name=$binding_name)" >&2
  exit 1
fi
policy_name=$(yq ea -r \
  'select(.kind == "ValidatingAdmissionPolicy") | .metadata.name' "$tmp/runners.yaml")
binding_policy=$(yq ea -r \
  'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.policyName' "$tmp/runners.yaml")
binding_nssel=$(yq ea -r \
  'select(.kind == "ValidatingAdmissionPolicyBinding") | .spec.matchResources.namespaceSelector.matchLabels."kubernetes.io/metadata.name"' \
  "$tmp/runners.yaml")
if [ "$binding_policy" != "$policy_name" ] || [ "$binding_nssel" != "$runner_ns" ]; then
  echo "the runner binding does not target the policy or the runner namespace (policyName=$binding_policy nsSelector=$binding_nssel)" >&2
  exit 1
fi

# The runner env carries the re-joined ALLOWED_OWNERS, not the raw string, so a
# space after a comma would otherwise pin a value no Pod ever matches.
owners=$(helm template contract "$chart" --values "$chart/ci/workflow-runner-values.yaml" \
  --set-string 'config.allowedOwners=acme\,  widgets ' |
  yq ea -r 'select(.metadata.name == "workflow-runner-boundary") | .data.allowedOwners')
if [ "$owners" != "acme,widgets" ]; then
  echo "boundary allowedOwners rendered '$owners', want 'acme,widgets'" >&2
  exit 1
fi

stale=$(helm template contract "$chart" --values "$chart/ci/workflow-runner-values.yaml" \
  --set config.awsRegion=us-east-1 \
  --set config.anthropicBedrockBaseUrl=https://bedrock.example.internal |
  yq ea -o=json -I=0 'select(.metadata.name == "workflow-runner-boundary") |
    [.data.awsRegion, .data.anthropicBedrockBaseUrl]')
if [ "$stale" != '["",""]' ]; then
  echo "anthropic boundary leaked Bedrock settings ($stale); the policy would deny every runner Pod" >&2
  exit 1
fi

# 11b. Bedrock boundary. The policy accepts exactly three credential shapes and
#      requires a non-empty awsRegion, so each has to render exactly.
bedrock_on=(--values "$chart/ci/workflow-runner-values.yaml"
  --set config.provider=bedrock --set config.awsRegion=us-east-1
  --set secrets.anthropicApiKey=)
while IFS='|' read -r flags c1 c2 c3; do
  # shellcheck disable=SC2086  # deliberate word split: static literals only
  got=$(helm template contract "$chart" "${bedrock_on[@]}" $flags |
    yq ea -o=json -I=0 'select(.metadata.name == "workflow-runner-boundary") |
      [.data.providerCredential1, .data.providerCredential2,
       .data.providerCredential3, .data.awsRegion]')
  want="[\"$c1\",\"$c2\",\"$c3\",\"us-east-1\"]"
  if [ "$got" != "$want" ]; then
    echo "bedrock boundary params rendered $got, want $want; the policy denies every runner Pod on a mismatch" >&2
    exit 1
  fi
done <<'BEDROCK'
--set secrets.awsBearerTokenBedrock=t|AWS_BEARER_TOKEN_BEDROCK||
--set secrets.awsAccessKeyId=a --set secrets.awsSecretAccessKey=b|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|
--set secrets.awsAccessKeyId=a --set secrets.awsSecretAccessKey=b --set secrets.awsSessionToken=c|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN
BEDROCK

# 12. Runner feature off is the default, and turning it off renders none of it.
leaked=$(yq ea -r '
  select(
    .kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding" or
    ((.metadata.name // "") | test("workflow-runner|^github-app-runners$|-ws$"))
  ) | .kind + "/" + .metadata.name' "$tmp/default.yaml")
if [ -n "$leaked" ]; then
  echo "workflow-runner resources rendered with workflowRunner.enabled unset: $leaked" >&2
  exit 1
fi

# 13. Negative cases for the runner guards. Each renders something that looks
#     valid and then fails at runtime -- denied Pods, a CrashLooping controller,
#     or a front door no runner will dial -- so every one must refuse here.
runner_on=(--values "$chart/ci/workflow-runner-values.yaml")
# $1 template file for the annotation, $2 substring the guard's message must
# contain, rest = helm flags. Matching the message is the point: a render can fail
# for an unrelated reason and a status-only check would still call the case green.
refuses() {
  local file=$1 want=$2 out
  if out=$(helm template contract "$chart" "${runner_on[@]}" "${@:3}" 2>&1); then
    echo "::error file=charts/github-app/templates/$file::rendered instead of failing: $want" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -qF "$want"; then
    echo "::error file=charts/github-app/templates/$file::render failed for the wrong reason; expected: $want" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
}
refuses workflow-runner-validate.yaml "orchestratorPublicUrl is empty" \
  --set config.ephemeralDaemon.orchestratorPublicUrl=
refuses workflow-runner-validate.yaml "is neither wss:// plus a plain DNS host" \
  --set config.ephemeralDaemon.orchestratorPublicUrl=ws://insecure/ws
refuses workflow-runner-validate.yaml "is not digest-pinned" --set image.daemon.tag=latest-daemon
# The controller asserts the digest and the scheme on every spawn, so both must
# still refuse with the admission policy switched off.
refuses workflow-runner-validate.yaml "is not digest-pinned" \
  --set workflowRunner.admission.enabled=false --set workflowRunner.admission.acknowledgeUnprotected=true --set image.daemon.tag=latest-daemon
refuses workflow-runner-validate.yaml "is neither wss:// plus a plain DNS host" \
  --set workflowRunner.admission.enabled=false --set workflowRunner.admission.acknowledgeUnprotected=true \
  --set config.ephemeralDaemon.orchestratorPublicUrl=ws://insecure/ws
# Plaintext is confined to a name that cannot resolve outside the cluster, so a
# public host must still be refused however well-formed it is.
refuses _helpers.tpl "is neither wss:// plus a plain DNS host" \
  --set workflowRunner.ingress.enabled=false \
  --set 'config.ephemeralDaemon.orchestratorPublicUrl=ws://orchestrator.example.com:3002/ws'
# The runner Ingress publishes the wss:// front door; a cluster-local dial-back
# never traverses it, so the combination is a misconfiguration, not dead weight.
refuses workflow-runner-ingress.yaml "is plaintext" \
  --set 'config.ephemeralDaemon.orchestratorPublicUrl=ws://github-app.github-app.svc.cluster.local:3002/ws'
refuses _helpers.tpl "is neither wss:// plus a plain DNS host" \
  --set 'config.ephemeralDaemon.orchestratorPublicUrl=wss://[2001:db8::1]/ws'
refuses _helpers.tpl "is neither wss:// plus a plain DNS host" \
  --set 'config.ephemeralDaemon.orchestratorPublicUrl=wss://git%68ub.example.com/ws'
refuses _helpers.tpl "is neither wss:// plus a plain DNS host" \
  --set 'config.ephemeralDaemon.orchestratorPublicUrl=wss://user:pass@github.example.com/ws'
refuses workflow-runner-boundary.yaml "requires config.model to be set explicitly" --set config.model=
refuses workflow-runner-validate.yaml "requires config.awsRegion" \
  --set config.provider=bedrock --set config.awsRegion=
refuses workflow-runner-validate.yaml "requires config.awsRegion" \
  --set workflowRunner.admission.enabled=false --set workflowRunner.admission.acknowledgeUnprotected=true \
  --set config.provider=bedrock --set config.awsRegion=
refuses workflow-runner-validate.yaml "is neither wss:// plus a plain DNS host" \
  --set workflowRunner.admission.enabled=false --set workflowRunner.admission.acknowledgeUnprotected=true \
  --set 'config.ephemeralDaemon.orchestratorPublicUrl=wss://user:pass@github.example.com/ws'
refuses workflow-runner-boundary.yaml "is not a chain the app emits for config.provider" \
  --set "workflowRunner.providerCredentials={A,B,C,D}"
# A chain the app really emits, but for the other provider: membership alone is
# not enough, the policy pairs the provider with the credential slots.
refuses workflow-runner-boundary.yaml "is not a chain the app emits for config.provider" \
  --set "workflowRunner.providerCredentials={AWS_BEARER_TOKEN_BEDROCK}"
refuses _helpers.tpl "the Anthropic credential cannot be derived" \
  --set secrets.anthropicApiKey= --set secrets.existingSecret=external
refuses _helpers.tpl "the Bedrock credential chain cannot be derived" \
  --set config.provider=bedrock --set config.awsRegion=us-east-1 \
  --set secrets.anthropicApiKey= --set secrets.existingSecret=external
refuses workflow-runner-networkpolicy.yaml "is a default route" \
  --set "workflowRunner.networkPolicy.extraEgressCidrs={0.0.0.0/0}"
refuses workflow-runner-networkpolicy.yaml "is a default route" \
  --set 'workflowRunner.networkPolicy.extraEgressCidrs={::/0}'
refuses workflow-runner-rbac.yaml "resolves to the controller ServiceAccount" \
  --set daemon.pools.shared.enabled=true --set daemon.serviceAccount.name=
refuses workflow-runner-rbac.yaml "would bind the namespace default ServiceAccount" \
  --set serviceAccount.create=false
refuses workflow-runner-namespace.yaml "which equals the ephemeral-daemon namespace" \
  --set workflowRunner.namespace=default --set config.ephemeralDaemon.namespace=default
refuses workflow-runner-namespace.yaml "equals the release namespace" \
  --namespace collide --set workflowRunner.namespace=collide \
  --set config.ephemeralDaemon.namespace=elsewhere
refuses workflow-runner-ingress.yaml "ingress.hosts is empty" --set ingress.hosts=null
refuses workflow-runner-ingress.yaml "ingress.tls is empty" --set ingress.tls=null
refuses workflow-runner-ingress.yaml "but ingress.enabled is false" --set ingress.enabled=false
# NOTES.txt is discarded by `helm template`, so an ArgoCD operator would never see
# a warning; disabling a boundary has to be refused at render instead.
refuses workflow-runner-validate.yaml "admission.enabled=false" --set workflowRunner.admission.enabled=false
refuses workflow-runner-validate.yaml "networkPolicy.enabled=false" --set workflowRunner.networkPolicy.enabled=false
refuses workflow-runner-ingress.yaml "is not in ingress.hosts" \
  --set config.ephemeralDaemon.orchestratorPublicUrl=wss://elsewhere.example.com/ws
# An empty node label or value renders runnerNodeLabel: "" into the boundary, which
# the policy's own second validation asserts against, so every runner Pod is denied.
# With the warmer on it instead surfaced as a raw YAML parse error from a bare
# `: "true"` mapping, which names neither the value nor the fix.
refuses workflow-runner-validate.yaml "workflowRunner.nodeLabel is empty" --set workflowRunner.nodeLabel=
refuses workflow-runner-validate.yaml "workflowRunner.nodeValue is empty" --set workflowRunner.nodeValue=
# A wildcard certificate is the common single-cert layout and DOES cover one label
# under its parent, so refusing it would reject a working front door. The guard has
# to keep refusing a name too deep for the wildcard.
if ! helm template contract "$chart" "${runner_on[@]}" \
  --set 'ingress.tls[0].hosts[0]=*.example.com' >/dev/null 2>&1; then
  echo "::error file=charts/github-app/templates/workflow-runner-ingress.yaml::wildcard TLS host refused; *.example.com covers github.example.com" >&2
  exit 1
fi
refuses workflow-runner-ingress.yaml "covered by no ingress.tls entry" \
  --set config.ephemeralDaemon.orchestratorPublicUrl=wss://a.b.example.com/ws \
  --set 'ingress.hosts[0].host=a.b.example.com' \
  --set 'ingress.tls[0].hosts[0]=*.example.com'
# A port is a 16-bit field. The URL patterns bound it to five digits, so 65536
# rendered here and then failed new URL(publicUrl) in the runner at startup.
refuses _helpers.tpl "is above 65535" \
  --set-string config.ephemeralDaemon.orchestratorPublicUrl=wss://github.example.com:65536/ws
# Route- and certificate-scoped annotations must NOT be inherited onto the ws
# Ingress, while the allowlist/WAF ones this inheritance exists for must be.
ann=$(helm template contract "$chart" "${runner_on[@]}" \
  --set 'ingress.annotations.kubernetes\.io/tls-acme=true' \
  --set 'ingress.annotations.nginx\.ingress\.kubernetes\.io/rewrite-target=/' \
  --set 'ingress.annotations.nginx\.ingress\.kubernetes\.io/whitelist-source-range=10.0.0.0/8' |
  yq ea 'select(.kind == "Ingress" and (.metadata.name | test("-ws$"))) | .metadata.annotations | keys | .[]')
for key in kubernetes.io/tls-acme nginx.ingress.kubernetes.io/rewrite-target; do
  if printf '%s\n' "$ann" | grep -qx "$key"; then
    echo "::error file=charts/github-app/templates/workflow-runner-ingress.yaml::ws Ingress inherited route/cert-scoped annotation $key" >&2
    exit 1
  fi
done
if ! printf '%s\n' "$ann" | grep -qx nginx.ingress.kubernetes.io/whitelist-source-range; then
  echo "::error file=charts/github-app/templates/workflow-runner-ingress.yaml::ws Ingress dropped the allowlist annotation inheritance exists for" >&2
  exit 1
fi
# A chart-managed daemon identity must not depend on the controller SA also being
# chart-managed: workflow-runner-rbac.yaml pushes operators onto exactly that path.
sa=$(helm template contract "$chart" "${runner_on[@]}" --values "$chart/ci/daemon-pools-values.yaml" \
  --set daemon.serviceAccount.create=true --set serviceAccount.create=false --set serviceAccount.name=byo-controller |
  yq ea 'select(.kind == "ServiceAccount") | .metadata.name')
if [ "$sa" != "github-app-daemon" ]; then
  echo "::error file=charts/github-app/templates/serviceaccount.yaml::daemon ServiceAccount not rendered with a BYO controller SA (got: ${sa:-none})" >&2
  exit 1
fi

# 14. Admission off leaves the namespace and egress boundary, drops policy + params.
helm template contract "$chart" "${runner_on[@]}" --set workflowRunner.admission.enabled=false --set workflowRunner.admission.acknowledgeUnprotected=true > "$tmp/no-admission.yaml"
left=$(yq ea -r '
  select(
    .kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding" or
    (.metadata.name // "") == "workflow-runner-boundary"
  ) | .kind + "/" + .metadata.name' "$tmp/no-admission.yaml")
if [ -n "$left" ]; then
  echo "workflowRunner.admission.enabled=false still rendered the policy or its params" >&2
  exit 1
fi
if ! yq ea -r 'select(.kind == "NetworkPolicy") | .metadata.name' "$tmp/no-admission.yaml" | grep -q workflow-runner; then
  echo "workflowRunner.admission.enabled=false dropped the egress boundary as well" >&2
  exit 1
fi

# 15. Ephemeral-daemon Secret name. Left unrendered when empty so the app owns
#     the default (daemon-secrets); a chart-side literal would drift from it.
if grep -q 'EPHEMERAL_DAEMON_SECRET_NAME' "$tmp/default.yaml"; then
  echo "config.ephemeralDaemon.secretName is empty but EPHEMERAL_DAEMON_SECRET_NAME still rendered; the chart would pin a default the app owns" >&2
  exit 1
fi
got=$(helm template contract "$chart" --set config.ephemeralDaemon.secretName=shared-daemon-secrets \
  | yq ea -r 'select(.kind == "ConfigMap") | .data.EPHEMERAL_DAEMON_SECRET_NAME // ""' | grep -v '^$')
if [ "$got" != "shared-daemon-secrets" ]; then
  echo "config.ephemeralDaemon.secretName rendered '$got', want 'shared-daemon-secrets'" >&2
  exit 1
fi

# 16. Bun does not honour the Kubernetes client's own CA, so the controller needs
#     NODE_EXTRA_CA_CERTS or every Pod spawn fails TLS verification. Daemons never
#     call that API, so it stays off them.
ctrl=$(yq ea -r 'select(.kind == "Deployment" and .metadata.name == "contract-github-app")
  | .spec.template.spec.containers[0].env[] | select(.name == "NODE_EXTRA_CA_CERTS") | .value' "$tmp/default.yaml")
if [ "$ctrl" != "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" ]; then
  echo "controller NODE_EXTRA_CA_CERTS rendered '$ctrl'; without the in-cluster CA every K8s API call fails UNABLE_TO_VERIFY_LEAF_SIGNATURE" >&2
  exit 1
fi
if yq ea -r 'select(.kind == "Deployment" and .metadata.name != "contract-github-app")
  | .spec.template.spec.containers[].env[]? | select(.name == "NODE_EXTRA_CA_CERTS") | .name' "$tmp/pools.yaml" | grep -q NODE_EXTRA_CA_CERTS; then
  echo "daemon pools rendered NODE_EXTRA_CA_CERTS; daemons never call the Kubernetes API" >&2
  exit 1
fi

# 17. Runner image warmer. Two invariants, both silent failures if broken.
#     It must never land in the runner namespace, whose fail-closed admission
#     policy admits only a Pod named for an exact attempt identity, and its image
#     must be the same reference the controller hands kubelet as DAEMON_IMAGE. A
#     warmer on any other digest pulls a layer set no attempt asks for, so the
#     stall returns with nothing reporting that it did.
helm template contract "$chart" "${runner_on[@]}" --namespace release-ns \
  --set workflowRunner.imageWarmer.enabled=true > "$tmp/warmer.yaml"
warmer_ns=$(yq ea -r 'select(.kind == "DaemonSet" and (.metadata.name | test("runner-image-warmer"))) | .metadata.namespace' "$tmp/warmer.yaml")
if [ "$warmer_ns" != "release-ns" ]; then
  echo "runner image warmer rendered into namespace '$warmer_ns'; the runner namespace admission policy denies every Pod that is not an exact attempt" >&2
  exit 1
fi
warmer_img=$(yq ea -r 'select(.kind == "DaemonSet" and (.metadata.name | test("runner-image-warmer"))) | .spec.template.spec.containers[0].image' "$tmp/warmer.yaml")
daemon_img=$(yq ea -r 'select(.kind == "ConfigMap" and .data.DAEMON_IMAGE != null) | .data.DAEMON_IMAGE' "$tmp/warmer.yaml" | head -1)
if [ "$warmer_img" != "$daemon_img" ]; then
  echo "runner image warmer pulls '$warmer_img' but DAEMON_IMAGE is '$daemon_img'; the warmed digest must be the one the controller spawns" >&2
  exit 1
fi
# The override DAEMON_IMAGE honours has to move the warmer with it.
over="ghcr.io/example/runner@sha256:$(printf 'b%.0s' $(seq 64))"
warmer_img=$(helm template contract "$chart" "${runner_on[@]}" \
  --set workflowRunner.imageWarmer.enabled=true --set "config.ephemeralDaemon.image=$over" \
  | yq ea -r 'select(.kind == "DaemonSet" and (.metadata.name | test("runner-image-warmer"))) | .spec.template.spec.containers[0].image')
if [ "$warmer_img" != "$over" ]; then
  echo "config.ephemeralDaemon.image moved DAEMON_IMAGE but the warmer still pulls '$warmer_img'" >&2
  exit 1
fi
# The warmer lives in the release namespace, so it must pull with that
# namespace's secrets. workflowRunner.imagePullSecret names a Secret in the
# runner namespace that a Pod here cannot read, and the failure is silent:
# ImagePullBackOff on the warmer, no warming, no signal.
warmer_pull=$(helm template contract "$chart" "${runner_on[@]}" \
  --set workflowRunner.imageWarmer.enabled=true \
  --set "imagePullSecrets[0].name=release-ns-pull" \
  --set workflowRunner.imagePullSecret=runner-ns-pull \
  | yq ea -r 'select(.kind == "DaemonSet" and (.metadata.name | test("runner-image-warmer"))) | .spec.template.spec.imagePullSecrets[].name')
if [ "$warmer_pull" != "release-ns-pull" ]; then
  echo "runner image warmer pulls with '$warmer_pull'; it runs in the release namespace and cannot read a Secret in the runner namespace" >&2
  exit 1
fi

# Off by default, and refused without the rail it exists to serve.
if grep -q 'runner-image-warmer' "$tmp/default.yaml"; then
  echo "runner image warmer rendered with workflowRunner.imageWarmer.enabled unset" >&2
  exit 1
fi
refuses workflow-runner-image-warmer.yaml "requires workflowRunner.enabled" \
  --set workflowRunner.enabled=false --set workflowRunner.imageWarmer.enabled=true

# 18. The two halves of the runner config surface.
#     With the rail on, the chart pins the admission boundary from workflowRunner.*,
#     so a config.workflowRunner.* passthrough that disagrees must be refused: the
#     controller and the policy would differ and every runner Pod would be denied
#     at admission, which produces no chart-level signal at all.
refuses configmap.yaml "conflicts with workflowRunner.nodeValue" \
  --set config.workflowRunner.nodeValue=definitely-not-true
refuses configmap.yaml "conflicts with workflowRunner.imagePullSecret" \
  --set config.workflowRunner.imagePullSecret=some-other-registry-credentials
# Equal values are not a disagreement; the guard must not be unconditionally strict.
helm template contract "$chart" "${runner_on[@]}" \
  --set config.workflowRunner.imagePullSecret=runner-registry-credentials > /dev/null

#     With the rail off, those four keys are the operator's way to point the
#     controller at a rail they provisioned themselves. Empty must render nothing,
#     so the app keeps ownership of its own defaults.
if grep -qE '^\s+WORKFLOW_RUNNER_(NAMESPACE|NODE_LABEL|NODE_VALUE|IMAGE_PULL_SECRET):' "$tmp/default.yaml"; then
  echo "config.workflowRunner.* is empty but runner env still rendered; the app owns those defaults" >&2
  exit 1
fi
got=$(helm template contract "$chart" \
  --set config.workflowRunner.namespace=byo-runners \
  --set config.workflowRunner.nodeLabel=byo/runner \
  --set config.workflowRunner.nodeValue=yes \
  | yq ea -o=json -I=0 'select(.kind == "ConfigMap" and .data.WORKFLOW_RUNNER_NAMESPACE != null)
      | [.data.WORKFLOW_RUNNER_NAMESPACE, .data.WORKFLOW_RUNNER_NODE_LABEL,
         .data.WORKFLOW_RUNNER_NODE_VALUE, .data.WORKFLOW_RUNNER_IMAGE_PULL_SECRET // ""]')
if [ "$got" != '["byo-runners","byo/runner","yes",""]' ]; then
  echo "config.workflowRunner.* passthrough rendered $got" >&2
  exit 1
fi
#     The namespace collision resolves through the shared runnerNamespace helper,
#     so it is caught on the passthrough too. workflow-runner-namespace.yaml used to
#     hardcode the app default here and both missed this and refused valid configs.
refuses workflow-runner-namespace.yaml "WORKFLOW_RUNNER_NAMESPACE=\"agents\"" \
  --set workflowRunner.enabled=false \
  --set config.workflowRunner.namespace=agents \
  --set config.ephemeralDaemon.namespace=agents

# 19. Repo-config filename. Both keys stay unrendered by default: the app reads
#     REPO_CONFIG_FILE first, so a chart default for it would silently shadow a
#     pre-1.17 schedulerConfigFile override the moment an operator upgrades.
if grep -qE '^\s+(REPO|SCHEDULER)_CONFIG_FILE:' "$tmp/default.yaml"; then
  echo "repoConfigFile/schedulerConfigFile are empty but a *_CONFIG_FILE key still rendered" >&2
  exit 1
fi
got=$(helm template contract "$chart" --set config.schedulerConfigFile=.legacy.yaml \
  | yq ea -o=json -I=0 'select(.kind == "ConfigMap" and .data.SCHEDULER_CONFIG_FILE != null)
      | [.data.SCHEDULER_CONFIG_FILE, .data.REPO_CONFIG_FILE // ""]')
if [ "$got" != '[".legacy.yaml",""]' ]; then
  echo "legacy schedulerConfigFile override rendered $got; REPO_CONFIG_FILE must stay unset" >&2
  exit 1
fi

echo "github-app render matrix: all cases rendered"

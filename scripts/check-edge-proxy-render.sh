#!/usr/bin/env bash
#
# Render matrix for the edge-proxy chart.
#
# Covers the conditional branches a single `helm template` does not: the
# placeholder-tag and missing-Secret guards, the generated and supplied
# Secrets, migrations off, the PodDisruptionBudget at one replica, extra env
# rendering, and the wiring of the bundled CloudNativePG Postgres and Valkey. Every --set flag is a static
# literal, so the script has no injection surface when driven from CI.
#
# Dependencies: helm and yq, and network access to fetch the Valkey subchart.
#
# Run from anywhere:  bash scripts/check-edge-proxy-render.sh
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/edge-proxy"
values="$chart/ci/ct-values.yaml"

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

# Subcharts are not committed. See check-chart-schemas.sh for update over build.
helm dependency update "$chart" >/dev/null

fail() { # <file> <message>
  echo "::error file=$1::$2"
  exit 1
}

# expect_fail <message substring> <helm args...>: the render must fail, and for
# the stated reason rather than any error.
expect_fail() {
  local want=$1 out
  shift
  if out=$(helm template "$chart" -f "$values" "$@" 2>&1); then
    fail scripts/check-edge-proxy-render.sh "render with $* must fail with '$want'"
  fi
  grep -qF "$want" <<<"$out" || fail scripts/check-edge-proxy-render.sh "render with $* failed for the wrong reason: $out"
}

# 1. Fixture renders, and edge and admin read the same ConfigMap. Admin
#    validates policy against it, so two sources could drift apart.
helm lint "$chart" -f "$values"
helm template "$chart" -f "$values" > "$rendered"
cm=$(yq e 'select(.kind == "ConfigMap" and .metadata.labels."app.kubernetes.io/component" != "log-shipper") | .metadata.name' "$rendered")
refs=$(yq e -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].envFrom[0].configMapRef.name' "$rendered" | sort -u)
[ "$refs" = "$cm" ] || fail charts/edge-proxy/templates/configmap.yaml "edge and admin must both load ConfigMap '$cm', got: $refs"

# 2. Without an explicit tag the 0.0.0 placeholder would deploy an image that
#    does not exist. The migrate init container and admin share admin.image.
#    Once a release replaces the placeholder, an empty tag follows appVersion.
appver=$(yq e '.appVersion' "$chart/Chart.yaml")
if [ "$appver" = "0.0.0" ]; then
  expect_fail "edge.image.tag is required" --set edge.image.tag=
  expect_fail "admin.image.tag is required" --set admin.image.tag=
else
  images=$(helm template "$chart" -f "$values" --set edge.image.tag= --set admin.image.tag= \
    | yq e -N 'select(.kind == "Deployment") | .spec.template.spec | ((.initContainers // []).[].image, .containers[].image)' - | sort -u)
  for want in "chrisleekr/edge-proxy:$appver" "chrisleekr/edge-proxy-admin:$appver"; do
    grep -qxF "$want" <<<"$images" || fail charts/edge-proxy/templates/_helpers.tpl "an empty image tag must render $want, got: $images"
  done
fi

# 3. Secrets and required config fail the render instead of producing pods that
#    wait or crash.
expect_fail "edge.existingSecret is required when bootstrap.generateSecrets=false" --set bootstrap.generateSecrets=false --set logShipper.existingSecret=logs
expect_fail "admin.existingSecret with DATABASE_URL, AUDIT_HMAC_KEY_ID and AUDIT_HMAC_KEY is required" --set admin.existingSecret=
expect_fail "migrations.existingSecret is required" --set migrations.existingSecret=
expect_fail "config.clientIPSource is required" --set config.clientIPSource=
expect_fail "config.upstreamURL is required" --set config.upstreamURL=
expect_fail "config.trustedProxies is required unless config.clientIPSource is remote_addr" --set config.trustedProxies= --set config.clientIPSource=xff
expect_fail "config.ingressSecretHeader needs edge.existingSecret" --set config.ingressSecretHeader=X-Origin-Secret --set edge.existingSecret=
# A setting from before the single upstream fails instead of being ignored.
expect_fail "additional properties 'upstreams' not allowed" --set config.upstreams=app=http://app

# 4. Migrations off renders no init container and no longer needs its Secret.
helm template "$chart" -f "$values" \
  --set migrations.enabled=false --set migrations.existingSecret= > "$rendered"
[ "$(yq e -N 'select(.kind == "Deployment") | .spec.template.spec.initContainers | length' "$rendered" | sort -u)" = "0" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "migrations.enabled=false must render no init container"

# 5. The PodDisruptionBudget allows one pod at a time, so it scales with the
#    replica count and never blocks draining a single replica. EXPECTED_REPLICAS
#    follows the count.
helm template "$chart" -f "$values" --set edge.replicas=1 > "$rendered"
pdb=$(yq e -N 'select(.kind == "PodDisruptionBudget") | .spec | (.maxUnavailable // "") + "/" + (.minAvailable // "" | tostring)' "$rendered")
[ "$pdb" = "1/" ] || fail charts/edge-proxy/templates/edge-pdb.yaml "the PodDisruptionBudget must be maxUnavailable 1 only, got '$pdb'"
expected=$(yq e 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "edge") | .spec.template.spec.containers[0].env[] | select(.name == "EXPECTED_REPLICAS") | .value' "$rendered")
[ "$expected" = "1" ] || fail charts/edge-proxy/templates/edge-deployment.yaml "EXPECTED_REPLICAS must follow edge.replicas, got '$expected'"

# 6. edge.env values render as strings; an unquoted number is rejected by the API server.
helm template "$chart" -f "$values" --set-json 'edge.env={"MAX_STREAMS":2000}' > "$rendered"
streams=$(yq e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].env[] | select(.name == "MAX_STREAMS") | .value | tag' "$rendered")
[ "$streams" = "!!str" ] || fail charts/edge-proxy/templates/_helpers.tpl "edge.env values must render as strings, got tag '$streams'"

# 7. Bundled Postgres. Migrate reads the owner URL from the operator's
#    <cluster>-app Secret, admin connects to <cluster>-rw as the runtime role,
#    and no migration Secret is needed. Wrong names here leave admin waiting on
#    a Secret or Service that never appears.
expect_fail "postgres.cnpg.runtimeRoleSecret is required when bootstrap.generateSecrets=false" \
  --set postgres.cnpg.enabled=true --set bootstrap.generateSecrets=false --set edge.existingSecret=edge --set logShipper.existingSecret=logs
helm template "$chart" -f "$values" --set postgres.cnpg.enabled=true \
  --set postgres.cnpg.runtimeRoleSecret=pg-runtime --set migrations.existingSecret= > "$rendered"
cluster=$(yq e -N 'select(.kind == "Cluster") | .metadata.name' "$rendered")
admin=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "admin") | .spec.template.spec' "$rendered")
owner=$(yq e '.initContainers[0].env[] | select(.name == "MIGRATION_DATABASE_URL") | .valueFrom.secretKeyRef.name + ":" + .valueFrom.secretKeyRef.key' <<<"$admin")
[ "$owner" = "$cluster-app:uri" ] || fail charts/edge-proxy/templates/admin-deployment.yaml "migrate must read $cluster-app:uri, got '$owner'"
url=$(yq e '.containers[0].env[] | select(.name == "DATABASE_URL") | .value' <<<"$admin")
[ "$url" = "postgres://$cluster-rw:5432/edge_admin" ] || fail charts/edge-proxy/templates/admin-deployment.yaml "DATABASE_URL must target $cluster-rw, got '$url'"
role=$(yq e -N 'select(.kind == "Cluster") | .spec.managed.roles[0].name' "$rendered")
[ "$role" = "edge_app" ] || fail charts/edge-proxy/templates/postgres-cluster.yaml "the managed role must be migrations.runtimeRole, got '$role'"

# 8. Bundled Valkey. The edge URL must name the subchart's Service, the edge
#    Secret must no longer supply VALKEY_URL (a duplicate env name), and the
#    subchart's NetworkPolicy must admit the edge pods.
helm template "$chart" -f "$values" --set valkey.enabled=true > "$rendered"
svc=$(yq e -N 'select(.kind == "Service" and .metadata.labels."app.kubernetes.io/name" == "valkey" and .spec.clusterIP != "None") | .metadata.name' "$rendered" | head -1)
edge=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "edge") | .spec.template' "$rendered")
vurl=$(yq e '[.spec.containers[0].env[] | select(.name == "VALKEY_URL")] | .[] | .value' <<<"$edge")
[ "$vurl" = "valkey://$svc:6379" ] || fail charts/edge-proxy/templates/edge-deployment.yaml "VALKEY_URL must be valkey://$svc:6379, got '$vurl'"
allowed=$(yq e -N 'select(.kind == "NetworkPolicy") | .spec.ingress[0].from[0].podSelector.matchLabels | to_entries | .[] | .key + "=" + .value' "$rendered")
while IFS= read -r pair; do
  [ "$(yq e ".metadata.labels.\"${pair%%=*}\"" <<<"$edge")" = "${pair#*=}" ] \
    || fail charts/edge-proxy/values.yaml "valkey.networkPolicy selector $pair does not match the edge pods"
done <<<"$allowed"
# valkey.nameOverride renames the subchart's Service, and VALKEY_URL must follow.
helm template "$chart" -f "$values" --set valkey.enabled=true --set valkey.nameOverride=kv > "$rendered"
svc=$(yq e -N 'select(.kind == "Service" and .metadata.labels."app.kubernetes.io/name" == "kv" and .spec.clusterIP != "None") | .metadata.name' "$rendered" | head -1)
vurl=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "edge") | .spec.template.spec.containers[0].env[] | select(.name == "VALKEY_URL") | .value' "$rendered")
[ -n "$svc" ] && [ "$vurl" = "valkey://$svc:6379" ] || fail charts/edge-proxy/templates/_helpers.tpl "with valkey.nameOverride, VALKEY_URL must be valkey://$svc:6379, got '$vurl'"
# nameOverride renames the edge pods but not the subchart's literal selector.
expect_fail "nameOverride changes the edge pods' app.kubernetes.io/name" --set valkey.enabled=true --set nameOverride=ep

# 9. Defaults that keep the edge up. No startup probe: one on /readyz kills a
#    pod that is correctly waiting for its first policy while admin is down.
#    Pods spread over zones and nodes by default, and [] turns that off. Both
#    workloads run as the chart's ServiceAccount.
helm template "$chart" -f "$values" > "$rendered"
edge=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "edge") | .spec.template.spec' "$rendered")
[ "$(yq e '.containers[0] | has("startupProbe")' <<<"$edge")" = "false" ] \
  || fail charts/edge-proxy/templates/edge-deployment.yaml "the edge must have no startup probe"
keys=$(yq e '[.topologySpreadConstraints[].topologyKey] | join(",")' <<<"$edge")
[ "$keys" = "topology.kubernetes.io/zone,kubernetes.io/hostname" ] \
  || fail charts/edge-proxy/templates/_helpers.tpl "default edge spread must cover zone and hostname, got '$keys'"
sa=$(yq e -N 'select(.kind == "ServiceAccount" and .metadata.labels."app.kubernetes.io/component" != "bootstrap" and .metadata.labels."app.kubernetes.io/component" != "log-shipper") | .metadata.name' "$rendered")
used=$(yq e -N 'select(.kind == "Deployment") | .spec.template.spec.serviceAccountName' "$rendered" | sort -u)
[ -n "$sa" ] && [ "$used" = "$sa" ] || fail charts/edge-proxy/templates/serviceaccount.yaml "both workloads must use ServiceAccount '$sa', got '$used'"
helm template "$chart" -f "$values" --set-json 'edge.topologySpreadConstraints=[]' > "$rendered"
[ "$(yq e -N 'select(.kind == "Deployment") | .spec.template.spec | has("topologySpreadConstraints")' "$rendered" | sort -u)" = "false" ] \
  || fail charts/edge-proxy/templates/_helpers.tpl "edge.topologySpreadConstraints=[] must render none"

# 10. Memory guards. Admin bounds concurrent sign-in hashes (19 MiB each, run
#     before authentication) through GOMAXPROCS, and setting another env key
#     must not drop it. The bundled Valkey caps its memory below its limit.
helm template "$chart" -f "$values" --set admin.env.FOO=bar --set valkey.enabled=true > "$rendered"
procs=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "admin") | .spec.template.spec.containers[0].env[] | select(.name == "GOMAXPROCS") | .value' "$rendered")
[ "$procs" = "2" ] || fail charts/edge-proxy/values.yaml "admin GOMAXPROCS must survive extra admin.env keys, got '$procs'"
conf=$(yq e -N 'select(.kind == "ConfigMap" and .metadata.labels."app.kubernetes.io/name" == "valkey") | .data."valkey.conf"' "$rendered")
grep -q '^maxmemory ' <<<"$conf" || fail charts/edge-proxy/values.yaml "the bundled Valkey must set maxmemory"

# 11. Integrations, all on. The edge NetworkPolicy admits only the listed
#     gateway peers on http; admin admits the edge pods; the DestinationRule
#     names the edge Service's FQDN. A wrong name in any of them silently does
#     nothing.
integrations="$chart/ci/integrations-values.yaml"
# An explicit namespace: helm template otherwise takes the kube context's,
# which differs between a laptop and a CI runner.
helm template "$chart" -f "$integrations" --namespace edge-ci > "$rendered"
edge_svc=$(yq e -N 'select(.kind == "Service" and .metadata.labels."app.kubernetes.io/component" == "edge") | .metadata.name' "$rendered")
admin_from=$(yq e -N 'select(.kind == "NetworkPolicy" and .metadata.labels."app.kubernetes.io/component" == "admin") | .spec.ingress[0].from[0].podSelector.matchLabels."app.kubernetes.io/component"' "$rendered")
[ "$admin_from" = "edge" ] || fail charts/edge-proxy/templates/networkpolicy.yaml "admin must admit the edge pods, got '$admin_from'"
host=$(yq e -N 'select(.kind == "DestinationRule") | .spec.host' "$rendered")
[ "$host" = "$edge_svc.edge-ci.svc.cluster.local" ] || fail charts/edge-proxy/templates/destinationrule.yaml "DestinationRule host must be the edge Service FQDN, got '$host'"
expect_fail "networkPolicy.edgeFrom is empty" --set networkPolicy.enabled=true
expect_fail "networkPolicy.metricsFrom is empty while metrics.serviceMonitor.enabled" -f "$integrations" --set networkPolicy.metricsFrom=null
expect_fail "networkPolicy.adminFrom is empty while route.admin.enabled" -f "$integrations" --set networkPolicy.adminFrom=null
# With the header set, a Secret missing its values must stop the pod, not start it.
optional=$(helm template "$chart" -f "$integrations" --set config.ingressSecretHeader=X-Origin-Secret \
  | yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "edge") | .spec.template.spec.containers[0].env[] | select(.name == "INGRESS_SECRET_VALUES") | .valueFrom.secretKeyRef.optional' -)
[ "$optional" = "false" ] || fail charts/edge-proxy/templates/edge-deployment.yaml "INGRESS_SECRET_VALUES must be required with config.ingressSecretHeader, got optional '$optional'"

# 12. Alerts match the series a ServiceMonitor scrape labels with this edge
#     Service, and refuse to render without that ServiceMonitor, where they
#     would never fire.
sel=$(yq e -N 'select(.kind == "PrometheusRule") | .spec.groups[0].rules[0].expr' "$rendered")
grep -qF "service=\"$edge_svc\"" <<<"$sel" || fail charts/edge-proxy/templates/prometheusrule.yaml "alerts must select service=\"$edge_svc\", got: $sel"
expect_fail "metrics.prometheusRule.enabled needs metrics.serviceMonitor.enabled" --set metrics.prometheusRule.enabled=true

# 13. The oauth2-proxy gate lives in the gateway's namespace, targets the
#     Gateway, and covers each admin host with and without a port. It cannot
#     be enabled without the route whose hosts it matches.
gate=$(yq e -N 'select(.kind == "AuthorizationPolicy")' "$rendered")
[ "$(yq e '.metadata.namespace + "/" + .spec.targetRefs[0].name + "/" + .spec.action' <<<"$gate")" = "gateway-system/public/CUSTOM" ] \
  || fail charts/edge-proxy/templates/admin-route.yaml "the gate must be a CUSTOM policy on gateway-system/public"
[ "$(yq e '.spec.rules[0].to[0].operation.hosts | join(",")' <<<"$gate")" = "admin.example.com,admin.example.com:*" ] \
  || fail charts/edge-proxy/templates/admin-route.yaml "the gate must match each admin host with and without a port"
expect_fail "route.admin.oauth2Proxy.enabled needs route.admin.enabled" --set route.admin.oauth2Proxy.enabled=true
# A route on another Gateway would serve admin without the gate.
expect_fail "but route.admin.oauth2Proxy.gateway is gateway-system/public" -f "$integrations" --set 'route.admin.parentRefs[0].name=private'
# A wildcard host would need a pattern Istio cannot match once a port is added.
helm template "$chart" -f "$integrations" --set 'route.admin.hostnames[0]=*.example.com' > /dev/null 2>"$rendered" \
  && fail charts/edge-proxy/templates/admin-route.yaml "the gate must refuse a wildcard hostname"
grep -qF "does not support the wildcard hostname" "$rendered" \
  || fail charts/edge-proxy/templates/admin-route.yaml "a wildcard hostname failed for the wrong reason: $(cat "$rendered")"

# 14. Default install: every Secret generated. The hook Job must create exactly
#     the Secrets the pods and the CloudNativePG Cluster read, before them, with
#     a Role that cannot read Secrets. A name mismatch leaves pods waiting in
#     ContainerCreating for a Secret nothing creates.
helm template "$chart" -f "$chart/ci/bundled-values.yaml" > "$rendered"
job=$(yq e -N 'select(.kind == "Job")' "$rendered")
job_env() { yq e ".spec.template.spec.containers[0].env[] | select(.name == \"$1\") | .value" <<<"$job"; }
edge_secret=$(job_env EDGE_SECRET)
admin_secret=$(job_env ADMIN_SECRET)
pg_secret=$(job_env PG_SECRET)
[ -n "$edge_secret" ] && [ -n "$admin_secret" ] && [ -n "$pg_secret" ] && [ "$edge_secret" != "$admin_secret" ] \
  || fail charts/edge-proxy/templates/bootstrap-secrets.yaml "the Job must name three distinct Secrets, got '$edge_secret', '$admin_secret' and '$pg_secret'"
[ "$(yq e '.metadata.annotations."helm.sh/hook"' <<<"$job")" = "pre-install,pre-upgrade" ] \
  || fail charts/edge-proxy/templates/bootstrap-secrets.yaml "the Job must be a pre-install,pre-upgrade hook"
[ "$(yq e -N -o=json -I=0 'select(.kind == "Role") | .rules' "$rendered")" = '[{"apiGroups":[""],"resources":["secrets"],"verbs":["create"]}]' ] \
  || fail charts/edge-proxy/templates/bootstrap-secrets.yaml "the Job's Role must only create Secrets"
edge=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "edge") | .spec.template.spec' "$rendered")
# The edge pod references no other Secret, so an edge node never receives
# admin's password or audit key.
[ "$(yq e '.volumes[] | select(.name == "token") | .secret.secretName' <<<"$edge")" = "$edge_secret" ] \
  || fail charts/edge-proxy/templates/edge-deployment.yaml "the edge token must come from $edge_secret"
[ "$(yq e '[.containers[0].env[] | select(.valueFrom.secretKeyRef)] | length' <<<"$edge")" = "0" ] \
  || fail charts/edge-proxy/templates/edge-deployment.yaml "without edge.existingSecret the edge must reference no other Secret"
admin=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "admin") | .spec.template.spec' "$rendered")
admin_env() { yq e ".containers[0].env[] | select(.name == \"$1\") | (.value // .valueFrom.secretKeyRef.name)" <<<"$admin"; }
[ "$(admin_env AUDIT_HMAC_KEY)" = "$admin_secret" ] || fail charts/edge-proxy/templates/admin-deployment.yaml "the audit key must come from $admin_secret"
[ "$(admin_env PGPASSWORD)" = "$pg_secret" ] || fail charts/edge-proxy/templates/admin-deployment.yaml "PGPASSWORD must come from $pg_secret"
# DATABASE_URL has no user, so without PGUSER admin connects as the OS user.
[ "$(yq e '.containers[0].env[] | select(.name == "PGUSER") | .valueFrom.secretKeyRef.name + ":" + .valueFrom.secretKeyRef.key' <<<"$admin")" = "$pg_secret:username" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "PGUSER must come from $pg_secret:username"
[ "$(yq e -N 'select(.kind == "Cluster") | .spec.managed.roles[0].passwordSecret.name' "$rendered")" = "$pg_secret" ] \
  || fail charts/edge-proxy/templates/postgres-cluster.yaml "the runtime role password must come from $pg_secret"
[ "$(admin_env BOOTSTRAP_ADMIN_USERNAME)/$(admin_env BOOTSTRAP_PUBLISH_DEFAULT)" = "admin/true" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "admin must bootstrap user admin and the starter policy"
# Each file admin reads must be a projected item from the right Secret.
mount=$(yq e '.containers[0].volumeMounts[] | select(.name == "secrets") | .mountPath' <<<"$admin")
files=$(yq e '.volumes[] | select(.name == "secrets") | .projected.sources[] | .secret.name + ":" + .secret.items[0].key + ":" + .secret.items[0].path' <<<"$admin" | sort | tr '\n' ' ')
[ "$files" = "$admin_secret:ADMIN_PASSWORD:admin-password $edge_secret:EDGE_SERVICE_TOKEN:edge-token " ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "admin's secret files are wrong: $files"
[ "$(admin_env BOOTSTRAP_ADMIN_PASSWORD_FILE) $(admin_env EDGE_SERVICE_TOKEN_FILE)" = "$mount/admin-password $mount/edge-token" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "admin's file variables must point into $mount"

# 15. An existingSecret replaces the generated one for its component, and edge
#     and admin agree on the edge token.
helm template "$chart" -f "$integrations" > "$rendered"
edge=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "edge") | .spec.template.spec' "$rendered")
admin=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "admin") | .spec.template.spec' "$rendered")
[ "$(yq e '.volumes[] | select(.name == "token") | .secret.secretName' <<<"$edge")" = "edge-proxy-ci-edge" ] \
  || fail charts/edge-proxy/templates/edge-deployment.yaml "edge.existingSecret must supply the edge token"
[ "$(yq e '.volumes[] | select(.name == "secrets") | .projected.sources[] | select(.secret.items[0].key == "EDGE_SERVICE_TOKEN") | .secret.name' <<<"$admin")" = "edge-proxy-ci-edge" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "admin must accept the token from edge.existingSecret"
[ "$(admin_env AUDIT_HMAC_KEY)" = "edge-proxy-ci-admin" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "admin.existingSecret must supply the audit key"

# 16. generateSecrets off is the manual flow: no hook, and admin neither waits
#     for the edge Secret, which is created after admin is up, nor bootstraps a
#     user.
helm template "$chart" -f "$values" --set bootstrap.generateSecrets=false --set edge.existingSecret=edge --set logShipper.existingSecret=logs > "$rendered"
[ -z "$(yq e -N 'select(.kind == "Job" or .kind == "Role")' "$rendered")" ] \
  || fail charts/edge-proxy/templates/bootstrap-secrets.yaml "generateSecrets=false must render no hook"
admin=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "admin") | .spec.template.spec' "$rendered")
[ "$(yq e '[.volumes // [] | .[] | select(.name == "secrets")] | length' <<<"$admin")/$(admin_env BOOTSTRAP_ADMIN_USERNAME)" = "0/" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "generateSecrets=false must mount no edge token and bootstrap no user in admin"

# 17. Log shipper, on by default. It must read only this release's edge pods,
#     post to this release's admin Service, and hold the token admin reads;
#     admin's NetworkPolicy must admit it. A mismatch ships nothing, silently.
helm template "$chart" -f "$chart/ci/bundled-values.yaml" --namespace edge-ci > "$rendered"
ds=$(yq e -N 'select(.kind == "DaemonSet")' "$rendered")
vector=$(yq e -N 'select(.kind == "ConfigMap" and .metadata.labels."app.kubernetes.io/component" == "log-shipper") | .data."vector.yaml"' "$rendered")
edge=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "edge") | .spec.template' "$rendered")
admin=$(yq e -N 'select(.kind == "Deployment" and .spec.template.metadata.labels."app.kubernetes.io/component" == "admin") | .spec.template.spec' "$rendered")
admin_svc=$(yq e -N 'select(.kind == "Service" and .metadata.labels."app.kubernetes.io/component" == "admin") | .metadata.name' "$rendered")
selector=$(yq e '.sources.edge.extra_label_selector' <<<"$vector")
for pair in ${selector//,/ }; do
  [ "$(yq e ".metadata.labels.\"${pair%%=*}\"" <<<"$edge")" = "${pair#*=}" ] \
    || fail charts/edge-proxy/templates/log-shipper.yaml "the shipper's selector $pair does not match the edge pods"
done
[ "$(yq e '.sources.edge.extra_field_selector' <<<"$vector")" = "metadata.namespace=edge-ci" ] \
  || fail charts/edge-proxy/templates/log-shipper.yaml "the shipper must read only this release's namespace"
[ "$(yq e '.sinks.admin.uri' <<<"$vector")" = "http://$admin_svc.edge-ci.svc:8081/v1/logs/access" ] \
  || fail charts/edge-proxy/templates/log-shipper.yaml "the shipper must post to $admin_svc"
logs_secret=$(yq e -N 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "LOGS_SECRET") | .value' "$rendered")
[ -n "$logs_secret" ] && [ "$(yq e '.spec.template.spec.volumes[] | select(.name == "log-token") | .secret.secretName' <<<"$ds")" = "$logs_secret" ] \
  || fail charts/edge-proxy/templates/log-shipper.yaml "the shipper's token must come from the generated $logs_secret"
# Vector reads the token file through its secret backend; a ${VAR} would be
# sent as written, since Vector 0.57 no longer interpolates by default.
[ "$(yq e '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "log-token") | .mountPath' <<<"$ds")" = "$(yq e '.secret.logs.path' <<<"$vector")" ] \
  && [ "$(yq e '.sinks.admin.auth.token' <<<"$vector")" = "SECRET[logs.token]" ] \
  || fail charts/edge-proxy/templates/log-shipper.yaml "the shipper must read its token from the mounted Secret"
case $vector in *"\${"*) fail charts/edge-proxy/templates/log-shipper.yaml "the shipper's config must not use environment variables" ;; esac
[ "$(yq e '.volumes[] | select(.name == "log-token") | .secret.secretName' <<<"$admin")" = "$logs_secret" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "admin must read the shipper's token from $logs_secret"
token_mount=$(yq e '.containers[0].volumeMounts[] | select(.name == "log-token") | .mountPath' <<<"$admin")
[ "$(yq e '.containers[0].env[] | select(.name == "LOG_INGEST_TOKEN_FILE") | .value' <<<"$admin")" = "$token_mount/token" ] \
  || fail charts/edge-proxy/templates/admin-deployment.yaml "LOG_INGEST_TOKEN_FILE must point into $token_mount"
[ "$(yq e -N -o=json -I=0 'select(.kind == "ClusterRole") | .rules' "$rendered")" = '[{"apiGroups":[""],"resources":["pods","nodes"],"verbs":["list","watch"]}]' ] \
  || fail charts/edge-proxy/templates/log-shipper.yaml "the shipper's ClusterRole must only list and watch pods and nodes"
[ "$(yq e '.spec.template.spec.volumes[] | select(.name == "pod-logs") | .hostPath.path' <<<"$ds")/$(yq e '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "pod-logs") | .readOnly' <<<"$ds")" = "/var/log/pods/true" ] \
  || fail charts/edge-proxy/templates/log-shipper.yaml "the shipper must mount only /var/log/pods, read-only"
# It follows the edge's nodeSelector unless given its own.
helm template "$chart" -f "$values" --set edge.nodeSelector.pool=edge > "$rendered"
[ "$(yq e -N 'select(.kind == "DaemonSet") | .spec.template.spec.nodeSelector.pool' "$rendered")" = "edge" ] \
  || fail charts/edge-proxy/templates/log-shipper.yaml "the shipper must run where edges run"
helm template "$chart" -f "$chart/ci/integrations-values.yaml" > "$rendered"
[ "$(yq e -N 'select(.kind == "NetworkPolicy" and .metadata.labels."app.kubernetes.io/component" == "admin") | .spec.ingress[0].from[1].podSelector.matchLabels."app.kubernetes.io/component"' "$rendered")" = "log-shipper" ] \
  || fail charts/edge-proxy/templates/networkpolicy.yaml "admin must admit the log shipper"
expect_fail "logShipper.existingSecret is required when bootstrap.generateSecrets=false" \
  --set bootstrap.generateSecrets=false --set edge.existingSecret=edge
helm template "$chart" -f "$values" --set logShipper.enabled=false > "$rendered"
[ -z "$(yq e -N 'select(.kind == "DaemonSet" or .kind == "ClusterRole")' "$rendered")" ] \
  && ! grep -q LOG_INGEST_TOKEN_FILE "$rendered" \
  && [ -z "$(yq e -N 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "LOGS_SECRET") | .value' "$rendered")" ] \
  || fail charts/edge-proxy/templates/log-shipper.yaml "logShipper.enabled=false must render no shipper and create no token"

# 18. The shipper's transform passes Vector's own unit tests: access lines are
#     posted as their JSON object, and every other line is dropped. The pinned
#     binary must be the version the chart deploys.
vector_version=0.59.0
vector_sha256=a8dbc43c18ae25d0b23a712c9262f3aad904e352b1db5e7db1d9c4aecab59496 # x86_64-unknown-linux-musl
[ "$(yq e '.logShipper.image.tag' "$chart/values.yaml" | cut -d- -f1)" = "$vector_version" ] \
  || fail scripts/check-edge-proxy-render.sh "update vector_version and vector_sha256 to logShipper.image.tag's version"
vdir=$(mktemp -d)
trap 'rm -f "$rendered"; rm -rf "$vdir"' EXIT
# The tests cover the transform; Vector would read the token file at startup.
yq e 'del(.secret) | .sinks.admin.auth.token = "test"' <<<"$vector" > "$vdir/vector.yaml"
cp "$chart/ci/vector-tests.yaml" "$vdir/tests.yaml"
if command -v vector >/dev/null; then
  vector test "$vdir/vector.yaml" "$vdir/tests.yaml"
elif [ "$(uname -sm)" = "Linux x86_64" ]; then
  curl -fsSL -o "$vdir/vector.tar.gz" "https://github.com/vectordotdev/vector/releases/download/v$vector_version/vector-$vector_version-x86_64-unknown-linux-musl.tar.gz"
  echo "$vector_sha256  $vdir/vector.tar.gz" | sha256sum -c - >/dev/null
  tar -xzf "$vdir/vector.tar.gz" -C "$vdir" --strip-components=3 ./vector-x86_64-unknown-linux-musl/bin/vector
  "$vdir/vector" test "$vdir/vector.yaml" "$vdir/tests.yaml"
else
  docker run --rm -v "$vdir:/cfg:ro" "timberio/vector:$(yq e '.logShipper.image.tag' "$chart/values.yaml")" test /cfg/vector.yaml /cfg/tests.yaml
fi >"$vdir/out" 2>&1 || fail charts/edge-proxy/ci/vector-tests.yaml "Vector unit tests failed: $(cat "$vdir/out")"

echo "edge-proxy render matrix: 18/18 cases passed"

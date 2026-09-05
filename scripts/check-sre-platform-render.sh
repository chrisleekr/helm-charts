#!/usr/bin/env bash
# Permanent render gate for the multi-role SRE Platform chart.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
chart="$repo_root/charts/sre-platform"
ci="$chart/ci"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
want() {
  if grep -qE -- "$2" "$1"; then pass "$3"; else bad "$3"; fi
}
want_not() {
  if grep -qE -- "$2" "$1"; then bad "$3"; else pass "$3"; fi
}
want_count() {
  local got
  got=$(grep -cE "$2" "$1" || true)
  if [ "$got" = "$3" ]; then pass "$4"; else bad "$4 (expected $3, found $got)"; fi
}

doc() {
  local source=$1 kind=$2 name=$3 out=$4
  awk -v kind="kind: $kind" -v name="  name: $name" -v out="$out" '
    function flush() {
      if (body ~ ("(^|\\n)" kind "(\\n|$)") && body ~ ("(^|\\n)" name "(\\n|$)")) {
        printf "%s", body > out
        found=1
      }
      body=""
    }
    /^---[[:space:]]*$/ { flush(); next }
    { body=body $0 "\n" }
    END { flush(); exit(found ? 0 : 1) }
  ' "$source"
}

render() {
  local name=$1
  shift
  helm template sre "$chart" "$@" >"$tmp/$name.yaml"
}

render base -f "$ci/ct-values.yaml"
render configured -f "$ci/ct-values.yaml" --set config.registrationMode=open --set config.trustedProxyHops=10
render public-site -f "$ci/ct-values.yaml" \
  --set-string public.supportUrl=https://support.example.com/sre-platform \
  --set-string public.termsUrl=https://www.example.com/legal/terms \
  --set-string public.termsVersion=2026-09-05
render closed -f "$ci/ct-values.yaml" --set config.registrationMode=closed
render smtp -f "$ci/ct-values.yaml" \
  --set smtp.enabled=true \
  --set-string smtp.host=smtp.example.com \
  --set smtp.port=465 \
  --set smtp.secure=true \
  --set-string smtp.from=alerts@example.com \
  --set-string smtp.username=mailer
render ingress -f "$ci/ingress-values.yaml"
render no-migrate -f "$ci/ct-values.yaml" --set migrations.enabled=false
render lean -f "$ci/ct-values.yaml" --set serviceAccount.create=false --set serviceAccount.name=sre-runtime
render edge-tls -f "$ci/ingress-values.yaml" --set ingress.allowInsecure=true --set ingress.api.tls=null --set ingress.dashboard.tls=null
# One valid provider, reused with different administrator cases below.
bootstrap_provider=(
  --set-string 'bootstrap.staffProvider.displayName=Staff sign-in'
  --set-string 'bootstrap.staffProvider.issuer=https://idp.example.com/'
  --set-string 'bootstrap.staffProvider.browserClientId=browser-client'
  --set-string 'bootstrap.staffProvider.audience=https://api.sre.example.com/'
  --set-string 'bootstrap.staffProvider.jwksUri=https://idp.example.com/jwks?version=1'
)
bootstrap_on=(
  --set bootstrap.enabled=true
  "${bootstrap_provider[@]}"
  --set-string 'bootstrap.platformAdmins[0].subject=directory|000000000000000000000001'
  --set-string 'bootstrap.platformAdmins[0].email=operator@example.com'
)
# The first entry pins subject-plus-email; the second pins an email-only invitation.
render bootstrap -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string 'bootstrap.platformAdmins[1].email=invited@example.com'
render bootstrap-changed -f "$ci/ct-values.yaml" "${bootstrap_provider[@]}" \
  --set bootstrap.enabled=true \
  --set-string 'bootstrap.platformAdmins[0].subject=directory|000000000000000000000009'
render bootstrap-discovery -f "$ci/ct-values.yaml" \
  --set bootstrap.enabled=true \
  --set-string 'bootstrap.staffProvider.displayName=Staff sign-in' \
  --set-string 'bootstrap.staffProvider.issuer=https://idp.example.com/' \
  --set-string 'bootstrap.staffProvider.browserClientId=browser-client' \
  --set-string 'bootstrap.staffProvider.audience=https://api.sre.example.com/' \
  --set-string 'bootstrap.platformAdmins[0].subject=directory|000000000000000000000001'
# Bootstrap is enabled here so the -bootstrap component name is length-checked too.
helm template a-release-name-long-enough-to-exercise-component-name \
  "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" >"$tmp/long.yaml"

helm lint "$chart" -f "$ci/ct-values.yaml" >"$tmp/lint.out"
pass "helm lint"

want_count "$tmp/base.yaml" '^kind: Deployment$' 4 "four long-lived Deployments"
want_count "$tmp/base.yaml" '^kind: Service$' 2 "two public Services"
want_count "$tmp/base.yaml" '^kind: Job$' 1 "one migration Job"
want_count "$tmp/base.yaml" '^kind: NetworkPolicy$' 1 "one default egress policy"
want_count "$tmp/base.yaml" '^[[:space:]]+value: (api|dashboard|triage-worker|surface-worker)$' 4 "every workload has its fixed role"
want "$tmp/base.yaml" 'value: "3000"' "API binds port 3000"
want "$tmp/base.yaml" 'value: "8080"' "dashboard binds port 8080"
want "$tmp/base.yaml" 'image: "chrisleekr/sre-platform:0\.0\.0"' "unpublished appVersion image remains human-readable"
want "$tmp/base.yaml" 'path: /readyz' "API readiness is rendered"
want "$tmp/base.yaml" 'DASHBOARD_WS_BASE_URL: "wss://api\.sre\.example\.com"' "WebSocket origin derives from HTTPS API"
want "$tmp/base.yaml" 'AUTH0_JWKS_URI: "https://tenant\.example\.auth0\.com/\.well-known/jwks\.json"' "optional JWKS override renders"
want "$tmp/base.yaml" 'helm\.sh/hook: pre-install,pre-upgrade' "migration blocks install and upgrade"
want_count "$tmp/base.yaml" '^      automountServiceAccountToken: false$' 5 "all five workloads disable Kubernetes credential automounting"
want_not "$tmp/base.yaml" '^      automountServiceAccountToken: true$' "no workload enables Kubernetes credential automounting"
want "$tmp/base.yaml" '- 169\.254\.0\.0/16' "metadata address space is excluded"
want "$tmp/base.yaml" '- fc00::/7' "IPv6 private address space is excluded"
# The API server rejects an IPv4-mapped IPv6 address in ipBlock (KEP-4858), so
# naming that range here would make the policy unadmittable and leave the
# workloads with no egress restriction at all.
want_not "$tmp/base.yaml" '- ::ffff:0:0/96' "IPv4-mapped range stays out of ipBlock"
want_not "$tmp/base.yaml" '^kind: Secret$' "chart never renders a Secret"
want_not "$tmp/no-migrate.yaml" '^kind: Job$' "operator-owned migration mode omits the Job"
want_count "$tmp/bootstrap.yaml" '^kind: Job$' 2 "first-run bootstrap adds a second Job"
want_count "$tmp/bootstrap.yaml" '^      automountServiceAccountToken: false$' 6 "the bootstrap Job also disables credential automounting"
want_not "$tmp/lean.yaml" '^kind: ServiceAccount$' "pre-existing ServiceAccount mode omits creation"
want "$tmp/lean.yaml" 'serviceAccountName: sre-runtime' "pre-existing ServiceAccount is selected"
want_count "$tmp/edge-tls.yaml" '^kind: Ingress$' 2 "external TLS termination branch renders"

doc "$tmp/base.yaml" NetworkPolicy sre-sre-platform-egress "$tmp/policy.yaml"
doc "$tmp/base.yaml" ConfigMap sre-sre-platform "$tmp/base-config.yaml"
doc "$tmp/bootstrap.yaml" ConfigMap sre-sre-platform "$tmp/bootstrap-config.yaml"
doc "$tmp/bootstrap-changed.yaml" ConfigMap sre-sre-platform "$tmp/bootstrap-changed-config.yaml"
doc "$tmp/base.yaml" Deployment sre-sre-platform-api "$tmp/api.yaml"
doc "$tmp/configured.yaml" Deployment sre-sre-platform-api "$tmp/configured-api.yaml"
doc "$tmp/public-site.yaml" Deployment sre-sre-platform-api "$tmp/public-site-api.yaml"
doc "$tmp/closed.yaml" Deployment sre-sre-platform-api "$tmp/closed-api.yaml"
doc "$tmp/smtp.yaml" ConfigMap sre-sre-platform "$tmp/smtp-config.yaml"
doc "$tmp/base.yaml" Deployment sre-sre-platform-dashboard "$tmp/dashboard.yaml"
doc "$tmp/base.yaml" Deployment sre-sre-platform-triage-worker "$tmp/triage.yaml"
doc "$tmp/base.yaml" Deployment sre-sre-platform-surface-worker "$tmp/surface.yaml"
doc "$tmp/base.yaml" Job sre-sre-platform-migrate "$tmp/migrate.yaml"
doc "$tmp/bootstrap-discovery.yaml" Job sre-sre-platform-bootstrap "$tmp/bootstrap-discovery-job.yaml"
want_not "$tmp/dashboard.yaml" 'secretKeyRef:' "dashboard receives no runtime Secret"
want "$tmp/api.yaml" '^[[:space:]]+value: "approval_required"$' "workspace founding is approval-required by default"
want "$tmp/api.yaml" '^[[:space:]]+value: "0"$' "forwarded source addresses are ignored by default"
want "$tmp/configured-api.yaml" '^[[:space:]]+- name: REGISTRATION_MODE$' "non-default registration mode is an explicit API variable"
want "$tmp/configured-api.yaml" '^[[:space:]]+value: "open"$' "open registration mode renders exactly"
want "$tmp/configured-api.yaml" '^[[:space:]]+- name: TRUST_PROXY_HOPS$' "non-default trusted proxy count is an explicit API variable"
want "$tmp/configured-api.yaml" '^[[:space:]]+value: "10"$' "upper trusted proxy boundary renders exactly"
want_not "$tmp/api.yaml" 'name: (SUPPORT_URL|TERMS_URL|TERMS_VERSION)' "optional public-site metadata stays absent by default"
want "$tmp/public-site-api.yaml" '^[[:space:]]+- name: SUPPORT_URL$' "support URL is an explicit API variable"
want "$tmp/public-site-api.yaml" '^[[:space:]]+value: "https://support\.example\.com/sre-platform"$' "support URL renders exactly"
want "$tmp/public-site-api.yaml" '^[[:space:]]+- name: TERMS_URL$' "terms URL is an explicit API variable"
want "$tmp/public-site-api.yaml" '^[[:space:]]+value: "https://www\.example\.com/legal/terms"$' "terms URL renders exactly"
want "$tmp/public-site-api.yaml" '^[[:space:]]+- name: TERMS_VERSION$' "terms version is an explicit API variable"
want "$tmp/public-site-api.yaml" '^[[:space:]]+value: "2026-09-05"$' "terms version renders exactly"
want "$tmp/closed-api.yaml" '^[[:space:]]+value: "closed"$' "closed registration mode renders exactly"
want_not "$tmp/base-config.yaml" '^  SMTP_' "SMTP fallback stays absent by default"
for pair in \
  'SMTP_HOST: "smtp.example.com"' \
  'SMTP_PORT: "465"' \
  'SMTP_SECURE: "true"' \
  'SMTP_FROM: "alerts@example.com"' \
  'SMTP_USERNAME: "mailer"'; do
  want "$tmp/smtp-config.yaml" "^  $pair$" "configured $pair renders exactly"
done
for key in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY; do
  want "$tmp/api.yaml" "name: $key" "API receives optional $key"
  want "$tmp/triage.yaml" "name: $key" "triage receives optional $key"
  want_not "$tmp/dashboard.yaml" "name: $key" "dashboard receives no $key"
  want_not "$tmp/surface.yaml" "name: $key" "surface worker receives no $key"
  want_not "$tmp/migrate.yaml" "name: $key" "migration receives no $key"
done
want_count "$tmp/api.yaml" '^[[:space:]]+optional: true$' 3 "API model bootstrap credentials remain optional"
want_count "$tmp/triage.yaml" '^[[:space:]]+optional: true$' 3 "triage model bootstrap credentials remain optional"
want_not "$tmp/triage.yaml" '(startup|readiness|liveness)Probe:' "triage worker has no synthetic probe"
want_not "$tmp/surface.yaml" '(startup|readiness|liveness)Probe:' "surface worker has no synthetic probe"
want_count "$tmp/migrate.yaml" '^[[:space:]]+secretKeyRef:$' 2 "migration receives only its two required secrets"

doc "$tmp/bootstrap.yaml" Job sre-sre-platform-bootstrap "$tmp/bootstrap-job.yaml"
# The weight is inert without the hook annotation itself. Asserting only the
# weight would stay green if the Job stopped being a hook and started installing
# alongside the workloads, which is the ordering guarantee this section rests on.
want "$tmp/bootstrap-job.yaml" 'helm\.sh/hook: pre-install,pre-upgrade' "bootstrap is registered as an install and upgrade hook"
want "$tmp/bootstrap-job.yaml" 'helm\.sh/hook-weight: "1"' "bootstrap runs after the migration hook"
want "$tmp/bootstrap-job.yaml" '^[[:space:]]+- name: ROLE$' "bootstrap Job sets the role variable"
want "$tmp/bootstrap-job.yaml" '^[[:space:]]+value: bootstrap$' "bootstrap Job carries its fixed role"
want_count "$tmp/bootstrap-job.yaml" '^[[:space:]]+secretKeyRef:$' 1 "bootstrap receives exactly one secret"
want "$tmp/bootstrap-job.yaml" '^[[:space:]]+key: DATABASE_URL$' "bootstrap receives the administrative connection"
want_not "$tmp/bootstrap-job.yaml" 'APP_DATABASE_URL' "bootstrap receives no restricted runtime connection"
want_not "$tmp/bootstrap-job.yaml" 'APP_DB_PASSWORD' "bootstrap receives no role password"
want "$tmp/bootstrap-job.yaml" '^[[:space:]]+- name: BOOTSTRAP_STAFF_PROVIDER$' "staff provider uses its contract variable"
want "$tmp/bootstrap-job.yaml" '^[[:space:]]+- name: BOOTSTRAP_PLATFORM_ADMINS$' "administrator list uses its contract variable"
want_not "$tmp/bootstrap-job.yaml" 'BOOTSTRAP_TENANT_NAME|BOOTSTRAP_OPERATORS' "retired bootstrap variables are absent"
want_not "$tmp/base-config.yaml" 'sre-platform\.io/bootstrap-revision' "disabled bootstrap adds no sync trigger"
want "$tmp/bootstrap-config.yaml" 'sre-platform\.io/bootstrap-revision: "[a-f0-9]{64}"' "enabled bootstrap adds an opaque sync trigger"
bootstrap_revision=$(yq '.metadata.annotations."sre-platform.io/bootstrap-revision"' "$tmp/bootstrap-config.yaml")
changed_revision=$(yq '.metadata.annotations."sre-platform.io/bootstrap-revision"' "$tmp/bootstrap-changed-config.yaml")
if [ "$bootstrap_revision" != "$changed_revision" ]; then
  pass "bootstrap declaration changes the sync trigger"
else
  bad "bootstrap declaration must change the sync trigger"
fi
# The application rejects an unrecognised key, so the chart composes this value
# from known keys rather than passing values through. Pinning the exact string
# keeps a silent shape change from reaching a release.
want "$tmp/bootstrap-job.yaml" \
  'value: "\{\\"audience\\":\\"https://api\.sre\.example\.com/\\",\\"browserClientId\\":\\"browser-client\\",\\"displayName\\":\\"Staff sign-in\\",\\"emailClaim\\":\\"email\\",\\"issuer\\":\\"https://idp\.example\.com/\\",\\"jwksUri\\":\\"https://idp\.example\.com/jwks\?version=1\\"\}"' \
  "staff provider renders as the exact JSON contract"
want "$tmp/bootstrap-job.yaml" \
  'value: "\[\{\\"email\\":\\"operator@example\.com\\",\\"subject\\":\\"directory\|000000000000000000000001\\"\},\{\\"email\\":\\"invited@example\.com\\"\}\]"' \
  "administrators render as the exact subject-plus-email and invitation JSON forms"
want "$tmp/bootstrap-discovery-job.yaml" \
  'value: "\{\\"audience\\":\\"https://api\.sre\.example\.com/\\",\\"browserClientId\\":\\"browser-client\\",\\"displayName\\":\\"Staff sign-in\\",\\"emailClaim\\":\\"email\\",\\"issuer\\":\\"https://idp\.example\.com/\\"\}"' \
  "discovery-mode provider omits an empty JWKS URI"
want_not "$tmp/bootstrap-discovery-job.yaml" 'jwksUri' "discovery-mode provider contains no empty JWKS key"
want_count "$tmp/policy.yaml" '^[[:space:]]+- (api|triage-worker)$' 2 "egress policy selects API and triage only"
want_not "$tmp/policy.yaml" '^[[:space:]]+- (dashboard|surface-worker)$' "egress policy excludes other components"
want "$tmp/policy.yaml" 'protocol: UDP' "egress policy retains UDP DNS"
want "$tmp/policy.yaml" 'protocol: TCP' "egress policy retains TCP DNS"
want "$tmp/policy.yaml" 'port: 53' "egress policy retains DNS port"
want "$tmp/policy.yaml" 'kubernetes\.io/metadata\.name: ai' "private egress namespace selector renders"
want "$tmp/policy.yaml" 'app\.kubernetes\.io/name: embeddings-ci' "private egress pod selector renders"
want "$tmp/policy.yaml" 'port: 8080' "private egress port renders"

want_count "$tmp/ingress.yaml" '^kind: Ingress$' 2 "TLS branch renders both ingresses"
want_count "$tmp/ingress.yaml" '^  tls:$' 2 "both ingresses carry TLS"
want "$tmp/ingress.yaml" 'host: "api\.sre\.example\.com"' "API ingress host"
want "$tmp/ingress.yaml" 'host: "sre\.example\.com"' "dashboard ingress host"

if helm template sre "$chart" -f "$ci/ct-values.yaml" --set existingSecret= >/dev/null 2>"$tmp/missing-secret.err"; then
  bad "missing existingSecret must fail"
else
  want "$tmp/missing-secret.err" 'existingSecret is required' "missing existingSecret fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set auth0.clientId= >/dev/null 2>"$tmp/auth.err"; then
  bad "missing Auth0 client ID must fail"
else
  want "$tmp/auth.err" 'auth0.clientId is required' "missing Auth0 client ID fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set llm.provider=fake >/dev/null 2>"$tmp/provider.err"; then
  bad "unsupported LLM provider must fail"
else
  want "$tmp/provider.err" 'must be empty, claude, or openai' "unsupported LLM provider fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set llm.provider=openai >/dev/null 2>"$tmp/openai-model.err"; then
  bad "OpenAI without a model must fail"
else
  want "$tmp/openai-model.err" 'openaiModel is required' "OpenAI requires a model"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set config.registrationMode=invalid >/dev/null 2>"$tmp/registration-mode.err"; then
  bad "unsupported registration mode must fail"
else
  want "$tmp/registration-mode.err" 'registrationMode must be open, approval_required, or closed' "unsupported registration mode fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string public.termsUrl=https://www.example.com/legal/terms >/dev/null 2>"$tmp/terms-pair.err"; then
  bad "terms URL without a version must fail"
else
  want "$tmp/terms-pair.err" 'termsUrl and public.termsVersion must be configured together' "terms metadata requires an exact version"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string public.supportUrl=mailto:sre@example.com >/dev/null 2>"$tmp/support-url.err"; then
  bad "non-HTTP support URL must fail"
else
  want "$tmp/support-url.err" 'must be an absolute http:// or https:// URL' "support URL requires HTTP or HTTPS"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string public.supportUrl=https:// >/dev/null 2>"$tmp/support-host.err"; then
  bad "support URL without a host must fail"
else
  want "$tmp/support-host.err" 'must be an absolute http:// or https:// URL' "support URL requires a host"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string public.termsUrl=https://user:secret@example.com/terms --set-string public.termsVersion=1 >/dev/null 2>"$tmp/terms-credentials.err"; then
  bad "terms URL with credentials must fail"
else
  want "$tmp/terms-credentials.err" 'without credentials' "terms URL rejects embedded credentials"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set public.supportUrl=123 >/dev/null 2>"$tmp/support-type.err"; then
  bad "non-string support URL must fail"
else
  want "$tmp/support-type.err" 'supportUrl must be a quoted string' "support URL rejects non-string YAML scalars"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set config.trustedProxyHops=11 >/dev/null 2>"$tmp/proxy-hops.err"; then
  bad "out-of-range trusted proxy hops must fail"
else
  want "$tmp/proxy-hops.err" 'trustedProxyHops must be an integer from 0 to 10' "out-of-range trusted proxy hops fail clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string config.trustedProxyHops=999999999999999999999999 >/dev/null 2>"$tmp/proxy-hops-overflow.err"; then
  bad "overflowing trusted proxy hops must fail"
else
  want "$tmp/proxy-hops-overflow.err" 'trustedProxyHops must be an integer from 0 to 10' "overflowing trusted proxy hops fail clearly"
fi
for malformed_hops in -1 1.5; do
  if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string config.trustedProxyHops="$malformed_hops" >/dev/null 2>"$tmp/proxy-hops-malformed.err"; then
    bad "malformed trusted proxy hops $malformed_hops must fail"
  else
    want "$tmp/proxy-hops-malformed.err" 'trustedProxyHops must be an integer from 0 to 10' "malformed trusted proxy hops $malformed_hops fail clearly"
  fi
done
for reserved_env in REGISTRATION_MODE TRUST_PROXY_HOPS SUPPORT_URL TERMS_URL TERMS_VERSION SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_FROM SMTP_USERNAME; do
  if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string "extraEnv[0].name=$reserved_env" --set-string 'extraEnv[0].value=override' >/dev/null 2>"$tmp/reserved-extra-env.err"; then
    bad "extraEnv must not replace $reserved_env"
  else
    want "$tmp/reserved-extra-env.err" 'extraEnv cannot replace public-site, SMTP, or security settings' "$reserved_env cannot be replaced through extraEnv"
  fi
done
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set smtp.enabled=true >/dev/null 2>"$tmp/smtp-host.err"; then
  bad "enabled SMTP without a host must fail"
else
  want "$tmp/smtp-host.err" 'smtp.host is required' "enabled SMTP requires a host"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set smtp.enabled=true --set-string smtp.host=smtp.example.com \
  --set smtp.port=70000 --set-string smtp.from=alerts@example.com >/dev/null 2>"$tmp/smtp-port.err"; then
  bad "out-of-range SMTP port must fail"
else
  want "$tmp/smtp-port.err" 'smtp.port must be an integer from 1 to 65535' "SMTP port is bounded"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set smtp.enabled=true --set-string smtp.host=smtp.example.com \
  --set smtp.port=587 --set-string smtp.from=not-an-email >/dev/null 2>"$tmp/smtp-from.err"; then
  bad "invalid SMTP sender must fail"
else
  want "$tmp/smtp-from.err" 'smtp.from must be an email address' "SMTP sender is validated"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set image.tag=1.2.3 >/dev/null 2>"$tmp/digest-required.err"; then
  bad "publishable image without digest must fail"
else
  want "$tmp/digest-required.err" 'image.tag and image.digest must be set together' "image override requires digest"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set image.tag=1.2.3 \
  --set-string image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$tmp/digest.yaml"; then
  want_count "$tmp/digest.yaml" 'image: "chrisleekr/sre-platform:1\.2\.3@sha256:a{64}"' 5 "every override image is digest pinned"
  want_not "$tmp/digest.yaml" 'image: "chrisleekr/sre-platform:1\.2\.3"$' "override render contains no unpinned image"
else
  bad "valid image digest must render"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string image.digest=sha256:not-a-digest >/dev/null 2>"$tmp/digest-invalid.err"; then
  bad "invalid image digest must fail"
else
  want "$tmp/digest-invalid.err" 'image.tag and image.digest must be set together' "digest without override tag fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set image.tag=1.2.3 \
  --set-string image.digest=sha256:not-a-digest >/dev/null 2>"$tmp/digest-format.err"; then
  bad "invalid image digest format must fail"
else
  want "$tmp/digest-format.err" 'image.digest must be a sha256 OCI manifest digest' "invalid image digest format fails clearly"
fi
# Bootstrap is enabled here so the sixth workload is covered by the pinning
# assertion. It runs the same image on the administrative connection, so an
# unpinned image would matter most there.
helm template sre "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string image.releaseDigest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >"$tmp/release-digest.yaml"
want_count "$tmp/release-digest.yaml" 'image: "chrisleekr/sre-platform:0\.0\.0@sha256:b{64}"' 6 "every chart release image is digest pinned, bootstrap included"
want_not "$tmp/release-digest.yaml" 'image: "chrisleekr/sre-platform:0\.0\.0"$' "release render contains no unpinned image"
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set-string image.releaseDigest=sha256:not-a-digest >/dev/null 2>"$tmp/release-digest-invalid.err"; then
  bad "invalid release digest must fail"
else
  want "$tmp/release-digest-invalid.err" 'image.releaseDigest must be a sha256 OCI manifest digest' "invalid release digest fails clearly"
fi
# A tag that already carries its digest is the single-key form a delivery
# controller writes. It must render byte-for-byte, not gain a second digest.
helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set-string image.tag=latest@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc >"$tmp/embedded-digest.yaml"
want_count "$tmp/embedded-digest.yaml" 'image: "chrisleekr/sre-platform:latest@sha256:c{64}"' 5 "embedded-digest tag renders unchanged"
want_not "$tmp/embedded-digest.yaml" '@sha256:[a-f0-9]{64}@' "embedded-digest tag is not double-pinned"
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set-string image.tag=latest@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  --set-string image.digest=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd >/dev/null 2>"$tmp/embedded-both.err"; then
  bad "embedded-digest tag plus image.digest must fail"
else
  want "$tmp/embedded-both.err" 'image.tag already carries a digest' "embedded-digest tag rejects a second digest"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set-string image.tag=latest@sha256:short >/dev/null 2>"$tmp/embedded-malformed.err"; then
  bad "malformed embedded digest must fail"
else
  want "$tmp/embedded-malformed.err" 'must be <tag>@sha256:<64 hex>' "malformed embedded digest fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set llm.provider=openai \
  --set-string llm.openaiModel='   ' >/dev/null 2>"$tmp/openai-model-space.err"; then
  bad "OpenAI with a whitespace model must fail"
else
  want "$tmp/openai-model-space.err" 'openaiModel is required' "OpenAI rejects a whitespace model"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set public.apiUrl=https://api.sre.example.com/path >/dev/null 2>"$tmp/path.err"; then
  bad "public API URL with path must fail"
else
  want "$tmp/path.err" 'without a path' "public API URL path fails clearly"
fi
for unsafe in 'https://api.sre.example.com?tenant=x' 'https://api.sre.example.com#fragment' 'https://user:pass@api.sre.example.com'; do
  # Asserted inside the loop like every other failure check here. A single `want`
  # after the loop reads only the last iteration's stderr, so the query and
  # fragment cases went unasserted and a stale file could satisfy it.
  if helm template sre "$chart" -f "$ci/ct-values.yaml" --set-string public.apiUrl="$unsafe" >/dev/null 2>"$tmp/origin.err"; then
    bad "non-origin public API URL must fail: $unsafe"
  else
    want "$tmp/origin.err" 'without a path, query, fragment, or credentials' "non-origin URL rejected clearly: $unsafe"
  fi
done
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set public.dashboardUrl=https://api.sre.example.com >/dev/null 2>"$tmp/same-origin.err"; then
  bad "identical dashboard and API origins must fail"
else
  want "$tmp/same-origin.err" 'must be different origins' "identical public origins fail clearly"
fi
if helm template sre "$chart" -f "$ci/ingress-values.yaml" --set ingress.api.tls=null >/dev/null 2>"$tmp/tls.err"; then
  bad "cleartext ingress must fail"
else
  want "$tmp/tls.err" 'enabled ingresses require TLS' "cleartext ingress fails clearly"
fi
if helm template sre "$chart" -f "$ci/ingress-values.yaml" --set public.apiUrl=https://different.example.com >/dev/null 2>"$tmp/host.err"; then
  bad "ingress/public API host mismatch must fail"
else
  want "$tmp/host.err" 'ingress.api.host must match' "ingress/public API host mismatch fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set embeddings.dim=1024.5 >/dev/null 2>"$tmp/dim.err"; then
  bad "wrong embedding dimension must fail"
else
  want "$tmp/dim.err" 'embeddings.dim must be exactly 1024' "wrong embedding dimension fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set networkPolicy.enabled=false >/dev/null 2>"$tmp/policy.err"; then
  bad "disabled egress policy without acknowledgement must fail"
else
  want "$tmp/policy.err" 'acknowledgeExternalPolicy=true' "external egress policy requires acknowledgement"
fi
helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set networkPolicy.enabled=false \
  --set networkPolicy.acknowledgeExternalPolicy=true >"$tmp/external-policy.yaml"
want_not "$tmp/external-policy.yaml" '^kind: NetworkPolicy$' "acknowledged external policy omits chart policy"

# Reaching the cluster's own API server is denied by the egress policy above, and
# no ipBlock can reopen it under Cilium: kube-proxy rewrites the ClusterIP to the
# node address before egress is evaluated, and Cilium resolves a node address to
# a reserved identity, which CIDR selectors do not match. Entities are the only
# selector that names what Cilium sees, so these assertions pin the selector kind
# as much as the rule.
want_not "$tmp/base.yaml" '^kind: CiliumNetworkPolicy$' "API server egress stays off by default"
helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set networkPolicy.apiServerEgress.enabled=true >"$tmp/apiserver-egress.yaml"
want_count "$tmp/apiserver-egress.yaml" '^kind: CiliumNetworkPolicy$' 1 "enabled API server egress renders one Cilium policy"
doc "$tmp/apiserver-egress.yaml" CiliumNetworkPolicy sre-sre-platform-apiserver-egress "$tmp/apiserver-policy.yaml"
want_count "$tmp/apiserver-policy.yaml" '^[[:space:]]+- (api|triage-worker)$' 2 "API server egress selects API and triage only"
want_not "$tmp/apiserver-policy.yaml" '^[[:space:]]+- (dashboard|surface-worker)$' "API server egress excludes other components"
want "$tmp/apiserver-policy.yaml" '^[[:space:]]+- kube-apiserver$' "API server egress names the kube-apiserver entity"
want "$tmp/apiserver-policy.yaml" '^[[:space:]]+- host$' "API server egress covers a control plane on the Pod's own node"
want "$tmp/apiserver-policy.yaml" '^[[:space:]]+- remote-node$' "API server egress covers a control plane on another node"
want "$tmp/apiserver-policy.yaml" 'port: "6443"' "API server egress pins the endpoint port"
want_not "$tmp/apiserver-policy.yaml" 'ipBlock' "API server egress uses entities, never a CIDR selector"
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set networkPolicy.apiServerEgress.enabled=true \
  --set networkPolicy.enabled=false \
  --set networkPolicy.acknowledgeExternalPolicy=true >/dev/null 2>"$tmp/apiserver-orphan.err"; then
  bad "API server egress without the chart egress policy must fail"
else
  want "$tmp/apiserver-orphan.err" 'requires networkPolicy.enabled' "orphaned API server egress fails clearly"
fi

# Bootstrap is a pre-upgrade hook, so invalid access configuration must fail at render time.
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set bootstrap.enabled=true >/dev/null 2>"$tmp/bootstrap-provider.err"; then
  bad "enabled bootstrap without a staff provider must fail"
else
  want "$tmp/bootstrap-provider.err" 'bootstrap.staffProvider.displayName is required' "enabled bootstrap requires staff-provider metadata"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" --set bootstrap.enabled=true \
  "${bootstrap_provider[@]}" >/dev/null 2>"$tmp/bootstrap-admins.err"; then
  bad "enabled bootstrap without administrators must fail"
else
  want "$tmp/bootstrap-admins.err" 'at least one entry in bootstrap.platformAdmins' "enabled bootstrap requires an administrator"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string 'bootstrap.platformAdmins[0].subject=' \
  --set-string 'bootstrap.platformAdmins[0].email=' >/dev/null 2>"$tmp/bootstrap-identity.err"; then
  bad "administrator without a subject or email must fail"
else
  want "$tmp/bootstrap-identity.err" 'requires a non-empty subject or email' "empty administrator identity fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string 'bootstrap.platformAdmins[0].role=admin' >/dev/null 2>"$tmp/bootstrap-key.err"; then
  bad "unrecognised administrator key must fail"
else
  want "$tmp/bootstrap-key.err" 'unexpected key role' "unrecognised administrator key fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string 'bootstrap.staffProvider.clientSecret=forbidden' >/dev/null 2>"$tmp/bootstrap-provider-key.err"; then
  bad "unrecognised provider key must fail"
else
  want "$tmp/bootstrap-provider-key.err" 'unexpected key clientSecret' "unrecognised provider key fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string 'bootstrap.staffProvider.audience=   ' >/dev/null 2>"$tmp/bootstrap-blank.err"; then
  bad "whitespace provider field must fail"
else
  want "$tmp/bootstrap-blank.err" 'bootstrap.staffProvider.audience is required' "whitespace provider field fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string 'bootstrap.platformAdmins[1].subject=directory|000000000000000000000001' >/dev/null 2>"$tmp/bootstrap-dup.err"; then
  bad "a repeated subject must fail"
else
  want "$tmp/bootstrap-dup.err" 'repeats the subject of entry 0' "a repeated subject fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string 'bootstrap.platformAdmins[1].email=invited@example.com' \
  --set-string 'bootstrap.platformAdmins[2].email=INVITED@example.com' >/dev/null 2>"$tmp/bootstrap-email-dup.err"; then
  bad "a repeated email-only invitation must fail"
else
  want "$tmp/bootstrap-email-dup.err" 'repeats the email-only invitation of entry 1' "email-only duplicates fail case-insensitively"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" "${bootstrap_on[@]}" \
  --set-string 'bootstrap.platformAdmins[0].email=operator@example.com' \
  --set-string 'bootstrap.platformAdmins[1].email=OPERATOR@example.com' >/dev/null 2>"$tmp/bootstrap-email-cross.err"; then
  bad "a subject and invitation email collision must fail"
else
  want "$tmp/bootstrap-email-cross.err" 'conflicts with subject entry 0' "subject and invitation email collision fails clearly"
fi
if helm template sre "$chart" -f "$ci/ct-values.yaml" \
  --set bootstrap.enabled=true "${bootstrap_provider[@]}" \
  --set-string 'bootstrap.platformAdmins[0].email=operator@example.com' \
  --set-string 'bootstrap.platformAdmins[1].subject=directory|000000000000000000000001' \
  --set-string 'bootstrap.platformAdmins[1].email=OPERATOR@example.com' >/dev/null 2>"$tmp/bootstrap-email-reverse.err"; then
  bad "a subject email matching an earlier invitation must fail"
else
  want "$tmp/bootstrap-email-reverse.err" 'conflicts with email-only entry 0' "reverse-order administrator email collision fails clearly"
fi
# These shapes only reproduce through a values file because --set-string forces strings.
cat >"$tmp/numeric-subject.yaml" <<'YAML'
bootstrap:
  enabled: true
  staffProvider:
    displayName: Staff sign-in
    issuer: https://idp.example.com/
    browserClientId: browser-client
    audience: https://api.sre.example.com/
  platformAdmins:
    - email: operator@example.com
      subject: 110169484474386276334
YAML
if helm template sre "$chart" -f "$ci/ct-values.yaml" -f "$tmp/numeric-subject.yaml" >/dev/null 2>"$tmp/bootstrap-numeric.err"; then
  bad "an unquoted numeric subject must fail rather than render in scientific notation"
else
  want "$tmp/bootstrap-numeric.err" 'subject must be a quoted string' "an unquoted numeric subject fails clearly"
fi
cat >"$tmp/scalar-provider.yaml" <<'YAML'
bootstrap:
  enabled: true
  staffProvider: invalid
  platformAdmins:
    - email: operator@example.com
YAML
if helm template sre "$chart" -f "$ci/ct-values.yaml" -f "$tmp/scalar-provider.yaml" >/dev/null 2>"$tmp/bootstrap-provider-shape.err"; then
  bad "a scalar staff provider must fail"
else
  want "$tmp/bootstrap-provider-shape.err" 'must be a YAML mapping' "a scalar staff provider fails clearly"
fi
cat >"$tmp/scalar-admins.yaml" <<'YAML'
bootstrap:
  enabled: true
  staffProvider:
    displayName: Staff sign-in
    issuer: https://idp.example.com/
    browserClientId: browser-client
    audience: https://api.sre.example.com/
  platformAdmins: operator@example.com
YAML
if helm template sre "$chart" -f "$ci/ct-values.yaml" -f "$tmp/scalar-admins.yaml" >/dev/null 2>"$tmp/bootstrap-scalar.err"; then
  bad "a scalar administrator list must fail"
else
  want "$tmp/bootstrap-scalar.err" 'must be a YAML list of mappings' "a scalar administrator list fails clearly"
fi

# Names must remain unique and fit DNS labels even with a long release name.
names=$(awk '/^  name: / {print $2}' "$tmp/long.yaml")
while read -r name; do
  [ -z "$name" ] && continue
  [ "${#name}" -le 63 ] || bad "resource name exceeds 63 characters: $name"
done <<<"$names"
want "$tmp/long.yaml" '^  name: .*-triage-worker$' "long role names retain their suffix"

# The chart is public. Personal infrastructure must not enter its source or render.
forbidden='gitlab\.chrislee\.kr|registry\.chrislee\.kr|(^|[^A-Za-z])chrislee\.kr|homelab|smee\.io'
if grep -rEi "$forbidden" "$chart" "$tmp/base.yaml" "$tmp/ingress.yaml" >/dev/null; then
  bad "private infrastructure reference found"
else
  pass "no private infrastructure references"
fi

[ "$fail" -eq 0 ]

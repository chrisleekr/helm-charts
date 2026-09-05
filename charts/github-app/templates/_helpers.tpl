{{/*
Expand the name of the chart.
*/}}
{{- define "github-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "github-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "github-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "github-app.labels" -}}
helm.sh/chart: {{ include "github-app.chart" . }}
{{ include "github-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "github-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "github-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "github-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "github-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding app credentials. Uses secrets.existingSecret when set,
otherwise the chart-managed name <fullname>-secret.
*/}}
{{- define "github-app.secretName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- printf "%s-secret" (include "github-app.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Name of the controller-only Secret (workflow-runner capability roots). Uses
secrets.existingControllerSecret when set, otherwise <fullname>-controller-secret.

Both names are RESOLVED before comparison, and the comparison is unconditional, so
either route to a collision is rejected: pointing existingControllerSecret at the
app Secret, and pointing existingSecret at the chart-managed controller Secret
name. The second route matters just as much, because the app Secret is
envFrom-mounted on every daemon pool: a collision there hands the capability
signing root to workers that run agent-authored code.
*/}}
{{- define "github-app.controllerSecretName" -}}
{{- $app := include "github-app.secretName" . -}}
{{- $controller := default (printf "%s-controller-secret" (include "github-app.fullname" .)) .Values.secrets.existingControllerSecret -}}
{{- if eq $controller $app -}}
{{- fail (printf "the controller-only Secret and the app Secret both resolve to %q. The app Secret is envFrom-mounted on every daemon pool, so the workflow-runner capability root would reach workers that run agent-authored code. Either point secrets.existingControllerSecret at a different Secret, or stop pointing secrets.existingSecret at the chart-managed <fullname>-controller-secret name." $controller) -}}
{{- end -}}
{{- $controller -}}
{{- end }}

{{/*
Runner namespace the controller will actually see, so the collision guard and the
rendered WORKFLOW_RUNNER_NAMESPACE cannot disagree. With the rail on, the chart
pins workflowRunner.namespace and the admission boundary is built from it. With it
off, the operator provisioned the rail themselves and may forward a name via
config.workflowRunner.namespace; empty inherits the app's own default.
*/}}
{{- define "github-app.runnerNamespace" -}}
{{- if .Values.workflowRunner.enabled -}}
{{- .Values.workflowRunner.namespace | default "github-app-runners" -}}
{{- else -}}
{{- (default dict .Values.config.workflowRunner).namespace | default "github-app-runners" -}}
{{- end -}}
{{- end }}

{{/*
Workspace PVC name. Uses existingClaim when set, otherwise <fullname>-workspace.
*/}}
{{- define "github-app.workspacePVCName" -}}
{{- if .Values.workspace.persistence.existingClaim }}
{{- .Values.workspace.persistence.existingClaim }}
{{- else }}
{{- printf "%s-workspace" (include "github-app.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Postgres / Valkey Secret names (chart-managed, for the stateful sidecars).
*/}}
{{- define "github-app.postgresSecretName" -}}
{{- if .Values.postgres.auth.existingSecret }}
{{- .Values.postgres.auth.existingSecret }}
{{- else }}
{{- printf "%s-postgres-secret" (include "github-app.fullname" .) }}
{{- end }}
{{- end }}

{{- define "github-app.valkeySecretName" -}}
{{- if .Values.valkey.auth.existingSecret }}
{{- .Values.valkey.auth.existingSecret }}
{{- else }}
{{- printf "%s-valkey-secret" (include "github-app.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Generate a value that persists across upgrades via `lookup`.
Args (dict): key (secret data key, e.g. DAEMON_AUTH_TOKEN),
             secretName (which Secret to inspect),
             override (optional literal value that short-circuits generation),
             root (.).
Falls back to `randAlphaNum 64` when no existing Secret holds the key.
*/}}
{{- define "github-app.stableToken" -}}
{{- $override := .override -}}
{{- if $override -}}
{{- $override -}}
{{- else -}}
{{- $existing := lookup "v1" "Secret" .root.Release.Namespace .secretName -}}
{{- if and $existing (index $existing.data .key) -}}
{{- index $existing.data .key | b64dec -}}
{{- else -}}
{{- randAlphaNum 64 -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Resolved Postgres password (in-chart Postgres).
Reads from whichever Secret the StatefulSet mounts:
  - postgres.auth.existingSecret  → that Secret's POSTGRES_PASSWORD key.
  - otherwise                     → chart-managed Secret, stable across upgrades.
This keeps DATABASE_URL in sync with the password the Postgres pod actually uses.
*/}}
{{- define "github-app.postgresPassword" -}}
{{- if .Values.postgres.auth.existingSecret -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.postgres.auth.existingSecret -}}
{{- if and $existing (index $existing.data "POSTGRES_PASSWORD") -}}
{{- index $existing.data "POSTGRES_PASSWORD" | b64dec -}}
{{- end -}}
{{- else -}}
{{- include "github-app.stableToken" (dict
    "key" "POSTGRES_PASSWORD"
    "secretName" (printf "%s-postgres-secret" (include "github-app.fullname" .))
    "override" ""
    "root" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolved Valkey password (in-chart Valkey). Matches mcp-server-boilerplate shape
where the Secret key is lowercase `password`.
Reads from whichever Secret the Deployment mounts:
  - valkey.auth.existingSecret    → that Secret's `password` key.
  - valkey.auth.password literal  → use verbatim.
  - otherwise                     → chart-managed Secret, stable across upgrades.
*/}}
{{- define "github-app.valkeyPassword" -}}
{{- if .Values.valkey.auth.existingSecret -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.valkey.auth.existingSecret -}}
{{- if and $existing (index $existing.data "password") -}}
{{- index $existing.data "password" | b64dec -}}
{{- end -}}
{{- else if .Values.valkey.auth.password -}}
{{- .Values.valkey.auth.password -}}
{{- else -}}
{{- include "github-app.stableToken" (dict
    "key" "password"
    "secretName" (printf "%s-valkey-secret" (include "github-app.fullname" .))
    "override" ""
    "root" .) -}}
{{- end -}}
{{- end }}

{{/*
Resolved external-Postgres password (postgres.external.enabled=true path).
Order: external.existingSecret (read at render time) → external.password literal.
When external.existingSecret is set and exists, return its password key; else "".
Callers should only use when composing the DATABASE_URL from external fields.
*/}}
{{- define "github-app.externalPostgresPassword" -}}
{{- if .Values.postgres.external.existingSecret -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.postgres.external.existingSecret -}}
{{- if and $existing (index $existing.data .Values.postgres.external.existingSecretPasswordKey) -}}
{{- index $existing.data .Values.postgres.external.existingSecretPasswordKey | b64dec -}}
{{- end -}}
{{- else -}}
{{- .Values.postgres.external.password -}}
{{- end -}}
{{- end }}

{{/*
Resolved external-Valkey password. Mirrors externalPostgresPassword.
*/}}
{{- define "github-app.externalValkeyPassword" -}}
{{- if .Values.valkey.external.auth.existingSecret -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.valkey.external.auth.existingSecret -}}
{{- if and $existing (index $existing.data .Values.valkey.external.auth.existingSecretPasswordKey) -}}
{{- index $existing.data .Values.valkey.external.auth.existingSecretPasswordKey | b64dec -}}
{{- end -}}
{{- else -}}
{{- .Values.valkey.external.auth.password -}}
{{- end -}}
{{- end }}

{{/*
Composed DATABASE_URL. Resolution order (stops at first match):
  1. secrets.databaseUrl (literal) → use verbatim.
  2. postgres.enabled=true        → postgresql://u:p@<fullname>-postgres:port/db?sslmode=disable
  3. postgres.external.enabled=true → postgresql://u:p@host:port/db?sslmode=<sslmode>
  4. nothing                      → empty string.
Consumers: template that emits it skips writing the key when empty.
*/}}
{{- define "github-app.databaseUrl" -}}
{{- if .Values.secrets.databaseUrl -}}
{{- .Values.secrets.databaseUrl -}}
{{- else if .Values.postgres.enabled -}}
{{- $pw := include "github-app.postgresPassword" . -}}
{{- printf "postgresql://%s:%s@%s-postgres:%d/%s?sslmode=disable" .Values.postgres.auth.username $pw (include "github-app.fullname" .) (int .Values.postgres.service.port) .Values.postgres.auth.database -}}
{{- else if .Values.postgres.external.enabled -}}
{{- $pw := include "github-app.externalPostgresPassword" . -}}
{{- printf "postgresql://%s:%s@%s:%d/%s?sslmode=%s" .Values.postgres.external.username $pw .Values.postgres.external.host (int .Values.postgres.external.port) .Values.postgres.external.database .Values.postgres.external.sslmode -}}
{{- end -}}
{{- end }}

{{/*
─────────────────────────── DAEMON POOL HELPERS ───────────────────────────
*/}}

{{/*
Daemon pool fully-qualified name: <fullname>-daemon-<poolName>, max 63 chars.
The pool suffix is preserved by truncating the base to fit, preventing collisions
when a long release name would push two different pool names to the same string.
Args (dict): root (.), poolName (string).
*/}}
{{- define "github-app.daemon.fullname" -}}
{{- $suffix := printf "-daemon-%s" .poolName -}}
{{- $base := include "github-app.fullname" .root | trunc (int (sub 63 (len $suffix))) | trimSuffix "-" -}}
{{- printf "%s%s" $base $suffix | trimSuffix "-" -}}
{{- end }}

{{/*
Daemon pool selector labels. Extends base selectorLabels with component + pool.
Args (dict): root (.), poolName (string).
*/}}
{{- define "github-app.daemon.selectorLabels" -}}
{{- include "github-app.selectorLabels" .root }}
app.kubernetes.io/component: daemon
app.kubernetes.io/pool: {{ .poolName }}
{{- end }}

{{/*
Daemon pool service account name.
Resolution: pool.serviceAccount.name → daemon.serviceAccount.name → orchestrator SA name.
Args (dict): root (.), pool (pool spec).
*/}}
{{- define "github-app.daemon.serviceAccountName" -}}
{{- $poolSA := .pool.serviceAccount | default dict }}
{{- if $poolSA.name }}
{{- $poolSA.name }}
{{- else if .root.Values.daemon.serviceAccount.name }}
{{- .root.Values.daemon.serviceAccount.name }}
{{- else }}
{{- include "github-app.serviceAccountName" .root }}
{{- end }}
{{- end }}

{{/*
ORCHESTRATOR_URL for a daemon pool.
Resolution: pool.orchestratorUrl → daemon.orchestratorUrl → ws://<fullname>:<wsPort>/ws.
Args (dict): root (.), pool (pool spec).
*/}}
{{- define "github-app.daemon.orchestratorUrl" -}}
{{- if .pool.orchestratorUrl }}
{{- .pool.orchestratorUrl }}
{{- else if .root.Values.daemon.orchestratorUrl }}
{{- .root.Values.daemon.orchestratorUrl }}
{{- else }}
{{- printf "ws://%s:%v/ws" (include "github-app.fullname" .root) .root.Values.config.wsPort }}
{{- end }}
{{- end }}

{{/*
Composed VALKEY_URL. Same resolution order as databaseUrl.
*/}}
{{- define "github-app.valkeyUrl" -}}
{{- if .Values.secrets.valkeyUrl -}}
{{- .Values.secrets.valkeyUrl -}}
{{- else if .Values.valkey.enabled -}}
{{- $host := printf "%s-valkey" (include "github-app.fullname" .) -}}
{{- if .Values.valkey.auth.enabled -}}
{{- $pw := include "github-app.valkeyPassword" . -}}
{{- printf "redis://default:%s@%s:%d/0" $pw $host (int .Values.valkey.service.port) -}}
{{- else -}}
{{- printf "redis://%s:%d/0" $host (int .Values.valkey.service.port) -}}
{{- end -}}
{{- else if .Values.valkey.external.enabled -}}
{{- if .Values.valkey.external.auth.enabled -}}
{{- $pw := include "github-app.externalValkeyPassword" . -}}
{{- printf "redis://default:%s@%s:%d/%d" $pw .Values.valkey.external.host (int .Values.valkey.external.port) (int .Values.valkey.external.database) -}}
{{- else -}}
{{- printf "redis://%s:%d/%d" .Values.valkey.external.host (int .Values.valkey.external.port) (int .Values.valkey.external.database) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Orchestrator-variant image (repository:tag). Used by the webhook Deployment.
Tag precedence: tagOverride arg → .Values.image.orchestrator.tag → "{{ .Chart.AppVersion }}-orchestrator".
Repository precedence: repoOverride arg → .Values.image.repository.
Args (dict): root (.), repoOverride (string, optional), tagOverride (string, optional).
*/}}
{{- define "github-app.image.orchestrator" -}}
{{- $args := . -}}
{{- $repo := $args.repoOverride | default $args.root.Values.image.repository -}}
{{- $tag := $args.tagOverride | default $args.root.Values.image.orchestrator.tag | default (printf "%s-orchestrator" $args.root.Chart.AppVersion) -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end }}

{{/*
Daemon-variant image (repository:tag). Used by daemon pool Deployments and
the ephemeral-daemon DAEMON_IMAGE fallback. Precedence mirrors .image.orchestrator.
Args (dict): root (.), repoOverride (string, optional), tagOverride (string, optional).
*/}}
{{- define "github-app.image.daemon" -}}
{{- $args := . -}}
{{- $repo := $args.repoOverride | default $args.root.Values.image.repository -}}
{{- $tag := $args.tagOverride | default $args.root.Values.image.daemon.tag | default (printf "%s-daemon" $args.root.Chart.AppVersion) -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end }}

{{/*
Origin of config.ephemeralDaemon.orchestratorPublicUrl: scheme and authority, no
path, no trailing slash.

The runner's ORCHESTRATOR_URL is built by the app as `new URL(publicUrl)` with the
pathname replaced, and the policy asserts that value equals
`orchestratorOrigin + '/ws/workflow-runner/' + ...`. WHATWG URL serialisation drops
the port when it is the scheme default and ASCII-lowercases the host, while Go's
urlParse preserves both, so an explicit :443 and any uppercase must be normalised
here too or every runner Pod is denied.

Plaintext is accepted only for a cluster-local Service name, which cannot resolve
outside the cluster, so an in-cluster runner can dial the orchestrator Service
directly instead of hairpinning out through an ingress VIP. A live GitHub
installation token crosses that socket, so every other host must still be wss://.
*/}}
{{- define "github-app.workflowRunner.orchestratorOrigin" -}}
{{- $url := .Values.config.ephemeralDaemon.orchestratorPublicUrl -}}
{{- $secure := regexMatch "^wss://(([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)*[A-Za-z]([A-Za-z0-9-]*[A-Za-z0-9])?)(:[1-9][0-9]{0,4})?(/.*)?$" $url -}}
{{- $clusterLocal := regexMatch "^ws://[a-z0-9-]+\\.[a-z0-9-]+\\.svc(\\.cluster\\.local)?(:[1-9][0-9]{0,4})?(/.*)?$" $url -}}
{{- if not (or $secure $clusterLocal) -}}
{{- fail (printf "config.ephemeralDaemon.orchestratorPublicUrl=%q is neither wss:// plus a plain DNS host and optional numeric port, nor ws://<service>.<namespace>.svc[.cluster.local][:port]. Userinfo, an IPv6 literal and percent-encoding all serialise differently in Go and WHATWG, so the rendered orchestratorOrigin would not match the URL the runner reports and admission would deny every Pod; the controller rejects embedded credentials outright. A live GitHub installation token crosses this socket, so plaintext is confined to names that cannot resolve outside the cluster." $url) -}}
{{- end -}}
{{- $host := lower (urlParse $url).host -}}
{{- /* The patterns above bound the port to five digits, not to its range. A
port over 65535 renders here but fails `new URL(publicUrl)` in the runner, which
is a 16-bit field, so the attempt dies at startup instead of at render. */ -}}
{{- $port := "" -}}
{{- if contains ":" $host -}}{{- $port = $host | splitList ":" | last -}}{{- end -}}
{{- if and $port (gt (atoi $port) 65535) -}}
{{- fail (printf "config.ephemeralDaemon.orchestratorPublicUrl port %q is above 65535. A port is a 16-bit field, so the runner's new URL(publicUrl) rejects it and every attempt fails at startup." $port) -}}
{{- end -}}
{{- $defaultPort := ternary ":443" ":80" $secure -}}
{{- if hasSuffix $defaultPort $host -}}
{{- $host = trimSuffix $defaultPort $host -}}
{{- end -}}
{{- printf "%s://%s" (ternary "wss" "ws" $secure) $host -}}
{{- end }}

{{/*
Comma-joined Secret key names the runner may mount, in the order the app's
credential chain emits them (src/shared/workflow-runner-provider.ts).

workflowRunner.providerCredentials wins when set. It has to, because the common
deployment uses secrets.existingSecret, where the chart cannot see which
credential is actually populated. Deriving the wrong chain renders a boundary that
looks valid and denies every Pod, so an underivable case fails the render instead.
*/}}
{{- define "github-app.workflowRunner.providerCredentials" -}}
{{- $wr := .Values.workflowRunner -}}
{{- if $wr.providerCredentials -}}
{{- join "," $wr.providerCredentials -}}
{{- else if eq .Values.config.provider "anthropic" -}}
{{- if (trim (.Values.secrets.anthropicApiKey | default "")) -}}
ANTHROPIC_API_KEY
{{- else if (trim (.Values.secrets.claudeCodeOauthToken | default "")) -}}
CLAUDE_CODE_OAUTH_TOKEN
{{- else -}}
{{- fail "workflowRunner.providerCredentials is empty and the Anthropic credential cannot be derived: neither secrets.anthropicApiKey nor secrets.claudeCodeOauthToken is set inline (secrets.existingSecret hides them from the chart). Set workflowRunner.providerCredentials to the Secret key the runner should mount, e.g. [\"CLAUDE_CODE_OAUTH_TOKEN\"], or set the credential inline." -}}
{{- end -}}
{{- else if (trim (.Values.secrets.awsBearerTokenBedrock | default "")) -}}
AWS_BEARER_TOKEN_BEDROCK
{{- else if and (trim (.Values.secrets.awsAccessKeyId | default "")) (trim (.Values.secrets.awsSecretAccessKey | default "")) -}}
{{- if (trim (.Values.secrets.awsSessionToken | default "")) -}}
AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_SESSION_TOKEN
{{- else -}}
AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY
{{- end -}}
{{- else -}}
{{- fail "workflowRunner.providerCredentials is empty and the Bedrock credential chain cannot be derived: set secrets.awsBearerTokenBedrock, or secrets.awsAccessKeyId plus secrets.awsSecretAccessKey, or list the Secret keys explicitly in workflowRunner.providerCredentials. AWS_PROFILE is not usable: runner Pods mount no profile files." -}}
{{- end -}}
{{- end }}

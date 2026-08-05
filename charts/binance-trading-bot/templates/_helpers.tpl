{{/*
Expand the name of the chart.
*/}}
{{- define "binance-trading-bot.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this
(by the DNS naming spec). If the release name already contains the chart name it
is used as-is, so `helm install binance-trading-bot` does not double the name.
*/}}
{{- define "binance-trading-bot.fullname" -}}
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
{{- define "binance-trading-bot.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "binance-trading-bot.labels" -}}
helm.sh/chart: {{ include "binance-trading-bot.chart" . }}
{{ include "binance-trading-bot.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "binance-trading-bot.selectorLabels" -}}
app.kubernetes.io/name: {{ include "binance-trading-bot.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "binance-trading-bot.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "binance-trading-bot.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name for a resource this chart derives from the release name by suffix.

fullname already truncates to 63, so appending to it can exceed the RFC 1035
limit that Services, StatefulSets and PVCs are held to, and the API server
rejects the object at apply time. For the bundled Postgres that lands mid
hook-phase and leaves the earlier hooks behind.

The base is shortened by the suffix length first, rather than truncating the
joined string: a 63-character fullname would otherwise lose the suffix outright
and every derived name would collapse onto the same string, so the postgres and
valkey Services would collide and the install would fail on a duplicate
resource. Every consumer of a derived name goes through here, including the DSN
in secret.yaml, so a truncated Service and the host that addresses it cannot
disagree.

Usage: include "binance-trading-bot.componentName" (dict "ctx" $ "suffix" "postgres")
*/}}
{{- define "binance-trading-bot.componentName" -}}
{{- $budget := int (sub 62 (len .suffix)) }}
{{- printf "%s-%s" (include "binance-trading-bot.fullname" .ctx | trunc $budget | trimSuffix "-") .suffix }}
{{- end }}

{{/*
Node placement shared by every pod the chart creates, app workloads and bundled
datastores alike, so a cluster with tainted or labelled nodes is configured once
rather than once per component. Affinity is deliberately absent: it stays on the
app Deployments, where a pod anti-affinity keyed on the app labels belongs.

Indentation is baked in for a pod spec, which is the only level it renders at.
*/}}
{{- define "binance-trading-bot.nodePlacement" -}}
{{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
{{- end }}
{{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
{{- end }}
{{- end }}

{{- define "binance-trading-bot.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/*
Secret holding every credential. Chart-managed unless the operator supplies one.
*/}}
{{- define "binance-trading-bot.secretName" -}}
{{- default (include "binance-trading-bot.fullname" .) .Values.existingSecret }}
{{- end }}

{{/*
The role that serves port 3000. Service selectors are equality-only, so the
primary Service has to name exactly one component rather than match a set.
*/}}
{{- define "binance-trading-bot.httpRole" -}}
{{- ternary "api" "all" (eq .Values.topology "split") }}
{{- end }}

{{/*
Roles to render a Deployment for, as a space-separated string.
*/}}
{{- define "binance-trading-bot.roles" -}}
{{- ternary "api worker study" "all" (eq .Values.topology "split") }}
{{- end }}

{{/*
WEB_ORIGIN. Explicit value wins, then the first ingress host. Failing the render
beats emitting a guess: the app accepts no wildcards and a wrong origin breaks
CORS, CSRF and the WebSocket upgrade only once a browser connects.
*/}}
{{- define "binance-trading-bot.webOrigin" -}}
{{- if .Values.webOrigin }}
{{- .Values.webOrigin }}
{{- else if and .Values.ingress.enabled .Values.ingress.hosts (first .Values.ingress.hosts).host }}
{{- $scheme := ternary "https" "http" (gt (len .Values.ingress.tls) 0) }}
{{- printf "%s://%s" $scheme (first .Values.ingress.hosts).host }}
{{- else }}
{{- fail "webOrigin could not be resolved. Set webOrigin to the exact browser origin (scheme://host[:port]), or enable ingress with a host to derive it. WEB_ORIGIN accepts no wildcards and gates CORS, Better Auth CSRF and the WebSocket upgrade." }}
{{- end }}
{{- end }}

{{/*
Guard for a credential that gets interpolated into a connection URL without
percent-encoding. RFC 3986 unreserved set, minus "~" which some clients still
mishandle. Lives here rather than in secret.yaml because a define nested inside
that file's top-level `if` is a template parse error.
*/}}
{{- define "binance-trading-bot.assertUrlSafe" -}}
{{/*
An all-digit value is parsed as a number, not a string: float64 from a values
file, int64 from --set. YAML's float64 formats back as "1.2345678e+07", which
the DSN below would carry verbatim, so this has to fail rather than coerce.
*/}}
{{- if ne (kindOf .value) "string" }}
{{- fail (printf "%s must be quoted: an unquoted all-digit value is parsed as a number and reaches the connection URL in scientific notation rather than as the digits you typed. Wrap it in quotes, or pass it with --set-string." .key) }}
{{- end }}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" .value) }}
{{- fail (printf "%s must contain only [A-Za-z0-9._-]: it is interpolated into a connection URL without percent-encoding, and a reserved character there corrupts the DSN instead of failing." .key) }}
{{- end }}
{{- end }}

{{/*
Environment variable name carrying one OTLP header value into the collector.
Header values are credentials, so they reach the collector config through env
substitution rather than being written into its readable ConfigMap. Shared by
the Secret, the ConfigMap and the Deployment so the three cannot drift.
*/}}
{{- define "binance-trading-bot.otlpHeaderEnv" -}}
{{- printf "OTLP_HEADER_%s" (. | trim | upper | replace "-" "_" | replace "." "_") }}
{{- end }}

{{/*
OTLP endpoint the app exports to: the bundled collector when enabled, otherwise
whatever external backend is configured. Empty means tracing export is off.
*/}}
{{- define "binance-trading-bot.otlpEndpoint" -}}
{{- if .Values.otelCollector.enabled }}
{{- printf "http://%s:4318" (include "binance-trading-bot.componentName" (dict "ctx" . "suffix" "otel-collector")) }}
{{- else }}
{{- .Values.otlp.endpoint }}
{{- end }}
{{- end }}

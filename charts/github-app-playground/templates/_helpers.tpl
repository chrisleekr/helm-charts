{{/*
Expand the name of the chart.
*/}}
{{- define "github-app-playground.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "github-app-playground.fullname" -}}
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
{{- define "github-app-playground.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "github-app-playground.labels" -}}
helm.sh/chart: {{ include "github-app-playground.chart" . }}
{{ include "github-app-playground.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "github-app-playground.selectorLabels" -}}
app.kubernetes.io/name: {{ include "github-app-playground.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "github-app-playground.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "github-app-playground.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding app credentials. Uses config.existingSecret when set,
otherwise the chart-managed name <fullname>-secret.
*/}}
{{- define "github-app-playground.secretName" -}}
{{- if .Values.config.existingSecret }}
{{- .Values.config.existingSecret }}
{{- else }}
{{- printf "%s-secret" (include "github-app-playground.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Workspace PVC name. Uses existingClaim when set, otherwise <fullname>-workspace.
*/}}
{{- define "github-app-playground.workspacePVCName" -}}
{{- if .Values.workspace.persistence.existingClaim }}
{{- .Values.workspace.persistence.existingClaim }}
{{- else }}
{{- printf "%s-workspace" (include "github-app-playground.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Postgres / Valkey Secret names (chart-managed, for the stateful sidecars).
*/}}
{{- define "github-app-playground.postgresSecretName" -}}
{{- if .Values.postgres.auth.existingSecret }}
{{- .Values.postgres.auth.existingSecret }}
{{- else }}
{{- printf "%s-postgres-secret" (include "github-app-playground.fullname" .) }}
{{- end }}
{{- end }}

{{- define "github-app-playground.valkeySecretName" -}}
{{- if .Values.valkey.auth.existingSecret }}
{{- .Values.valkey.auth.existingSecret }}
{{- else }}
{{- printf "%s-valkey-secret" (include "github-app-playground.fullname" .) }}
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
{{- define "github-app-playground.stableToken" -}}
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
Preference: .Values.postgres.auth.existingSecret → stable token generated value.
When postgres.auth.existingSecret is set, this helper is not consulted.
*/}}
{{- define "github-app-playground.postgresPassword" -}}
{{- include "github-app-playground.stableToken" (dict
    "key" "POSTGRES_PASSWORD"
    "secretName" (printf "%s-postgres-secret" (include "github-app-playground.fullname" .))
    "override" ""
    "root" .) -}}
{{- end }}

{{/*
Resolved Valkey password (in-chart Valkey). Matches mcp-server-boilerplate shape
where the Secret key is lowercase `password`.
*/}}
{{- define "github-app-playground.valkeyPassword" -}}
{{- if .Values.valkey.auth.password -}}
{{- .Values.valkey.auth.password -}}
{{- else -}}
{{- include "github-app-playground.stableToken" (dict
    "key" "password"
    "secretName" (printf "%s-valkey-secret" (include "github-app-playground.fullname" .))
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
{{- define "github-app-playground.externalPostgresPassword" -}}
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
{{- define "github-app-playground.externalValkeyPassword" -}}
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
  1. config.databaseUrl (literal) → use verbatim.
  2. postgres.enabled=true        → postgresql://u:p@<fullname>-postgres:port/db?sslmode=disable
  3. postgres.external.enabled=true → postgresql://u:p@host:port/db?sslmode=<sslmode>
  4. nothing                      → empty string.
Consumers: template that emits it skips writing the key when empty.
*/}}
{{- define "github-app-playground.databaseUrl" -}}
{{- if .Values.config.databaseUrl -}}
{{- .Values.config.databaseUrl -}}
{{- else if .Values.postgres.enabled -}}
{{- $pw := include "github-app-playground.postgresPassword" . -}}
{{- printf "postgresql://%s:%s@%s-postgres:%d/%s?sslmode=disable" .Values.postgres.auth.username $pw (include "github-app-playground.fullname" .) (int .Values.postgres.service.port) .Values.postgres.auth.database -}}
{{- else if .Values.postgres.external.enabled -}}
{{- $pw := include "github-app-playground.externalPostgresPassword" . -}}
{{- printf "postgresql://%s:%s@%s:%d/%s?sslmode=%s" .Values.postgres.external.username $pw .Values.postgres.external.host (int .Values.postgres.external.port) .Values.postgres.external.database .Values.postgres.external.sslmode -}}
{{- end -}}
{{- end }}

{{/*
Composed VALKEY_URL. Same resolution order as databaseUrl.
*/}}
{{- define "github-app-playground.valkeyUrl" -}}
{{- if .Values.config.valkeyUrl -}}
{{- .Values.config.valkeyUrl -}}
{{- else if .Values.valkey.enabled -}}
{{- $host := printf "%s-valkey" (include "github-app-playground.fullname" .) -}}
{{- if .Values.valkey.auth.enabled -}}
{{- $pw := include "github-app-playground.valkeyPassword" . -}}
{{- printf "redis://default:%s@%s:%d/0" $pw $host (int .Values.valkey.service.port) -}}
{{- else -}}
{{- printf "redis://%s:%d/0" $host (int .Values.valkey.service.port) -}}
{{- end -}}
{{- else if .Values.valkey.external.enabled -}}
{{- if .Values.valkey.external.auth.enabled -}}
{{- $pw := include "github-app-playground.externalValkeyPassword" . -}}
{{- printf "redis://default:%s@%s:%d/%d" $pw .Values.valkey.external.host (int .Values.valkey.external.port) (int .Values.valkey.external.database) -}}
{{- else -}}
{{- printf "redis://%s:%d/%d" .Values.valkey.external.host (int .Values.valkey.external.port) (int .Values.valkey.external.database) -}}
{{- end -}}
{{- end -}}
{{- end }}

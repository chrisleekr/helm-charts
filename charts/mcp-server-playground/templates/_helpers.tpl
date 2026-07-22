{{/*
Expand the name of the chart.
*/}}
{{- define "mcp-server-playground.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "mcp-server-playground.fullname" -}}
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
{{- define "mcp-server-playground.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mcp-server-playground.labels" -}}
helm.sh/chart: {{ include "mcp-server-playground.chart" . }}
{{ include "mcp-server-playground.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mcp-server-playground.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-server-playground.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mcp-server-playground.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mcp-server-playground.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate JWT secret if empty.
  If secret exists, then use the existing value to avoid re-generating it.
*/}}
{{- define "mcp-server-playground.jwtSecret" -}}
{{- if .Values.mcpServer.secrets.auth.jwtSecret }}
{{- .Values.mcpServer.secrets.auth.jwtSecret }}
{{- else }}
{{- $secretName := printf "%s-secret" (include "mcp-server-playground.fullname" .) }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- $existingSecret.data.MCP_CONFIG_SERVER_AUTH_JWT_SECRET | b64dec }}
{{- else }}
{{- randAlphaNum 64 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Generate Valkey password if empty.
  If secret exists, then use the existing value to avoid re-generating it.
*/}}
{{/*
  Precedence: existingSecret > password > generated. existingSecret must win over
  password so the storage URL and the Valkey Deployment (which reads existingSecret)
  agree on one password. When existingSecret is unset, keep password-over-generated
  so an updated password value is not shadowed by the sticky generated secret.
*/}}
{{- define "mcp-server-playground.valkeyPassword" -}}
{{- if .Values.valkey.auth.existingSecret }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace .Values.valkey.auth.existingSecret }}
{{- if $existingSecret }}
{{- $existingSecret.data.password | b64dec }}
{{- end }}
{{- else if .Values.valkey.auth.password }}
{{- .Values.valkey.auth.password }}
{{- else }}
{{- $secretName := printf "%s-valkey-secret" (include "mcp-server-playground.fullname" .) }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- $existingSecret.data.password | b64dec }}
{{- else }}
{{- randAlphaNum 64 }}
{{- end }}
{{- end }}
{{- end }}

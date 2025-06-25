{{/*
Expand the name of the chart.
*/}}
{{- define "mcp-server-boilerplate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "mcp-server-boilerplate.fullname" -}}
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
{{- define "mcp-server-boilerplate.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mcp-server-boilerplate.labels" -}}
helm.sh/chart: {{ include "mcp-server-boilerplate.chart" . }}
{{ include "mcp-server-boilerplate.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mcp-server-boilerplate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-server-boilerplate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mcp-server-boilerplate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mcp-server-boilerplate.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate JWT secret if empty.
  If secret exists, then use the existing value to avoid re-generating it.
*/}}
{{- define "mcp-server-boilerplate.jwtSecret" -}}
{{- if .Values.mcpServer.secrets.auth.jwtSecret }}
{{- .Values.mcpServer.secrets.auth.jwtSecret }}
{{- else }}
{{- $secretName := printf "%s-secret" (include "mcp-server-boilerplate.fullname" .) }}
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
{{- define "mcp-server-boilerplate.valkeyPassword" -}}
{{- if .Values.valkey.auth.password }}
{{- .Values.valkey.auth.password }}
{{- else }}
{{- $secretName := printf "%s-valkey-secret" (include "mcp-server-boilerplate.fullname" .) }}
{{- $existingSecret := lookup "v1" "Secret" .Release.Namespace $secretName }}
{{- if $existingSecret }}
{{- $existingSecret.data.password | b64dec }}
{{- else }}
{{- randAlphaNum 64 }}
{{- end }}
{{- end }}
{{- end }}

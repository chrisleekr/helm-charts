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
Return the name of the Secret to use for app credentials.
Uses existingSecret if provided, otherwise uses the chart-managed secret name.
*/}}
{{- define "github-app-playground.secretName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- printf "%s-secret" (include "github-app-playground.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Return the name of the workspace PVC to use.
Uses existingClaim if provided, otherwise uses the chart-managed PVC name.
*/}}
{{- define "github-app-playground.workspacePVCName" -}}
{{- if .Values.workspace.persistence.existingClaim }}
{{- .Values.workspace.persistence.existingClaim }}
{{- else }}
{{- printf "%s-workspace" (include "github-app-playground.fullname" .) }}
{{- end }}
{{- end }}

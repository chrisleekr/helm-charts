{{- define "edge-proxy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "edge-proxy.fullname" -}}
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

{{/* Component name under the DNS label limit: (dict "ctx" . "suffix" "edge"). */}}
{{- define "edge-proxy.componentName" -}}
{{- $budget := sub 63 (add 1 (len .suffix)) -}}
{{- printf "%s-%s" (include "edge-proxy.fullname" .ctx | trunc (int $budget) | trimSuffix "-") .suffix -}}
{{- end }}

{{- define "edge-proxy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "edge-proxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "edge-proxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "edge-proxy.labels" -}}
helm.sh/chart: {{ include "edge-proxy.chart" . }}
{{ include "edge-proxy.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Image reference for one component: (dict "ctx" . "image" .Values.edge.image "key" "edge.image.tag").
0.0.0 is the unpublished placeholder and no such image exists, so a render
without an explicit tag fails instead of deploying an unpullable image.
*/}}
{{- define "edge-proxy.image" -}}
{{- $tag := .image.tag | default .ctx.Chart.AppVersion | toString -}}
{{- if eq $tag "0.0.0" -}}
{{- fail (printf "%s is required: edge-proxy has no published release yet." .key) -}}
{{- end -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end }}

{{/* Hash of the shared ConfigMap data, so a config change restarts both workloads. */}}
{{- define "edge-proxy.configChecksum" -}}
{{- include (print .Template.BasePath "/configmap.yaml") . | fromYaml | dig "data" dict | toYaml | sha256sum -}}
{{- end }}

{{/* Renders a map of extra environment variables as name/value pairs. */}}
{{- define "edge-proxy.env" -}}
{{- range $name, $value := . }}
- name: {{ $name }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- end }}

{{/*
CloudNativePG Cluster name. The operator derives Services such as <name>-rw and
the <name>-app Secret from it, so it leaves room under the 63-character limit.
*/}}
{{- define "edge-proxy.pgCluster" -}}
{{- printf "%s-pg" (include "edge-proxy.fullname" . | trunc 50 | trimSuffix "-") -}}
{{- end }}

{{/* Service name of the bundled Valkey, mirroring the valkey chart's fullname helper. */}}
{{- define "edge-proxy.valkeyHost" -}}
{{- if .Values.valkey.fullnameOverride -}}
{{- .Values.valkey.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else if contains "valkey" .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-valkey" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "edge-proxy.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "edge-proxy.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
Edge topology spread. null renders the default: zones, then nodes, preferred
so a small cluster still schedules. matchLabelKeys limits the count to the
current ReplicaSet, so old pods of a rollout do not skew it. [] renders none.
*/}}
{{- define "edge-proxy.edgeSpread" -}}
{{- $tsc := .Values.edge.topologySpreadConstraints -}}
{{- if kindIs "invalid" $tsc -}}
{{- $selector := dict "matchLabels" (merge (include "edge-proxy.selectorLabels" . | fromYaml) (dict "app.kubernetes.io/component" "edge")) -}}
{{- $tsc = list -}}
{{- range $key := list "topology.kubernetes.io/zone" "kubernetes.io/hostname" -}}
{{- $tsc = append $tsc (dict "maxSkew" 1 "topologyKey" $key "whenUnsatisfiable" "ScheduleAnyway" "labelSelector" $selector "matchLabelKeys" (list "pod-template-hash")) -}}
{{- end -}}
{{- end -}}
{{- with $tsc }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Secret names. bootstrap.generateSecrets creates one Secret per component, so
the kubelet on an edge node never receives admin's password or audit key, and
<fullname>-pg-runtime for the bundled Postgres. An existingSecret replaces the
generated one for its component.
*/}}
{{- define "edge-proxy.generatedEdgeSecret" -}}
{{- include "edge-proxy.componentName" (dict "ctx" . "suffix" "edge-generated") -}}
{{- end }}

{{- define "edge-proxy.generatedAdminSecret" -}}
{{- include "edge-proxy.componentName" (dict "ctx" . "suffix" "admin-generated") -}}
{{- end }}

{{- define "edge-proxy.edgeSecret" -}}
{{- if .Values.edge.existingSecret -}}
{{- .Values.edge.existingSecret -}}
{{- else if .Values.bootstrap.generateSecrets -}}
{{- include "edge-proxy.generatedEdgeSecret" . -}}
{{- else -}}
{{- fail "edge.existingSecret is required when bootstrap.generateSecrets=false." -}}
{{- end -}}
{{- end }}

{{- define "edge-proxy.adminSecret" -}}
{{- if .Values.admin.existingSecret -}}
{{- .Values.admin.existingSecret -}}
{{- else if .Values.bootstrap.generateSecrets -}}
{{- include "edge-proxy.generatedAdminSecret" . -}}
{{- else -}}
{{- fail "admin.existingSecret is required when bootstrap.generateSecrets=false." -}}
{{- end -}}
{{- end }}

{{- define "edge-proxy.generatedLogsSecret" -}}
{{- include "edge-proxy.componentName" (dict "ctx" . "suffix" "logs-generated") -}}
{{- end }}

{{- define "edge-proxy.logsSecret" -}}
{{- if .Values.logShipper.existingSecret -}}
{{- .Values.logShipper.existingSecret -}}
{{- else if .Values.bootstrap.generateSecrets -}}
{{- include "edge-proxy.generatedLogsSecret" . -}}
{{- else -}}
{{- fail "logShipper.existingSecret is required when bootstrap.generateSecrets=false; or set logShipper.enabled=false." -}}
{{- end -}}
{{- end }}

{{- define "edge-proxy.pgRuntimeSecret" -}}
{{- if .Values.postgres.cnpg.runtimeRoleSecret -}}
{{- .Values.postgres.cnpg.runtimeRoleSecret -}}
{{- else if .Values.bootstrap.generateSecrets -}}
{{- printf "%s-pg-runtime" (include "edge-proxy.fullname" . | trunc 52 | trimSuffix "-") -}}
{{- else -}}
{{- fail "postgres.cnpg.runtimeRoleSecret is required when bootstrap.generateSecrets=false." -}}
{{- end -}}
{{- end }}

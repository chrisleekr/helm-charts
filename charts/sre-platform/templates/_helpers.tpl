{{/* Chart name. */}}
{{- define "sre-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Release-scoped base name. */}}
{{- define "sre-platform.fullname" -}}
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

{{/* Collision-safe component name under the DNS label limit. */}}
{{- define "sre-platform.componentName" -}}
{{- $suffix := .suffix -}}
{{- $budget := sub 63 (add 1 (len $suffix)) -}}
{{- printf "%s-%s" (include "sre-platform.fullname" .ctx | trunc (int $budget) | trimSuffix "-") $suffix -}}
{{- end }}

{{- define "sre-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sre-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sre-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sre-platform.labels" -}}
helm.sh/chart: {{ include "sre-platform.chart" . }}
{{ include "sre-platform.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "sre-platform.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sre-platform.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "sre-platform.secretName" -}}
{{- required "existingSecret is required; create it before installing the chart." .Values.existingSecret }}
{{- end }}

{{/*
True when image.tag already carries its own digest, as "<tag>@sha256:<64 hex>".
Continuous-delivery controllers that follow a mutable tag write the resolved
digest back into a single Helm key; Argo CD Image Updater's digest strategy is
one. Such a tag is already an immutable reference, so image.digest stays empty
and the chart passes the value through instead of composing one.
*/}}
{{- define "sre-platform.tagCarriesDigest" -}}
{{- if contains "@" (.Values.image.tag | toString) -}}true{{- end -}}
{{- end }}

{{- define "sre-platform.image" -}}
{{- if include "sre-platform.tagCarriesDigest" . -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- else if .Values.image.tag -}}
{{- printf "%s:%s@%s" .Values.image.repository .Values.image.tag .Values.image.digest -}}
{{- else if .Values.image.releaseDigest -}}
{{- printf "%s:%s@%s" .Values.image.repository .Chart.AppVersion .Values.image.releaseDigest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Chart.AppVersion -}}
{{- end -}}
{{- end }}

{{/* Build the strict BOOTSTRAP_STAFF_PROVIDER JSON object from known keys. */}}
{{- define "sre-platform.bootstrapStaffProvider" -}}
{{- $provider := .Values.bootstrap.staffProvider -}}
{{- if not (kindIs "map" $provider) -}}
{{- fail "bootstrap.staffProvider must be a YAML mapping." -}}
{{- end -}}
{{- $allowed := list "displayName" "issuer" "browserClientId" "audience" "emailClaim" "jwksUri" -}}
{{- range $key, $value := $provider -}}
{{- if not (has $key $allowed) -}}
{{- fail (printf "bootstrap.staffProvider has unexpected key %s." $key) -}}
{{- end -}}
{{- end -}}
{{- $result := dict -}}
{{- range $key := list "displayName" "issuer" "browserClientId" "audience" -}}
{{- $raw := index $provider $key -}}
{{- if not (kindIs "string" $raw) -}}
{{- fail (printf "bootstrap.staffProvider.%s must be a quoted string." $key) -}}
{{- end -}}
{{- $value := trim $raw -}}
{{- if empty $value -}}
{{- fail (printf "bootstrap.staffProvider.%s is required when bootstrap.enabled=true." $key) -}}
{{- end -}}
{{- $_ := set $result $key $value -}}
{{- end -}}
{{- range $key := list "emailClaim" "jwksUri" -}}
{{- if hasKey $provider $key -}}
{{- $raw := index $provider $key -}}
{{- if not (kindIs "string" $raw) -}}
{{- fail (printf "bootstrap.staffProvider.%s must be a quoted string." $key) -}}
{{- end -}}
{{- $value := trim $raw -}}
{{- if $value -}}
{{- $_ := set $result $key $value -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $result -}}
{{- end }}

{{/* Build strict BOOTSTRAP_PLATFORM_ADMINS JSON and reject ambiguous entries. */}}
{{- define "sre-platform.bootstrapPlatformAdmins" -}}
{{- $admins := .Values.bootstrap.platformAdmins -}}
{{- if not (kindIs "slice" $admins) -}}
{{- fail "bootstrap.platformAdmins must be a YAML list of mappings." -}}
{{- end -}}
{{- if empty $admins -}}
{{- fail "bootstrap.enabled=true requires at least one entry in bootstrap.platformAdmins." -}}
{{- end -}}
{{- $entries := list -}}
{{- $subjects := dict -}}
{{- $subjectEmails := dict -}}
{{- $invitationEmails := dict -}}
{{- range $index, $admin := $admins -}}
{{- if not (kindIs "map" $admin) -}}
{{- fail (printf "bootstrap.platformAdmins[%v] must be a mapping with subject or email." $index) -}}
{{- end -}}
{{- range $key, $value := $admin -}}
{{- if not (has $key (list "subject" "email")) -}}
{{- fail (printf "bootstrap.platformAdmins[%v] has unexpected key %s; only subject and email are accepted." $index $key) -}}
{{- end -}}
{{- end -}}
{{- $subject := "" -}}
{{- $email := "" -}}
{{- if hasKey $admin "subject" -}}
{{- if not (kindIs "string" $admin.subject) -}}
{{- fail (printf "bootstrap.platformAdmins[%v].subject must be a quoted string." $index) -}}
{{- end -}}
{{- $subject = trim $admin.subject -}}
{{- end -}}
{{- if hasKey $admin "email" -}}
{{- if not (kindIs "string" $admin.email) -}}
{{- fail (printf "bootstrap.platformAdmins[%v].email must be a quoted string." $index) -}}
{{- end -}}
{{- $email = trim $admin.email -}}
{{- end -}}
{{- if and (empty $subject) (empty $email) -}}
{{- fail (printf "bootstrap.platformAdmins[%v] requires a non-empty subject or email." $index) -}}
{{- end -}}
{{- $emailKey := lower $email -}}
{{- if $subject -}}
{{- if hasKey $subjects $subject -}}
{{- fail (printf "bootstrap.platformAdmins[%v] repeats the subject of entry %v." $index (index $subjects $subject)) -}}
{{- end -}}
{{- $_ := set $subjects $subject $index -}}
{{- if and $email (hasKey $invitationEmails $emailKey) -}}
{{- fail (printf "bootstrap.platformAdmins[%v].email conflicts with email-only entry %v." $index (index $invitationEmails $emailKey)) -}}
{{- end -}}
{{- /* Recorded only on first sight, so a later subject entry carrying the same
address neither overwrites the index this error message reports nor fails. That
is deliberate: for a subject entry the OIDC subject is the identity and the email
is metadata, so two directory subjects may share one mailbox. README.md lists the
rejected shapes and this is not among them. If the application ever constrains
operator email to be unique, drop the hasKey test so a repeat fails here, the way
the invitation side already does. */ -}}
{{- if and $email (not (hasKey $subjectEmails $emailKey)) -}}
{{- $_ := set $subjectEmails $emailKey $index -}}
{{- end -}}
{{- $entry := dict "subject" $subject -}}
{{- if $email -}}{{- $_ := set $entry "email" $email -}}{{- end -}}
{{- $entries = append $entries $entry -}}
{{- else -}}
{{- if hasKey $subjectEmails $emailKey -}}
{{- fail (printf "bootstrap.platformAdmins[%v].email conflicts with subject entry %v." $index (index $subjectEmails $emailKey)) -}}
{{- end -}}
{{- if hasKey $invitationEmails $emailKey -}}
{{- fail (printf "bootstrap.platformAdmins[%v] repeats the email-only invitation of entry %v." $index (index $invitationEmails $emailKey)) -}}
{{- end -}}
{{- $_ := set $invitationEmails $emailKey $index -}}
{{- $entries = append $entries (dict "email" $email) -}}
{{- end -}}
{{- end -}}
{{- toJson $entries -}}
{{- end }}

{{/* Opaque desired-state marker that makes bootstrap-only changes visible to GitOps sync. */}}
{{- define "sre-platform.bootstrapRevision" -}}
{{- printf "%s\n%s" (include "sre-platform.bootstrapStaffProvider" .) (include "sre-platform.bootstrapPlatformAdmins" .) | sha256sum -}}
{{- end }}

{{- define "sre-platform.publicUrl" -}}
{{- $name := .name -}}
{{- $url := required (printf "public.%s is required." $name) .value | trimSuffix "/" -}}
{{- if not (regexMatch "^https?://[^[:space:]/?#@]+$" $url) -}}
{{- fail (printf "public.%s must be an http:// or https:// origin without a path, query, fragment, or credentials." $name) -}}
{{- end -}}
{{- $url -}}
{{- end }}

{{- define "sre-platform.dashboardUrl" -}}
{{- include "sre-platform.publicUrl" (dict "name" "dashboardUrl" "value" .Values.public.dashboardUrl) -}}
{{- end }}

{{- define "sre-platform.apiUrl" -}}
{{- include "sre-platform.publicUrl" (dict "name" "apiUrl" "value" .Values.public.apiUrl) -}}
{{- end }}

{{- define "sre-platform.apiWsUrl" -}}
{{- $url := include "sre-platform.apiUrl" . -}}
{{- if hasPrefix "https://" $url -}}
{{- printf "wss://%s" (trimPrefix "https://" $url) -}}
{{- else -}}
{{- printf "ws://%s" (trimPrefix "http://" $url) -}}
{{- end -}}
{{- end }}

{{/* Validate an optional public HTTP(S) URL that may include a path. */}}
{{- define "sre-platform.optionalWebUrl" -}}
{{- if not (kindIs "string" .value) -}}
{{- fail (printf "public.%s must be a quoted string." .name) -}}
{{- end -}}
{{- $url := trim .value -}}
{{- if and $url (not (regexMatch "^https?://[^[:space:]/?#@]+([/?#][^[:space:]@]*)?$" $url)) -}}
{{- fail (printf "public.%s must be an absolute http:// or https:// URL without credentials." .name) -}}
{{- end -}}
{{- $url -}}
{{- end }}

{{/* Validate the optional identifier recorded with accepted terms. */}}
{{- define "sre-platform.termsVersion" -}}
{{- if not (kindIs "string" .Values.public.termsVersion) -}}
{{- fail "public.termsVersion must be a quoted string." -}}
{{- end -}}
{{- trim .Values.public.termsVersion -}}
{{- end }}

{{- define "sre-platform.validate" -}}
{{- include "sre-platform.secretName" . -}}
{{- $bootstrap := and (eq .Chart.AppVersion "0.0.0") (empty .Values.image.tag) (empty .Values.image.digest) (empty .Values.image.releaseDigest) -}}
{{- $embeddedDigest := include "sre-platform.tagCarriesDigest" . -}}
{{- if $embeddedDigest -}}
{{- if not (regexMatch "^[^@]+@sha256:[a-f0-9]{64}$" (.Values.image.tag | toString)) -}}
{{- fail "image.tag containing @ must be <tag>@sha256:<64 hex>; it is passed through unchanged." -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- fail "image.tag already carries a digest; leave image.digest empty." -}}
{{- end -}}
{{- else if ne (empty .Values.image.tag) (empty .Values.image.digest) -}}
{{- fail "image.tag and image.digest must be set together for an image override." -}}
{{- end -}}
{{- if and .Values.image.digest (not (regexMatch "^sha256:[a-f0-9]{64}$" .Values.image.digest)) -}}
{{- fail "image.digest must be a sha256 OCI manifest digest." -}}
{{- end -}}
{{- if and .Values.image.releaseDigest (not (regexMatch "^sha256:[a-f0-9]{64}$" .Values.image.releaseDigest)) -}}
{{- fail "image.releaseDigest must be a sha256 OCI manifest digest." -}}
{{- end -}}
{{- if and (not $bootstrap) (empty .Values.image.tag) (empty .Values.image.releaseDigest) -}}
{{- fail "image.releaseDigest is required for every published chart version." -}}
{{- end -}}
{{- $dashboardOrigin := include "sre-platform.dashboardUrl" . -}}
{{- $apiOrigin := include "sre-platform.apiUrl" . -}}
{{- if eq $dashboardOrigin $apiOrigin -}}
{{- fail "public.dashboardUrl and public.apiUrl must be different origins." -}}
{{- end -}}
{{- $supportUrl := include "sre-platform.optionalWebUrl" (dict "name" "supportUrl" "value" .Values.public.supportUrl) -}}
{{- $termsUrl := include "sre-platform.optionalWebUrl" (dict "name" "termsUrl" "value" .Values.public.termsUrl) -}}
{{- $termsVersion := include "sre-platform.termsVersion" . -}}
{{- if ne (empty $termsUrl) (empty $termsVersion) -}}
{{- fail "public.termsUrl and public.termsVersion must be configured together." -}}
{{- end -}}
{{- required "auth0.issuer is required." .Values.auth0.issuer -}}
{{- required "auth0.audience is required." .Values.auth0.audience -}}
{{- required "auth0.domain is required." .Values.auth0.domain -}}
{{- required "auth0.clientId is required." .Values.auth0.clientId -}}
{{- required "embeddings.url is required." .Values.embeddings.url -}}
{{- if ne (toString .Values.embeddings.dim) "1024" -}}
{{- fail "embeddings.dim must be exactly 1024; the application schema is fixed to that dimension." -}}
{{- end -}}
{{- $llmProvider := .Values.llm.provider | trim -}}
{{- if and $llmProvider (not (or (eq $llmProvider "claude") (eq $llmProvider "openai"))) -}}
{{- fail "llm.provider must be empty, claude, or openai." -}}
{{- end -}}
{{- if eq $llmProvider "openai" -}}
{{- required "llm.openaiModel is required when llm.provider=openai." (.Values.llm.openaiModel | trim) -}}
{{- end -}}
{{- if not (kindIs "bool" .Values.smtp.enabled) -}}
{{- fail "smtp.enabled must be true or false." -}}
{{- end -}}
{{- if .Values.smtp.enabled -}}
{{- required "smtp.host is required when smtp.enabled=true." (.Values.smtp.host | trim) -}}
{{- $smtpPort := .Values.smtp.port | toString -}}
{{- if or (not (regexMatch "^[0-9]+$" $smtpPort)) (lt (atoi $smtpPort) 1) (gt (atoi $smtpPort) 65535) -}}
{{- fail "smtp.port must be an integer from 1 to 65535." -}}
{{- end -}}
{{- if not (kindIs "bool" .Values.smtp.secure) -}}
{{- fail "smtp.secure must be true or false." -}}
{{- end -}}
{{- $smtpFrom := .Values.smtp.from | trim -}}
{{- if not (regexMatch "^[^[:space:]@]+@[^[:space:]@]+$" $smtpFrom) -}}
{{- fail "smtp.from must be an email address when smtp.enabled=true." -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.config.registrationMode (list "open" "approval_required" "closed")) -}}
{{- fail "config.registrationMode must be open, approval_required, or closed." -}}
{{- end -}}
{{- $trustedProxyHops := .Values.config.trustedProxyHops | toString -}}
{{- if not (has $trustedProxyHops (list "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10")) -}}
{{- fail "config.trustedProxyHops must be an integer from 0 to 10." -}}
{{- end -}}
{{- range $entry := .Values.extraEnv -}}
{{- if has (get $entry "name") (list "REGISTRATION_MODE" "TRUST_PROXY_HOPS" "SUPPORT_URL" "TERMS_URL" "TERMS_VERSION" "SMTP_HOST" "SMTP_PORT" "SMTP_SECURE" "SMTP_FROM" "SMTP_USERNAME") -}}
{{- fail "extraEnv cannot replace public-site, SMTP, or security settings; use public, smtp, and config values." -}}
{{- end -}}
{{- end -}}
{{- if .Values.bootstrap.enabled -}}
{{- include "sre-platform.bootstrapStaffProvider" . -}}
{{- include "sre-platform.bootstrapPlatformAdmins" . -}}
{{- end -}}
{{- if and (not .Values.networkPolicy.enabled) (not .Values.networkPolicy.acknowledgeExternalPolicy) -}}
{{- fail "networkPolicy.enabled=false requires networkPolicy.acknowledgeExternalPolicy=true because the application URL guard cannot close DNS-rebinding races alone." -}}
{{- end -}}
{{- if and (or .Values.ingress.api.enabled .Values.ingress.dashboard.enabled) (not .Values.ingress.allowInsecure) -}}
  {{- if or (and .Values.ingress.api.enabled (empty .Values.ingress.api.tls)) (and .Values.ingress.dashboard.enabled (empty .Values.ingress.dashboard.tls)) -}}
  {{- fail "enabled ingresses require TLS. Set ingress.allowInsecure=true only when TLS terminates before the Kubernetes ingress." -}}
  {{- end -}}
{{- end -}}
{{- if .Values.ingress.api.enabled -}}
{{- required "ingress.api.host is required when the API ingress is enabled." .Values.ingress.api.host -}}
{{- $apiUrl := include "sre-platform.apiUrl" . -}}
{{- $apiHost := regexReplaceAll "^https?://" $apiUrl "" -}}
{{- if ne $apiHost .Values.ingress.api.host -}}
{{- fail "ingress.api.host must match the host in public.apiUrl." -}}
{{- end -}}
{{- if not (hasPrefix "https://" $apiUrl) -}}
{{- fail "public.apiUrl must use https:// when ingress.api is enabled." -}}
{{- end -}}
{{- end -}}
{{- if .Values.ingress.dashboard.enabled -}}
{{- required "ingress.dashboard.host is required when the dashboard ingress is enabled." .Values.ingress.dashboard.host -}}
{{- $dashboardUrl := include "sre-platform.dashboardUrl" . -}}
{{- $dashboardHost := regexReplaceAll "^https?://" $dashboardUrl "" -}}
{{- if ne $dashboardHost .Values.ingress.dashboard.host -}}
{{- fail "ingress.dashboard.host must match the host in public.dashboardUrl." -}}
{{- end -}}
{{- if not (hasPrefix "https://" $dashboardUrl) -}}
{{- fail "public.dashboardUrl must use https:// when ingress.dashboard is enabled." -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "sre-platform.placement" -}}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.topologySpreadConstraints }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

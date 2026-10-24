{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "mailpit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "mailpit.fullname" -}}
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
Chart label value.
*/}}
{{- define "mailpit.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "mailpit.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "mailpit.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "mailpit.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "mailpit.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "mailpit.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "mailpit.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mailpit.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. Tag empty: the entry of the artifacthub.io/images annotation
of Chart.yaml whose repository is image.repository (tag and digest as recorded
there). Tag set: that tag, plus image.digest if given; the chart digest never
applies to a user-chosen tag.
*/}}
{{- define "mailpit.image" -}}
{{- $repo := .Values.image.repository }}
{{- if .Values.image.tag }}
{{- if .Values.image.digest }}
{{- printf "%s:%s@%s" $repo .Values.image.tag .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" $repo .Values.image.tag }}
{{- end }}
{{- else }}
{{- $images := fromYamlArray (index .Chart.Annotations "artifacthub.io/images" | default "") }}
{{- if not $images }}
{{- fail "Chart.yaml: annotation artifacthub.io/images is missing, it holds the pinned image digest" }}
{{- end }}
{{- $found := "" }}
{{- range $images }}
{{- if hasPrefix (printf "%s:" $repo) .image }}
{{- $found = .image }}
{{- end }}
{{- end }}
{{- if not $found }}
{{- fail (printf "image.tag is required: %s is not an image pinned in Chart.yaml" $repo) }}
{{- end }}
{{- $found }}
{{- end }}
{{- end }}

{{/*
Webroot as upstream serves it: leading and trailing slash ("/", "/mail/").
*/}}
{{- define "mailpit.webroot" -}}
{{- $root := trimAll "/" (toString (.Values.config.MP_WEBROOT | default "")) }}
{{- if $root }}
{{- printf "/%s/" $root }}
{{- else }}
{{- "/" }}
{{- end }}
{{- end }}

{{/*
"true" when the separate metrics listener runs (port 9090).
*/}}
{{- define "mailpit.metrics" -}}
{{- $m := .Values.metrics }}
{{- if or $m.enabled $m.serviceMonitor.enabled $m.podMonitor.enabled }}true{{ end }}
{{- end }}

{{/*
Mounted Secrets, as a YAML list of {volume, secret, dir, env}: env maps each
upstream file variable to its path under dir. One entry per secrets.<x> with
a name. Htpasswd and relay/forward files use secrets.<x>.key, TLS Secrets the
kubernetes.io/tls keys.
*/}}
{{- define "mailpit.secretMounts" -}}
{{- $files := dict "forwardConfig" (list "forward-config" "MP_SMTP_FORWARD_CONFIG") "pop3Auth" (list "pop3-auth" "MP_POP3_AUTH_FILE") "relayConfig" (list "relay-config" "MP_SMTP_RELAY_CONFIG") "sendApiAuth" (list "send-api-auth" "MP_SEND_API_AUTH_FILE") "smtpAuth" (list "smtp-auth" "MP_SMTP_AUTH_FILE") "uiAuth" (list "ui-auth" "MP_UI_AUTH_FILE") }}
{{- $tls := dict "pop3Tls" (list "pop3-tls" "MP_POP3_TLS") "smtpTls" (list "smtp-tls" "MP_SMTP_TLS") "uiTls" (list "ui-tls" "MP_UI_TLS") }}
{{- $out := list }}
{{- range $key, $spec := $files }}
{{- $s := index $.Values.secrets $key }}
{{- if $s.name }}
{{- $dir := printf "/etc/mailpit/%s" (index $spec 0) }}
{{- $out = append $out (dict "volume" (index $spec 0) "secret" $s.name "dir" $dir "env" (dict (index $spec 1) (printf "%s/%s" $dir $s.key))) }}
{{- end }}
{{- end }}
{{- range $key, $spec := $tls }}
{{- $s := index $.Values.secrets $key }}
{{- if $s.name }}
{{- $dir := printf "/etc/mailpit/%s" (index $spec 0) }}
{{- $env := dict (printf "%s_CERT" (index $spec 1)) (printf "%s/tls.crt" $dir) (printf "%s_KEY" (index $spec 1)) (printf "%s/tls.key" $dir) }}
{{- $out = append $out (dict "volume" (index $spec 0) "secret" $s.name "dir" $dir "env" $env) }}
{{- end }}
{{- end }}
{{- toYaml $out }}
{{- end }}

{{/*
Mailpit variables as a YAML map: every .Values.config value as the string the
app reads, then the chart-owned variables (secret file paths, metrics listener).
*/}}
{{- define "mailpit.config" -}}
{{- $out := dict }}
{{- range $key, $value := .Values.config }}
{{- if kindIs "string" $value }}
{{- $_ := set $out $key $value }}
{{- else if kindIs "bool" $value }}
{{- $_ := set $out $key (toString $value) }}
{{- else }}
{{- $_ := set $out $key (printf "%d" (int64 $value)) }}
{{- end }}
{{- end }}
{{- range fromYamlArray (include "mailpit.secretMounts" .) }}
{{- $out = merge .env $out }}
{{- end }}
{{- if include "mailpit.metrics" . }}
{{- $_ := set $out "MP_ENABLE_PROMETHEUS" ":9090" }}
{{- end }}
{{- toYaml $out }}
{{- end }}

{{/*
Settings the schema cannot express. Included by deployment.yaml, which is
always rendered.
*/}}
{{- define "mailpit.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.hosts is required when ingress.enabled is true" }}
{{- end }}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) }}
{{- fail "httpRoute.parentRefs is required when httpRoute.enabled is true" }}
{{- end }}
{{- if and .Values.secrets.pop3Tls.name (not .Values.secrets.pop3Auth.name) }}
{{- fail "secrets.pop3Tls requires secrets.pop3Auth: POP3 only runs with credentials" }}
{{- end }}
{{- if and .Values.secrets.smtpAuth.name (not .Values.secrets.smtpTls.name) (not (has (lower (toString .Values.config.MP_SMTP_AUTH_ALLOW_INSECURE)) (list "1" "true" "yes"))) }}
{{- fail "secrets.smtpAuth requires secrets.smtpTls, or config.MP_SMTP_AUTH_ALLOW_INSECURE: true (credentials sent in clear text)" }}
{{- end }}
{{- end }}

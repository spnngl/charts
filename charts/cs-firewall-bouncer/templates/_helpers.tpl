{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "cs-firewall-bouncer.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "cs-firewall-bouncer.fullname" -}}
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
{{- define "cs-firewall-bouncer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "cs-firewall-bouncer.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "cs-firewall-bouncer.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "cs-firewall-bouncer.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "cs-firewall-bouncer.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "cs-firewall-bouncer.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "cs-firewall-bouncer.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cs-firewall-bouncer.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. Tag empty: appVersion, pinned by the digest recorded in the
artifacthub.io/images annotation of Chart.yaml (only when image.repository is
the one the annotation names). Tag set: that tag, plus image.digest if given;
the chart digest never applies to a user-chosen tag.
*/}}
{{- define "cs-firewall-bouncer.image" -}}
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
{{- $ref := splitList "@" (first $images).image }}
{{- if and (eq (len $ref) 2) (hasPrefix (printf "%s:" $repo) (first $ref)) }}
{{- printf "%s:%s@%s" $repo .Chart.AppVersion (last $ref) }}
{{- else }}
{{- printf "%s:%s" $repo .Chart.AppVersion }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding the LAPI API key.
*/}}
{{- define "cs-firewall-bouncer.secretName" -}}
{{- default (include "cs-firewall-bouncer.fullname" .) .Values.lapi.existingSecret.name }}
{{- end }}

{{/*
Bouncer config merged over the image's, as .yaml.local: chart-owned keys win
over .Values.config. The image config already reads api_url / api_key from
the API_URL / API_KEY env and logs to stdout. Metrics stay on loopback unless
a PodMonitor needs to reach them: then they listen on the node IP.
*/}}
{{- define "cs-firewall-bouncer.config" -}}
{{- $addr := ternary "${HOST_IP}" "127.0.0.1" .Values.metrics.podMonitor.enabled }}
{{- $owned := dict "prometheus" (dict "enabled" true "listen_addr" $addr "listen_port" (toString (int .Values.metrics.port))) }}
{{- toYaml (merge $owned (deepCopy .Values.config)) }}
{{- end }}

{{/*
Probe from `.probe`; `.root` is the chart context. httpGet probes target
loopback unless the metrics listen on the node IP.
*/}}
{{- define "cs-firewall-bouncer.probe" -}}
{{- $probe := deepCopy .probe }}
{{- if and $probe.httpGet (not .root.Values.metrics.podMonitor.enabled) (not (hasKey $probe.httpGet "host")) }}
{{- $_ := set $probe.httpGet "host" "127.0.0.1" }}
{{- end }}
{{- toYaml $probe }}
{{- end }}

{{/*
Go memory limit: 90% of the container memory limit, in bytes. The Go runtime
only sees its own heap: it needs room under the limit for the rest (netlink
buffers, stacks). Integer quantities only (plain, Ki, Mi, Gi, Ti, k, M, G, T).
*/}}
{{- define "cs-firewall-bouncer.goMemLimit" -}}
{{- $q := ternary . (printf "%d" (int64 .)) (kindIs "string" .) }}
{{- $num := regexFind "^[0-9]+" $q }}
{{- $unit := trimPrefix $num $q }}
{{- $units := dict "" 1 "k" 1000 "M" 1000000 "G" 1000000000 "T" 1000000000000 "Ki" 1024 "Mi" 1048576 "Gi" 1073741824 "Ti" 1099511627776 }}
{{- if or (not $num) (not (hasKey $units $unit)) }}
{{- fail (printf "resources.limits.memory %q: use an integer quantity (plain, Ki, Mi, Gi, Ti, k, M, G, T) so the chart can derive GOMEMLIMIT" $q) }}
{{- end }}
{{- printf "%dB" (div (mul (mul (int64 $num) (int64 (get $units $unit))) 90) 100) }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "cs-firewall-bouncer.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins appVersion by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and (eq .Values.updateStrategy.type "RollingUpdate") (has (toString .Values.updateStrategy.rollingUpdate.maxUnavailable) (list "0" "0%")) }}
{{- fail "updateStrategy.rollingUpdate.maxUnavailable must not be 0: a DaemonSet cannot surge, so no node would ever be updated" }}
{{- end }}
{{- end }}

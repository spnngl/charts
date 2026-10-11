{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "nftables-exporter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "nftables-exporter.fullname" -}}
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
{{- define "nftables-exporter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "nftables-exporter.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "nftables-exporter.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "nftables-exporter.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "nftables-exporter.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "nftables-exporter.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "nftables-exporter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "nftables-exporter.fullname" .) .Values.serviceAccount.name }}
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
{{- define "nftables-exporter.image" -}}
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
Metrics listen address. Empty metrics.bindAddress: loopback, or every
interface when a PodMonitor scrapes the node IP (the exporter cannot read the
node IP from the environment).
*/}}
{{- define "nftables-exporter.bindAddress" -}}
{{- .Values.metrics.bindAddress | default (ternary "0.0.0.0" "127.0.0.1" .Values.metrics.podMonitor.enabled) }}
{{- end }}

{{/*
Exporter config file: .Values.config plus the chart-owned bind_to (the schema
rejects it in .Values.config).
*/}}
{{- define "nftables-exporter.config" -}}
{{- $owned := dict "nftables_exporter" (dict "bind_to" (printf "%s:%d" (include "nftables-exporter.bindAddress" .) (int .Values.metrics.port))) }}
{{- toYaml (merge $owned (deepCopy .Values.config)) }}
{{- end }}

{{/*
Probe from `.probe`; `.root` is the chart context. The kubelet probes the pod
IP (the node IP, host network): httpGet and tcpSocket probes target the
listen address unless it is every interface.
*/}}
{{- define "nftables-exporter.probe" -}}
{{- $probe := deepCopy .probe }}
{{- $addr := include "nftables-exporter.bindAddress" .root }}
{{- if ne $addr "0.0.0.0" }}
{{- range $handler := list "httpGet" "tcpSocket" }}
{{- $h := get $probe $handler }}
{{- if and $h (not (hasKey $h "host")) }}
{{- $_ := set $h "host" $addr }}
{{- end }}
{{- end }}
{{- end }}
{{- toYaml $probe }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "nftables-exporter.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins appVersion by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and (eq .Values.updateStrategy.type "RollingUpdate") (has (toString .Values.updateStrategy.rollingUpdate.maxUnavailable) (list "0" "0%")) }}
{{- fail "updateStrategy.rollingUpdate.maxUnavailable must not be 0: a DaemonSet cannot surge, so no node would ever be updated" }}
{{- end }}
{{- end }}

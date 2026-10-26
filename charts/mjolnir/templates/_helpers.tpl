{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "mjolnir.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "mjolnir.fullname" -}}
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
{{- define "mjolnir.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "mjolnir.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "mjolnir.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "mjolnir.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "mjolnir.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "mjolnir.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "mjolnir.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mjolnir.fullname" .) .Values.serviceAccount.name }}
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
{{- define "mjolnir.image" -}}
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
"true" when the web API is on (config.web.enabled): the Service port, the
container port and the NetworkPolicy rule follow it.
*/}}
{{- define "mjolnir.webEnabled" -}}
{{- if dig "web" "enabled" false .Values.config }}true{{ end }}
{{- end }}

{{/*
production.yaml: the chart-owned keys win over .Values.config, which wins over
the defaults (rawHomeserverUrl is homeserverUrl: upstream's default is
localhost, which would send the admin calls to the wrong host). The health endpoint is always on (the probes read it), the
metrics endpoint follows metrics.enabled, the web API listens on its own port
(the default collides with the health port).
*/}}
{{- define "mjolnir.config" -}}
{{- $owned := dict
  "dataPath" "/data/storage"
  "health" (dict
    "healthz" (dict "address" "0.0.0.0" "enabled" true "endpoint" "/healthz" "healthyStatus" 200 "port" 8080 "unhealthyStatus" 418)
    "openMetrics" (dict "address" "0.0.0.0" "enabled" .Values.metrics.enabled "endpoint" "/metrics" "port" 9090))
  "web" (dict "address" "0.0.0.0" "port" 8081) }}
{{- $defaults := dict }}
{{- with get .Values.config "homeserverUrl" }}{{ $_ := set $defaults "rawHomeserverUrl" . }}{{ end }}
{{- merge $owned (deepCopy .Values.config) $defaults | toYaml }}
{{- end }}

{{/*
Volume of persistence.data when it is not a volumeClaimTemplate, as a YAML list.
*/}}
{{- define "mjolnir.volume" -}}
{{- $p := .Values.persistence.data }}
{{- if eq $p.type "existingClaim" }}
- name: data
  persistentVolumeClaim:
    claimName: {{ $p.existingClaim.name }}
{{- else if eq $p.type "emptyDir" }}
- emptyDir:
    {{- with $p.emptyDir.sizeLimit }}
    sizeLimit: {{ . }}
    {{- end }}
  name: data
{{- end }}
{{- end }}

{{/*
Name of the metrics Service, which is also the `job` label a ServiceMonitor sets.
*/}}
{{- define "mjolnir.metricsServiceName" -}}
{{- printf "%s-metrics" (include "mjolnir.fullname" . | trunc 55 | trimSuffix "-") }}
{{- end }}

{{/*
Non-empty when the metrics Service is rendered.
*/}}
{{- define "mjolnir.metricsService" -}}
{{- if or .Values.metrics.service.enabled .Values.metrics.serviceMonitor.enabled }}true{{ end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "mjolnir.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- $p := .Values.persistence.data }}
{{- if and (eq $p.type "existingClaim") (not $p.existingClaim.name) }}
{{- fail "persistence.data.existingClaim.name is required when persistence.data.type is existingClaim" }}
{{- end }}
{{- if and (eq $p.type "emptyDir") (dig "encryption" "use" false .Values.config) }}
{{- fail "config.encryption.use requires persistent storage: with persistence.data.type emptyDir every restart logs in again and creates a new device" }}
{{- end }}
{{- end }}

{{/*
Egress rules: DNS, the internet peers, then extraEgress.
*/}}
{{- define "mjolnir.egress" -}}
{{- $e := .Values.networkPolicy.egress }}
- ports:
    - port: 53
      protocol: TCP
    - port: 53
      protocol: UDP
  {{- with $e.dns.to }}
  to:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- with $e.peers.to }}
- to:
    {{- toYaml . | nindent 4 }}
{{- else }}
- {}
{{- end }}
{{- with $e.extraEgress }}
{{ toYaml . }}
{{- end }}
{{- end }}

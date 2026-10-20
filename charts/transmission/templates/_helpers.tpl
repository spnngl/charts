{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "transmission.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "transmission.fullname" -}}
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
{{- define "transmission.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "transmission.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "transmission.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "transmission.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "transmission.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "transmission.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "transmission.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "transmission.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference of "image" (a values map: transmission's or the exporter's),
"ctx" being the root context. Tag empty: the entry of the artifacthub.io/images
annotation of Chart.yaml whose repository is image.repository (tag and digest
as recorded there). Tag set: that tag, plus image.digest if given; the chart
digest never applies to a user-chosen tag.
*/}}
{{- define "transmission.image" -}}
{{- $repo := .image.repository }}
{{- if .image.tag }}
{{- if .image.digest }}
{{- printf "%s:%s@%s" $repo .image.tag .image.digest }}
{{- else }}
{{- printf "%s:%s" $repo .image.tag }}
{{- end }}
{{- else }}
{{- $images := fromYamlArray (index .ctx.Chart.Annotations "artifacthub.io/images" | default "") }}
{{- if not $images }}
{{- fail "Chart.yaml: annotation artifacthub.io/images is missing, it holds the pinned image digests" }}
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
Name of the Secret holding the RPC login.
*/}}
{{- define "transmission.secretName" -}}
{{- default (include "transmission.fullname" .) .Values.auth.existingSecret.name }}
{{- end }}

{{/*
settings.json: chart-owned keys win over .Values.config.
*/}}
{{- define "transmission.settings" -}}
{{- $owned := dict "peer_port" (int .Values.peer.port) "peer_port_random_on_start" false "rpc_authentication_required" .Values.auth.enabled "rpc_enabled" true "rpc_port" 9091 "rpc_url" "/transmission/" "watch_dir_enabled" .Values.persistence.watch.enabled }}
{{- if .Values.persistence.watch.enabled }}
{{- $_ := set $owned "watch_dir" "/watch" }}
{{- end }}
{{- toPrettyJson (merge $owned (deepCopy .Values.config)) }}
{{- end }}

{{/*
Volumes that are not volumeClaimTemplates, as a YAML list. "name" and "p" (the
persistence entry) are passed in a dict.
*/}}
{{- define "transmission.volume" -}}
{{- $p := .p }}
{{- if eq $p.type "existingClaim" }}
- name: {{ .name }}
  persistentVolumeClaim:
    claimName: {{ $p.existingClaim.name }}
{{- else if eq $p.type "hostPath" }}
- hostPath:
    path: {{ $p.hostPath.path }}
    type: {{ $p.hostPath.type }}
  name: {{ .name }}
{{- else if eq $p.type "emptyDir" }}
- emptyDir:
    {{- with $p.emptyDir.sizeLimit }}
    sizeLimit: {{ . }}
    {{- end }}
  name: {{ .name }}
{{- end }}
{{- end }}

{{/*
Persistent volumes in mount order, as a YAML list of {name, path, p}.
*/}}
{{- define "transmission.persistence" -}}
{{- $list := list (dict "name" "config" "path" "/config" "p" .Values.persistence.config) (dict "name" "downloads" "path" "/downloads" "p" .Values.persistence.downloads) }}
{{- if .Values.persistence.watch.enabled }}
{{- $list = append $list (dict "name" "watch" "path" "/watch" "p" .Values.persistence.watch) }}
{{- end }}
{{- toYaml $list }}
{{- end }}

{{/*
True (non-empty) when the peer Service is rendered.
*/}}
{{- define "transmission.peerService" -}}
{{- if or .Values.peer.service.enabled .Values.peer.tcpRoute.enabled .Values.peer.udpRoute.enabled }}true{{ end }}
{{- end }}

{{/*
True (non-empty) when the metrics Service is rendered.
*/}}
{{- define "transmission.metricsService" -}}
{{- if or .Values.metrics.service.enabled .Values.metrics.serviceMonitor.enabled }}true{{ end }}
{{- end }}

{{/*
True (non-empty) when a persistence entry is a hostPath.
*/}}
{{- define "transmission.hasHostPath" -}}
{{- $p := .Values.persistence }}
{{- if or (eq $p.config.type "hostPath") (eq $p.downloads.type "hostPath") (and $p.watch.enabled (eq $p.watch.type "hostPath")) }}true{{ end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "transmission.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and .Values.metrics.image.digest (not .Values.metrics.image.tag) }}
{{- fail "metrics.image.digest requires metrics.image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- range $name, $p := dict "config" .Values.persistence.config "downloads" .Values.persistence.downloads "watch" .Values.persistence.watch }}
{{- if or (ne $name "watch") $p.enabled }}
{{- if and (eq $p.type "existingClaim") (not $p.existingClaim.name) }}
{{- fail (printf "persistence.%s.existingClaim.name is required when persistence.%s.type is existingClaim" $name $name) }}
{{- end }}
{{- if and (eq $p.type "hostPath") (not (hasPrefix "/" $p.hostPath.path)) }}
{{- fail (printf "persistence.%s.hostPath.path must be an absolute path when persistence.%s.type is hostPath" $name $name) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.hosts is required when ingress.enabled is true" }}
{{- end }}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) }}
{{- fail "httpRoute.parentRefs is required when httpRoute.enabled is true" }}
{{- end }}
{{- if and .Values.peer.tcpRoute.enabled (not .Values.peer.tcpRoute.parentRefs) }}
{{- fail "peer.tcpRoute.parentRefs is required when peer.tcpRoute.enabled is true" }}
{{- end }}
{{- if and .Values.peer.udpRoute.enabled (not .Values.peer.udpRoute.parentRefs) }}
{{- fail "peer.udpRoute.parentRefs is required when peer.udpRoute.enabled is true" }}
{{- end }}
{{- if and .Values.peer.service.enabled (eq .Values.peer.service.type "NodePort") (or (lt (int .Values.peer.port) 30000) (gt (int .Values.peer.port) 32767)) }}
{{- fail "peer.port must be within 30000-32767 when peer.service.type is NodePort: the daemon announces the port, so the node port is the same number" }}
{{- end }}
{{- if and .Values.peer.hostPort .Values.peer.service.enabled (eq .Values.peer.service.type "NodePort") }}
{{- fail "peer.hostPort and a NodePort peer Service would publish the same port twice: use one" }}
{{- end }}
{{- if and (or .Values.peer.tcpRoute.enabled .Values.peer.udpRoute.enabled) .Values.peer.service.enabled (ne .Values.peer.service.type "ClusterIP") }}
{{- fail "peer.tcpRoute / peer.udpRoute route to a ClusterIP peer Service: peer.service.type must stay ClusterIP, or the peers are exposed twice" }}
{{- end }}
{{- if and .Values.metrics.serviceMonitor.enabled .Values.metrics.podMonitor.enabled }}
{{- fail "metrics.serviceMonitor and metrics.podMonitor are exclusive: both would scrape the exporter twice" }}
{{- end }}
{{- if and (or .Values.metrics.serviceMonitor.enabled .Values.metrics.podMonitor.enabled .Values.metrics.service.enabled .Values.metrics.prometheusRule.enabled) (not .Values.metrics.enabled) }}
{{- fail "metrics.service, metrics.serviceMonitor, metrics.podMonitor and metrics.prometheusRule need metrics.enabled" }}
{{- end }}
{{- if and .Values.metrics.prometheusRule.enabled (not (or .Values.metrics.serviceMonitor.enabled .Values.metrics.podMonitor.enabled)) }}
{{- fail "metrics.prometheusRule needs metrics.serviceMonitor or metrics.podMonitor: the alerts select the job label it sets" }}
{{- end }}
{{- end }}

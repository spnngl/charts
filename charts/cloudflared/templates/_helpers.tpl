{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "cloudflared.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "cloudflared.fullname" -}}
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
{{- define "cloudflared.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "cloudflared.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "cloudflared.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "cloudflared.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "cloudflared.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "cloudflared.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "cloudflared.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cloudflared.fullname" .) .Values.serviceAccount.name }}
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
{{- define "cloudflared.image" -}}
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
Name of the Secret holding the tunnel token / credentials.
*/}}
{{- define "cloudflared.secretName" -}}
{{- $s := ternary .Values.tunnel.token.existingSecret .Values.tunnel.credentials.existingSecret (eq .Values.tunnel.mode "token") }}
{{- default (include "cloudflared.fullname" .) $s.name }}
{{- end }}

{{/*
Secret key and file name of the tunnel token / credentials.
*/}}
{{- define "cloudflared.secretKey" -}}
{{- ternary .Values.tunnel.token.existingSecret.key .Values.tunnel.credentials.existingSecret.key (eq .Values.tunnel.mode "token") }}
{{- end }}

{{/*
cloudflared config.yaml: chart-owned keys win over .Values.config.
*/}}
{{- define "cloudflared.config" -}}
{{- $owned := dict "grace-period" (printf "%ds" (int .Values.gracePeriodSeconds)) "metrics" (printf "0.0.0.0:%d" (int .Values.metrics.service.port)) }}
{{- $file := printf "/etc/cloudflared/credentials/%s" (include "cloudflared.secretKey" .) }}
{{- if eq .Values.tunnel.mode "token" }}
{{- $_ := set $owned "token-file" $file }}
{{- else }}
{{- $_ := set $owned "credentials-file" $file }}
{{- $_ := set $owned "ingress" .Values.tunnel.credentials.ingress }}
{{- $_ := set $owned "tunnel" .Values.tunnel.credentials.tunnel }}
{{- end }}
{{- toYaml (merge $owned (deepCopy .Values.config)) }}
{{- end }}

{{/*
Affinity: the chart default (preferred spread over hosts) unless overridden.
*/}}
{{- define "cloudflared.affinity" -}}
{{- if .Values.affinity }}
{{- toYaml .Values.affinity }}
{{- else }}
{{- $term := dict "labelSelector" (dict "matchLabels" (include "cloudflared.selectorLabels" . | fromYaml)) "topologyKey" "kubernetes.io/hostname" }}
{{- toYaml (dict "podAntiAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "podAffinityTerm" $term "weight" 100)))) }}
{{- end }}
{{- end }}

{{/*
Topology spread constraints: the chart default (preferred spread over zones)
unless overridden.
*/}}
{{- define "cloudflared.topologySpreadConstraints" -}}
{{- if .Values.topologySpreadConstraints }}
{{- toYaml .Values.topologySpreadConstraints }}
{{- else }}
{{- toYaml (list (dict "labelSelector" (dict "matchLabels" (include "cloudflared.selectorLabels" . | fromYaml)) "matchLabelKeys" (list "pod-template-hash") "maxSkew" 1 "topologyKey" "topology.kubernetes.io/zone" "whenUnsatisfiable" "ScheduleAnyway")) }}
{{- end }}
{{- end }}

{{/*
True (non-empty) when the metrics Service is rendered.
*/}}
{{- define "cloudflared.metricsService" -}}
{{- if or .Values.metrics.service.enabled .Values.metrics.serviceMonitor.enabled }}true{{ end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "cloudflared.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins appVersion by the digest recorded in Chart.yaml" }}
{{- end }}
{{- $maxReplicas := ternary (int .Values.autoscaling.maxReplicas) (int .Values.replicaCount) .Values.autoscaling.enabled }}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) }}
{{- fail "autoscaling.minReplicas must be <= autoscaling.maxReplicas" }}
{{- end }}
{{- /* A rollout runs replicas + surge connectors; Cloudflare allows 25 per tunnel. */}}
{{- $surge := 0 }}
{{- if eq .Values.strategy.type "RollingUpdate" }}
{{- $s := .Values.strategy.rollingUpdate.maxSurge }}
{{- if kindIs "string" $s }}
{{- $surge = int (ceil (divf (mulf (float64 $maxReplicas) (float64 (int (trimSuffix "%" $s)))) 100.0)) }}
{{- else }}
{{- $surge = int $s }}
{{- end }}
{{- end }}
{{- if gt (add $maxReplicas $surge) 25 }}
{{- fail (printf "a rollout would run %d connectors (%d replicas + %d surge), Cloudflare allows 25 per tunnel: lower the replicas or strategy.rollingUpdate.maxSurge" (add $maxReplicas $surge) $maxReplicas $surge) }}
{{- end }}
{{- if .Values.autoscaling.enabled }}
{{- range .Values.autoscaling.metrics }}
{{- if eq .type "Resource" }}
{{- $res := .resource.name }}
{{- if not (dig "requests" $res "" $.Values.resources) }}
{{- fail (printf "autoscaling: a %s Resource metric needs resources.requests.%s" $res $res) }}
{{- end }}
{{- if and $.Values.verticalPodAutoscaler.enabled (ne $.Values.verticalPodAutoscaler.updateMode "Off") (has $res $.Values.verticalPodAutoscaler.controlledResources) }}
{{- fail (printf "HPA and VPA must not act on the same resource metric (%s): set verticalPodAutoscaler.updateMode to Off or drop %s from controlledResources" $res $res) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

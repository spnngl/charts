{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "cinny.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "cinny.fullname" -}}
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
{{- define "cinny.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "cinny.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "cinny.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "cinny.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "cinny.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "cinny.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "cinny.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cinny.fullname" .) .Values.serviceAccount.name }}
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
{{- define "cinny.image" -}}
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
Affinity: the user's, merged over a preferred pod anti-affinity on the
hostname (a user podAntiAffinity replaces it).
*/}}
{{- define "cinny.affinity" -}}
{{- $selector := include "cinny.selectorLabels" . | fromYaml }}
{{- $term := dict "labelSelector" (dict "matchLabels" $selector) "topologyKey" "kubernetes.io/hostname" }}
{{- $antiAffinity := dict "podAntiAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "podAffinityTerm" $term "weight" 100))) }}
{{- toYaml (merge (deepCopy .Values.affinity) $antiAffinity) }}
{{- end }}

{{/*
Topology spread: the user's list, or one zone constraint.
*/}}
{{- define "cinny.topologySpreadConstraints" -}}
{{- $selector := include "cinny.selectorLabels" . | fromYaml }}
{{- $zone := dict "labelSelector" (dict "matchLabels" $selector) "maxSkew" 1 "topologyKey" "topology.kubernetes.io/zone" "whenUnsatisfiable" "ScheduleAnyway" }}
{{- toYaml (.Values.topologySpreadConstraints | default (list $zone)) }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "cinny.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.hosts is required when ingress.enabled is true" }}
{{- end }}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) }}
{{- fail "httpRoute.parentRefs is required when httpRoute.enabled is true" }}
{{- end }}
{{- if .Values.autoscaling.enabled }}
{{- if gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas) }}
{{- fail "autoscaling.minReplicas must be <= autoscaling.maxReplicas" }}
{{- end }}
{{- range .Values.autoscaling.metrics }}
{{- if eq .type "Resource" }}
{{- $res := dig "resource" "name" "" . }}
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

{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "artifacthub-exporter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "artifacthub-exporter.fullname" -}}
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
{{- define "artifacthub-exporter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "artifacthub-exporter.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "artifacthub-exporter.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "artifacthub-exporter.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "artifacthub-exporter.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "artifacthub-exporter.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "artifacthub-exporter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "artifacthub-exporter.fullname" .) .Values.serviceAccount.name }}
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
{{- define "artifacthub-exporter.image" -}}
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
Name of the metrics Service, which is also the `job` label a ServiceMonitor sets.
*/}}
{{- define "artifacthub-exporter.metricsServiceName" -}}
{{- printf "%s-metrics" (include "artifacthub-exporter.fullname" . | trunc 55 | trimSuffix "-") }}
{{- end }}

{{/*
Non-empty when the metrics Service is rendered.
*/}}
{{- define "artifacthub-exporter.metricsService" -}}
{{- if or .Values.metrics.service.enabled .Values.metrics.serviceMonitor.enabled }}true{{ end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by deployment.yaml, which is
always rendered.
*/}}
{{- define "artifacthub-exporter.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins appVersion by the digest recorded in Chart.yaml" }}
{{- end }}
{{- $a := .Values.artifacthub }}
{{- if not (or $a.orgs $a.users $a.repositories $a.packages (eq (include "artifacthub-exporter.hubStats" .) "true")) }}
{{- fail "artifacthub has no target: the exporter exits at startup without something to collect. Set artifacthub.orgs, users, repositories or packages, or leave artifacthub.hubStats empty" }}
{{- end }}
{{- end }}

{{/*
Whether to collect the hub totals, "true" or "false": artifacthub.hubStats,
or when empty, whether no other target is set.
*/}}
{{- define "artifacthub-exporter.hubStats" -}}
{{- $a := .Values.artifacthub }}
{{- if kindIs "bool" $a.hubStats }}{{ $a.hubStats }}{{ else }}{{ not (or $a.orgs $a.users $a.repositories $a.packages) }}{{ end }}
{{- end }}

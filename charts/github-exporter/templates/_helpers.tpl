{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "github-exporter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "github-exporter.fullname" -}}
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
{{- define "github-exporter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "github-exporter.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "github-exporter.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "github-exporter.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "github-exporter.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "github-exporter.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "github-exporter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "github-exporter.fullname" .) .Values.serviceAccount.name }}
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
{{- define "github-exporter.image" -}}
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
Name of the Secret holding the GitHub token.
*/}}
{{- define "github-exporter.secretName" -}}
{{- default (include "github-exporter.fullname" .) .Values.github.existingSecret.name }}
{{- end }}

{{/*
Name of the metrics Service, which is also the `job` label a ServiceMonitor sets.
*/}}
{{- define "github-exporter.metricsServiceName" -}}
{{- printf "%s-metrics" (include "github-exporter.fullname" . | trunc 55 | trimSuffix "-") }}
{{- end }}

{{/*
Non-empty when the metrics Service is rendered.
*/}}
{{- define "github-exporter.metricsService" -}}
{{- if or .Values.metrics.service.enabled .Values.metrics.serviceMonitor.enabled }}true{{ end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by deployment.yaml, which is
always rendered.
*/}}
{{- define "github-exporter.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins appVersion by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and (not .Values.github.orgs) (not .Values.github.repos) }}
{{- fail "github.orgs and github.repos are both empty: the exporter exits at startup without something to export. Set github.orgs and/or github.repos (`repos: [\"*\"]` exports every repository the token can see)" }}
{{- end }}
{{- end }}

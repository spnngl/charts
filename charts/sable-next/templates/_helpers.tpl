{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "sable-next.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "sable-next.fullname" -}}
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
{{- define "sable-next.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "sable-next.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "sable-next.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "sable-next.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "sable-next.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "sable-next.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "sable-next.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sable-next.fullname" .) .Values.serviceAccount.name }}
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
{{- define "sable-next.image" -}}
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
Settings the schema cannot express. Included by deployment.yaml, which is
always rendered.
*/}}
{{- define "sable-next.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.hosts is required when ingress.enabled is true" }}
{{- end }}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) }}
{{- fail "httpRoute.parentRefs is required when httpRoute.enabled is true" }}
{{- end }}
{{- end }}

{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "ignition-converter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "ignition-converter.fullname" -}}
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
{{- define "ignition-converter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "ignition-converter.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "ignition-converter.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "ignition-converter.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "ignition-converter.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "ignition-converter.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "ignition-converter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "ignition-converter.fullname" .) .Values.serviceAccount.name }}
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
{{- define "ignition-converter.image" -}}
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
Name of the serving certificate Secret: cert-manager's, or the user's.
*/}}
{{- define "ignition-converter.tlsSecretName" -}}
{{- if eq .Values.tls.mode "certManager" }}
{{- printf "%s-tls" (include "ignition-converter.fullname" .) }}
{{- else }}
{{- .Values.tls.existingSecret.name }}
{{- end }}
{{- end }}

{{/*
Affinity: the chart default (preferred spread over hosts) unless overridden.
*/}}
{{- define "ignition-converter.affinity" -}}
{{- if .Values.affinity }}
{{- toYaml .Values.affinity }}
{{- else }}
{{- $term := dict "labelSelector" (dict "matchLabels" (include "ignition-converter.selectorLabels" . | fromYaml)) "topologyKey" "kubernetes.io/hostname" }}
{{- toYaml (dict "podAntiAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "podAffinityTerm" $term "weight" 100)))) }}
{{- end }}
{{- end }}

{{/*
Topology spread constraints: the chart default (preferred spread over zones)
unless overridden.
*/}}
{{- define "ignition-converter.topologySpreadConstraints" -}}
{{- if .Values.topologySpreadConstraints }}
{{- toYaml .Values.topologySpreadConstraints }}
{{- else }}
{{- toYaml (list (dict "labelSelector" (dict "matchLabels" (include "ignition-converter.selectorLabels" . | fromYaml)) "matchLabelKeys" (list "pod-template-hash") "maxSkew" 1 "topologyKey" "topology.kubernetes.io/zone" "whenUnsatisfiable" "ScheduleAnyway")) }}
{{- end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by deployment.yaml, which is
always rendered.
*/}}
{{- define "ignition-converter.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins appVersion by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if dig "limits" "memory" "" .Values.resources }}
{{- range .Values.extraEnv }}
{{- if eq .name "GOMEMLIMIT" }}
{{- fail "extraEnv: GOMEMLIMIT is set by the chart from resources.limits.memory; drop the entry, or set resources.limits.memory to null to own it" }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

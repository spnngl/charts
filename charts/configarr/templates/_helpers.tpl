{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "configarr.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "configarr.fullname" -}}
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
{{- define "configarr.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "configarr.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "configarr.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "configarr.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "configarr.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "configarr.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "configarr.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "configarr.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. Tag empty: the entry of the artifacthub.io/images annotation of
Chart.yaml whose repository is image.repository (tag and digest as recorded
there). Tag set: that tag, plus image.digest if given; the chart digest never
applies to a user-chosen tag.
*/}}
{{- define "configarr.image" -}}
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
Kinds of object the container env reads from ("secret ", "configMap "), for
the kube-linter exemptions. Empty: env holds plain values only.
*/}}
{{- define "configarr.envRefs" -}}
{{- range .Values.extraEnv }}
{{- with .valueFrom }}
{{- if .secretKeyRef }}secret {{ end }}
{{- if .configMapKeyRef }}configMap {{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by cronjob.yaml, which is always
rendered.
*/}}
{{- define "configarr.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- /* Helm's parser keeps `!env X` as the string X: tagged values parse. */}}
{{- $config := fromYaml .Values.config }}
{{- if hasKey $config "Error" }}
{{- fail (printf "config must be a YAML mapping (Configarr's config.yml): %s" (get $config "Error")) }}
{{- end }}
{{- /* Without it every run fails with "Secret file not found.". */}}
{{- if and (regexMatch `!secret\s` .Values.config) (not .Values.secrets.existingSecret.name) }}
{{- fail "config uses !secret: set secrets.existingSecret.name to the Secret holding Configarr's secrets.yml" }}
{{- end }}
{{- /* Configarr reads env names case-sensitively: an exact match is enough. */}}
{{- $owned := list "CONFIG_LOCATION" "CUSTOM_REPO_ROOT" "ROOT_PATH" "SECRETS_LOCATION" "STOP_ON_ERROR" }}
{{- range .Values.extraEnv }}
{{- if has .name $owned }}
{{- fail (printf "extraEnv %s is set by the chart: the paths match the chart's volumes, and STOP_ON_ERROR=true makes a failed instance fail the Job" .name) }}
{{- end }}
{{- end }}
{{- end }}

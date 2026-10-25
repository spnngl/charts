{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "seerr.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "seerr.fullname" -}}
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
{{- define "seerr.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "seerr.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "seerr.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "seerr.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "seerr.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "seerr.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "seerr.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "seerr.fullname" .) .Values.serviceAccount.name }}
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
{{- define "seerr.image" -}}
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
{{- define "seerr.envRefs" -}}
{{- if or .Values.apiKey.existingSecret.name .Values.externalDatabase.enabled }}secret {{ end }}
{{- range .Values.extraEnv }}
{{- with .valueFrom }}
{{- if .secretKeyRef }}secret {{ end }}
{{- if .configMapKeyRef }}configMap {{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Volume of /app/config when it is not a volumeClaimTemplate, as a YAML list.
*/}}
{{- define "seerr.configVolume" -}}
{{- $p := .Values.persistence.config }}
{{- if eq $p.type "existingClaim" }}
- name: config
  persistentVolumeClaim:
    claimName: {{ $p.existingClaim.name }}
{{- else if eq $p.type "hostPath" }}
- hostPath:
    path: {{ $p.hostPath.path }}
    type: {{ $p.hostPath.type }}
  name: config
{{- else if eq $p.type "emptyDir" }}
- emptyDir:
    {{- with $p.emptyDir.sizeLimit }}
    sizeLimit: {{ . }}
    {{- end }}
  name: config
{{- end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by statefulset.yaml, which is
always rendered.
*/}}
{{- define "seerr.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- $p := .Values.persistence.config }}
{{- if and (eq $p.type "existingClaim") (not $p.existingClaim.name) }}
{{- fail "persistence.config.existingClaim.name is required when persistence.config.type is existingClaim" }}
{{- end }}
{{- if and (eq $p.type "hostPath") (not (hasPrefix "/" $p.hostPath.path)) }}
{{- fail "persistence.config.hostPath.path must be an absolute path when persistence.config.type is hostPath" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.hosts is required when ingress.enabled is true" }}
{{- end }}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) }}
{{- fail "httpRoute.parentRefs is required when httpRoute.enabled is true" }}
{{- end }}
{{- /* Seerr reads env names case-sensitively: an exact match is enough. */}}
{{- $owned := list "API_KEY" "CONFIG_DIRECTORY" "DB_HOST" "DB_NAME" "DB_PASS" "DB_PORT" "DB_SOCKET_PATH" "DB_TYPE" "DB_USER" "HOST" "PORT" }}
{{- range .Values.extraEnv }}
{{- if has .name $owned }}
{{- fail (printf "extraEnv %s is set by the chart: use apiKey.existingSecret or externalDatabase; the port, bind address and config directory match the Service and volumes" .name) }}
{{- end }}
{{- end }}
{{- end }}

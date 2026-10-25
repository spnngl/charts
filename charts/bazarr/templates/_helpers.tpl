{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "bazarr.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "bazarr.fullname" -}}
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
{{- define "bazarr.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "bazarr.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "bazarr.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "bazarr.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "bazarr.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "bazarr.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "bazarr.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "bazarr.fullname" .) .Values.serviceAccount.name }}
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
{{- define "bazarr.image" -}}
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
URL base (config.general.base_url) as "/<base>", empty when unset. The chart
pins it by env and prefixes the probe, Ingress and HTTPRoute paths with it:
Bazarr serves its API and UI under it only, so a base changed in the UI alone
would fail the probes.
*/}}
{{- define "bazarr.urlPath" -}}
{{- with (dig "general" "base_url" "" .Values.config | toString | trim | trimAll "/") }}/{{ . }}{{ end }}
{{- end }}

{{/*
Kinds of object the container env reads from ("secret ", "configMap "), for
the kube-linter exemptions. Empty: env holds plain values only.
*/}}
{{- define "bazarr.envRefs" -}}
{{- if or .Values.apiKey.existingSecret.name .Values.externalDatabase.enabled }}secret {{ end }}
{{- range .Values.extraEnv }}
{{- with .valueFrom }}
{{- if .secretKeyRef }}secret {{ end }}
{{- if .configMapKeyRef }}configMap {{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Volume of /config when it is not a volumeClaimTemplate, as a YAML list.
*/}}
{{- define "bazarr.configVolume" -}}
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
Volume of /data, as a YAML list.
*/}}
{{- define "bazarr.dataVolume" -}}
{{- $p := .Values.persistence.data }}
{{- if eq $p.type "existingClaim" }}
- name: data
  persistentVolumeClaim:
    claimName: {{ $p.existingClaim.name }}
{{- else if eq $p.type "hostPath" }}
- hostPath:
    path: {{ $p.hostPath.path }}
    type: {{ $p.hostPath.type }}
  name: data
{{- else if eq $p.type "nfs" }}
- name: data
  nfs:
    path: {{ $p.nfs.path }}
    server: {{ $p.nfs.server }}
{{- else }}
- emptyDir:
    {{- with $p.emptyDir.sizeLimit }}
    sizeLimit: {{ . }}
    {{- end }}
  name: data
{{- end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by statefulset.yaml, which is
always rendered.
*/}}
{{- define "bazarr.validate" -}}
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
{{- $d := .Values.persistence.data }}
{{- if and (eq $d.type "existingClaim") (not $d.existingClaim.name) }}
{{- fail "persistence.data.existingClaim.name is required when persistence.data.type is existingClaim" }}
{{- end }}
{{- if and (eq $d.type "hostPath") (not (hasPrefix "/" $d.hostPath.path)) }}
{{- fail "persistence.data.hostPath.path must be an absolute path when persistence.data.type is hostPath" }}
{{- end }}
{{- if has (clean $d.mountPath) (list "/" "/config" "/tmp") }}
{{- fail "persistence.data.mountPath must not be /, /config or /tmp" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.hosts is required when ingress.enabled is true" }}
{{- end }}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) }}
{{- fail "httpRoute.parentRefs is required when httpRoute.enabled is true" }}
{{- end }}
{{- /* Bazarr reads POSTGRES_* before its postgresql settings. Dynaconf matches
  the DYNACONF_ prefix exactly and the key in any case; a section name alone
  (DYNACONF_AUTH) replaces the whole section. */}}
{{- $owned := list "BAZARR_API_KEY" "INCLUDES_FOR_DYNACONF" "POSTGRES_DATABASE" "POSTGRES_ENABLED" "POSTGRES_HOST" "POSTGRES_PASSWORD" "POSTGRES_PORT" "POSTGRES_USERNAME" }}
{{- $ownedKeys := list "auth" "auth__apikey" "general" "general__base_url" "general__ip" "postgresql" "postgresql__enabled" }}
{{- range .Values.extraEnv }}
{{- if or (has .name $owned) (and (hasPrefix "DYNACONF_" .name) (has (.name | trimPrefix "DYNACONF_" | lower) $ownedKeys)) }}
{{- fail (printf "extraEnv %s is set by the chart: use apiKey.existingSecret, externalDatabase or config (general.base_url); the port and bind address match the Service" .name) }}
{{- end }}
{{- end }}
{{- end }}

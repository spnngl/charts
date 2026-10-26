{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "sabnzbd.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "sabnzbd.fullname" -}}
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
{{- define "sabnzbd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "sabnzbd.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "sabnzbd.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "sabnzbd.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "sabnzbd.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "sabnzbd.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "sabnzbd.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sabnzbd.fullname" .) .Values.serviceAccount.name }}
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
{{- define "sabnzbd.image" -}}
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
Kinds of object extraEnv reads from ("secret ", "configMap "), for the
kube-linter exemptions. Empty: env holds plain values only.
*/}}
{{- define "sabnzbd.envRefs" -}}
{{- range .Values.extraEnv }}
{{- with .valueFrom }}
{{- if .secretKeyRef }}secret {{ end }}
{{- if .configMapKeyRef }}configMap {{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Mount of /config, as a YAML list, for the SABnzbd and the config init containers.
*/}}
{{- define "sabnzbd.configMount" -}}
{{- $p := .Values.persistence.config }}
- mountPath: /config
  name: config
  {{- if and (eq $p.type "existingClaim") $p.existingClaim.subPath }}
  subPath: {{ $p.existingClaim.subPath }}
  {{- end }}
{{- end }}

{{/*
Volume of /config when it is not a volumeClaimTemplate, as a YAML list.
*/}}
{{- define "sabnzbd.configVolume" -}}
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
{{- define "sabnzbd.dataVolume" -}}
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
{{- define "sabnzbd.validate" -}}
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
{{- end }}

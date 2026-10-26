{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "fluffychat.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "fluffychat.fullname" -}}
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
{{- define "fluffychat.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "fluffychat.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "fluffychat.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "fluffychat.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "fluffychat.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "fluffychat.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "fluffychat.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fluffychat.fullname" .) .Values.serviceAccount.name }}
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
{{- define "fluffychat.image" -}}
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
TOML key: bare when it can be, quoted otherwise.
*/}}
{{- define "fluffychat.tomlKey" -}}
{{- if regexMatch "^[A-Za-z0-9_-]+$" . }}{{ . }}{{ else }}{{ . | toJson }}{{ end }}
{{- end }}

{{/*
TOML value, inline. Written here because toToml renders every number read from
a values file as a float (5 becomes 5e+00), which static-web-server rejects for
integer options. Strings go through toJson: a JSON string is a TOML basic string.
*/}}
{{- define "fluffychat.tomlValue" -}}
{{- if kindIs "map" . }}
{{- $items := list }}
{{- range $k := keys . | sortAlpha }}
{{- $v := get $ $k }}
{{- if not (kindIs "invalid" $v) }}
{{- $items = append $items (printf "%s = %s" (include "fluffychat.tomlKey" $k) (include "fluffychat.tomlValue" $v)) }}
{{- end }}
{{- end }}
{{- printf "{ %s }" (join ", " $items) }}
{{- else if kindIs "slice" . }}
{{- $items := list }}
{{- range $v := . }}
{{- $items = append $items (include "fluffychat.tomlValue" $v) }}
{{- end }}
{{- printf "[%s]" (join ", " $items) }}
{{- else if kindIs "string" . }}
{{- . | toJson }}
{{- else if kindIs "bool" . }}
{{- printf "%t" . }}
{{- else if kindIs "float64" . }}
{{- if eq (floor .) . }}{{ printf "%d" (int64 .) }}{{ else }}{{ printf "%v" . }}{{ end }}
{{- else }}
{{- printf "%d" . }}
{{- end }}
{{- end }}

{{/*
sws.toml: [general] is server.general under the chart-owned keys (the schema
rejects them in values; merge keeps the owned ones regardless), [advanced] is
server.advanced. Keys sorted. The file beats the image's SERVER_* variables and
the command line, so nothing set elsewhere can move the owned keys.
*/}}
{{- define "fluffychat.swsToml" -}}
{{- $general := merge (dict "health" true "host" "::" "metrics" .Values.metrics.enabled "port" 8080 "root" "/app") (deepCopy .Values.server.general) -}}
[general]
{{- range $k := keys $general | sortAlpha }}
{{- $v := get $general $k }}
{{- if not (kindIs "invalid" $v) }}
{{ include "fluffychat.tomlKey" $k }} = {{ include "fluffychat.tomlValue" $v }}
{{- end }}
{{- end }}
{{- with .Values.server.advanced }}
{{- $advanced := . }}

[advanced]
{{- range $k := keys $advanced | sortAlpha }}
{{- $v := get $advanced $k }}
{{- if not (kindIs "invalid" $v) }}
{{ include "fluffychat.tomlKey" $k }} = {{ include "fluffychat.tomlValue" $v }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "fluffychat.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.hosts is required when ingress.enabled is true" }}
{{- end }}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) }}
{{- fail "httpRoute.parentRefs is required when httpRoute.enabled is true" }}
{{- end }}
{{- $grace := index .Values.server.general "grace-period" | default 0 }}
{{- if le (int .Values.terminationGracePeriodSeconds) (int $grace) }}
{{- fail (printf "terminationGracePeriodSeconds (%v) must exceed server.general.grace-period (%v): the pod is killed before the server has drained" .Values.terminationGracePeriodSeconds $grace) }}
{{- end }}
{{- end }}

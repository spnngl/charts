{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "tuwunel.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "tuwunel.fullname" -}}
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
{{- define "tuwunel.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels of a component. Immutable once released: never add a key.
Takes a dict: "ctx" (the root context) and "component" (homeserver, cinny, livekit or lk-jwt).
*/}}
{{- define "tuwunel.selectorLabels" -}}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/name: {{ include "tuwunel.name" .ctx }}
{{- end }}

{{/*
Common labels of a component (keys sorted). Takes the dict of tuwunel.selectorLabels.
*/}}
{{- define "tuwunel.labels" -}}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/name: {{ include "tuwunel.name" .ctx }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
helm.sh/chart: {{ include "tuwunel.chart" .ctx }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "tuwunel.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "tuwunel.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference of "image" (a values map), "ctx" being the root context. Tag
empty: the entry of the artifacthub.io/images annotation of Chart.yaml whose
repository is image.repository (tag and digest as recorded there). Tag set:
that tag, plus image.digest if given; the chart digest never applies to a
user-chosen tag.
*/}}
{{- define "tuwunel.image" -}}
{{- $repo := .image.repository }}
{{- if .image.tag }}
{{- if .image.digest }}
{{- printf "%s:%s@%s" $repo .image.tag .image.digest }}
{{- else }}
{{- printf "%s:%s" $repo .image.tag }}
{{- end }}
{{- else }}
{{- $images := fromYamlArray (index .ctx.Chart.Annotations "artifacthub.io/images" | default "") }}
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
TOML key: bare when it can be, quoted otherwise.
*/}}
{{- define "tuwunel.tomlKey" -}}
{{- if regexMatch "^[A-Za-z0-9_-]+$" . }}{{ . }}{{ else }}{{ . | toJson }}{{ end }}
{{- end }}

{{/*
TOML value, inline. Written here because toToml renders every number read from
a values file as a float (20000000 becomes 2e+07), which tuwunel rejects for
integer options. Strings go through toJson: a JSON string is a TOML basic string.
*/}}
{{- define "tuwunel.tomlValue" -}}
{{- if kindIs "map" . }}
{{- $items := list }}
{{- range $k := keys . | sortAlpha }}
{{- $v := get $ $k }}
{{- if not (kindIs "invalid" $v) }}
{{- $items = append $items (printf "%s = %s" (include "tuwunel.tomlKey" $k) (include "tuwunel.tomlValue" $v)) }}
{{- end }}
{{- end }}
{{- printf "{ %s }" (join ", " $items) }}
{{- else if kindIs "slice" . }}
{{- $items := list }}
{{- range $v := . }}
{{- $items = append $items (include "tuwunel.tomlValue" $v) }}
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
tuwunel.toml from a config map: the [global] table holds the scalars, then one
sub-table per map value (well_known, tls, ...), keys sorted.
*/}}
{{- define "tuwunel.toml" -}}
[global]
{{- range $k := keys . | sortAlpha }}
{{- $v := get $ $k }}
{{- if not (or (kindIs "map" $v) (kindIs "invalid" $v)) }}
{{ include "tuwunel.tomlKey" $k }} = {{ include "tuwunel.tomlValue" $v }}
{{- end }}
{{- end }}
{{- range $k := keys . | sortAlpha }}
{{- $v := get $ $k }}
{{- if kindIs "map" $v }}
{{ printf "\n[global.%s]" (include "tuwunel.tomlKey" $k) }}
{{- range $kk := keys $v | sortAlpha }}
{{- $vv := get $v $kk }}
{{- if not (kindIs "invalid" $vv) }}
{{ include "tuwunel.tomlKey" $kk }} = {{ include "tuwunel.tomlValue" $vv }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Host name of the first Ingress host (or HTTPRoute host name) when the
.well-known delegation is on, empty otherwise.
*/}}
{{- define "tuwunel.wellKnownHost" -}}
{{- if and .Values.ingress.enabled .Values.ingress.wellKnown }}
{{- first .Values.ingress.hosts }}
{{- else if and .Values.httpRoute.enabled .Values.httpRoute.wellKnown }}
{{- first .Values.httpRoute.hostnames }}
{{- end }}
{{- end }}

{{/*
tuwunel.toml content: chart-owned keys win over .Values.config, which wins
over the delegation defaults.
*/}}
{{- define "tuwunel.config" -}}
{{- $owned := dict "address" "0.0.0.0" "database_path" "/var/lib/tuwunel" "port" 8008 "server_name" .Values.serverName }}
{{- $defaults := dict }}
{{- with include "tuwunel.wellKnownHost" . }}
{{- $_ := set $defaults "well_known" (dict "client" (printf "https://%s" .) "server" (printf "%s:443" .)) }}
{{- end }}
{{- include "tuwunel.toml" (merge $owned (deepCopy .Values.config) $defaults) }}
{{- end }}

{{/*
Volume of persistence.data when it is not a volumeClaimTemplate, as a YAML list.
*/}}
{{- define "tuwunel.volume" -}}
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
{{- else if eq $p.type "emptyDir" }}
- emptyDir:
    {{- with $p.emptyDir.sizeLimit }}
    sizeLimit: {{ . }}
    {{- end }}
  name: data
{{- end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "tuwunel.validate" -}}
{{- if not .Values.serverName }}
{{- fail "serverName is required: the Matrix server name (for example example.com). It is permanent: changing it later orphans the database" }}
{{- end }}
{{- include "tuwunel.validateImage" (dict "key" "image" "image" .Values.image) }}
{{- $p := .Values.persistence.data }}
{{- if and (eq $p.type "existingClaim") (not $p.existingClaim.name) }}
{{- fail "persistence.data.existingClaim.name is required when persistence.data.type is existingClaim" }}
{{- end }}
{{- if and (eq $p.type "hostPath") (not (hasPrefix "/" $p.hostPath.path)) }}
{{- fail "persistence.data.hostPath.path must be an absolute path when persistence.data.type is hostPath" }}
{{- end }}
{{- include "tuwunel.validateExposure" (dict "key" "" "ingress" .Values.ingress "httpRoute" .Values.httpRoute) }}
{{- if and .Values.ingress.wellKnown (not (and .Values.ingress.enabled .Values.ingress.hosts)) }}
{{- fail "ingress.wellKnown needs ingress.enabled and ingress.hosts: the first host becomes well_known.client" }}
{{- end }}
{{- if and .Values.httpRoute.wellKnown (not (and .Values.httpRoute.enabled .Values.httpRoute.hostnames)) }}
{{- fail "httpRoute.wellKnown needs httpRoute.enabled and httpRoute.hostnames: the first host name becomes well_known.client" }}
{{- end }}
{{- with .Values.cinny }}
{{- if .enabled }}
{{- include "tuwunel.validateImage" (dict "key" "cinny.image" "image" .image) }}
{{- include "tuwunel.validateExposure" (dict "key" "cinny." "ingress" .ingress "httpRoute" .httpRoute) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
A digest needs a tag. Takes "key" (the values path, for the message) and "image".
*/}}
{{- define "tuwunel.validateImage" -}}
{{- if and .image.digest (not .image.tag) }}
{{- fail (printf "%s.digest requires %s.tag: without a tag the chart pins the image by the digest recorded in Chart.yaml" .key .key) }}
{{- end }}
{{- end }}

{{/*
Ingress needs hosts, HTTPRoute needs parentRefs. Takes "key" (the values path
prefix of the two, for the messages: "" or "cinny."), "ingress" and "httpRoute".
*/}}
{{- define "tuwunel.validateExposure" -}}
{{- if and .ingress.enabled (not .ingress.hosts) }}
{{- fail (printf "%singress.hosts is required when %singress.enabled is true" .key .key) }}
{{- end }}
{{- if and .httpRoute.enabled (not .httpRoute.parentRefs) }}
{{- fail (printf "%shttpRoute.parentRefs is required when %shttpRoute.enabled is true" .key .key) }}
{{- end }}
{{- end }}

{{/*
Egress rules shared by the components that reach out: DNS, the internet peers,
then extraEgress.
*/}}
{{- define "tuwunel.egress" -}}
{{- $e := .Values.networkPolicy.egress }}
- ports:
    - port: 53
      protocol: TCP
    - port: 53
      protocol: UDP
  {{- with $e.dns.to }}
  to:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- with $e.peers.to }}
- to:
    {{- toYaml . | nindent 4 }}
{{- else }}
- {}
{{- end }}
{{- with $e.extraEgress }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Cinny config.json: user values over the defaults (the homeserver of this chart,
no custom homeservers).
*/}}
{{- define "tuwunel.cinnyConfig" -}}
{{- $defaults := dict "allowCustomHomeservers" false "defaultHomeserver" 0 "homeserverList" (list .Values.serverName) }}
{{- merge (deepCopy .Values.cinny.config) $defaults | toPrettyJson }}
{{- end }}

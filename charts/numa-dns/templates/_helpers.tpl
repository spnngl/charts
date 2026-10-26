{{/*
Chart name, truncated to the 63 characters Kubernetes names allow.
*/}}
{{- define "numa-dns.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "numa-dns.fullname" -}}
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
{{- define "numa-dns.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels. Immutable once released: never add a key.
*/}}
{{- define "numa-dns.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "numa-dns.name" . }}
{{- end }}

{{/*
Common labels (keys sorted).
*/}}
{{- define "numa-dns.labels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/name: {{ include "numa-dns.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ include "numa-dns.chart" . }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "numa-dns.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "numa-dns.fullname" .) .Values.serviceAccount.name }}
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
{{- define "numa-dns.image" -}}
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
A TOML key: bare when it can be, else a quoted string.
*/}}
{{- define "numa-dns.tomlKey" -}}
{{- if regexMatch "^[A-Za-z0-9_-]+$" . }}{{ . }}{{ else }}{{ toJson . }}{{ end }}
{{- end }}

{{/*
One TOML value: strings and keys through toJson (a JSON string is a TOML
basic string), integral numbers as integers (Helm's toToml renders them as
floats, which numa's integer fields reject), lists as arrays, maps as inline
tables. Anything else fails.
*/}}
{{- define "numa-dns.tomlValue" -}}
{{- $v := . }}
{{- if kindIs "map" $v }}
{{- $items := list }}
{{- range $k := keys $v | sortAlpha }}
{{- $items = append $items (printf "%s = %s" (include "numa-dns.tomlKey" $k) (include "numa-dns.tomlValue" (get $v $k))) }}
{{- end }}
{{- if $items }}{{ printf "{ %s }" (join ", " $items) }}{{ else }}{{ "{}" }}{{ end }}
{{- else if kindIs "slice" $v }}
{{- $items := list }}
{{- range $v }}
{{- $items = append $items (include "numa-dns.tomlValue" .) }}
{{- end }}
{{- printf "[%s]" (join ", " $items) }}
{{- else if kindIs "string" $v }}
{{- toJson $v }}
{{- else if kindIs "bool" $v }}
{{- printf "%t" $v }}
{{- else if or (kindIs "float64" $v) (kindIs "int" $v) (kindIs "int64" $v) }}
{{- if eq (float64 $v) (floor (float64 $v)) }}{{ printf "%d" (int64 $v) }}{{ else }}{{ printf "%v" $v }}{{ end }}
{{- else }}
{{- fail (printf "config: unsupported value %v (%s): use strings, numbers, booleans, lists and maps" $v (kindOf $v)) }}
{{- end }}
{{- end }}

{{/*
A TOML document from a map: root keys that are not maps first, then one
[table] per map (TOML requires root keys before the first table), each key
sorted.
*/}}
{{- define "numa-dns.toml" -}}
{{- $root := . }}
{{- $lines := list }}
{{- range $k := keys $root | sortAlpha }}
{{- $v := get $root $k }}
{{- if not (kindIs "map" $v) }}
{{- $lines = append $lines (printf "%s = %s" (include "numa-dns.tomlKey" $k) (include "numa-dns.tomlValue" $v)) }}
{{- end }}
{{- end }}
{{- range $k := keys $root | sortAlpha }}
{{- $v := get $root $k }}
{{- if kindIs "map" $v }}
{{- $lines = append $lines (printf "\n[%s]" (include "numa-dns.tomlKey" $k)) }}
{{- range $kk := keys $v | sortAlpha }}
{{- $lines = append $lines (printf "%s = %s" (include "numa-dns.tomlKey" $kk) (include "numa-dns.tomlValue" (get $v $kk))) }}
{{- end }}
{{- end }}
{{- end }}
{{- join "\n" $lines | trim }}
{{- end }}

{{/*
numa.toml: chart-owned keys are set one by one onto a copy of .Values.config (sprig merge lets a user value replace an owned `false`). They bind the pod
ports (8053 DNS, 8080 plain proxy, 8443 DoH), keep the API on loopback, and
switch off the listeners the chart does not expose.
*/}}
{{- define "numa-dns.config" -}}
{{- $owned := dict
  "dot" (dict "enabled" false)
  "lan" (dict "enabled" false)
  "mobile" (dict "enabled" false)
  "proxy" (dict "bind_addr" "0.0.0.0" "enabled" true "port" 8080 "tls_port" 8443)
  "server" (dict "api_bind_addr" "127.0.0.1" "bind_addr" (list "0.0.0.0:8053")) }}
{{- $cfg := deepCopy .Values.config }}
{{- range $table, $keys := $owned }}
{{- $t := get $cfg $table | default dict }}
{{- range $k, $v := $keys }}
{{- $_ := set $t $k $v }}
{{- end }}
{{- $_ := set $cfg $table $t }}
{{- end }}
{{- include "numa-dns.toml" $cfg }}
{{- end }}

{{/*
Affinity: the chart default (preferred spread over hosts) unless overridden.
*/}}
{{- define "numa-dns.affinity" -}}
{{- if .Values.affinity }}
{{- toYaml .Values.affinity }}
{{- else }}
{{- $term := dict "labelSelector" (dict "matchLabels" (include "numa-dns.selectorLabels" . | fromYaml)) "topologyKey" "kubernetes.io/hostname" }}
{{- toYaml (dict "podAntiAffinity" (dict "preferredDuringSchedulingIgnoredDuringExecution" (list (dict "podAffinityTerm" $term "weight" 100)))) }}
{{- end }}
{{- end }}

{{/*
Topology spread constraints: the chart default (preferred spread over zones)
unless overridden.
*/}}
{{- define "numa-dns.topologySpreadConstraints" -}}
{{- if .Values.topologySpreadConstraints }}
{{- toYaml .Values.topologySpreadConstraints }}
{{- else }}
{{- toYaml (list (dict "labelSelector" (dict "matchLabels" (include "numa-dns.selectorLabels" . | fromYaml)) "matchLabelKeys" (list "pod-template-hash") "maxSkew" 1 "topologyKey" "topology.kubernetes.io/zone" "whenUnsatisfiable" "ScheduleAnyway")) }}
{{- end }}
{{- end }}

{{/*
Settings the schema cannot express. Included by configmap.yaml, which is
always rendered.
*/}}
{{- define "numa-dns.validate" -}}
{{- if and .Values.image.digest (not .Values.image.tag) }}
{{- fail "image.digest requires image.tag: without a tag the chart pins appVersion by the digest recorded in Chart.yaml" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) }}
{{- fail "ingress.hosts is required when ingress.enabled is true" }}
{{- end }}
{{- $suffixes := list }}
{{- range .Values.extraIngresses }}
{{- if not .hosts }}
{{- fail (printf "extraIngresses[%s].hosts is required" .nameSuffix) }}
{{- end }}
{{- if has .nameSuffix $suffixes }}
{{- fail (printf "extraIngresses: nameSuffix %q is used twice, each must be unique" .nameSuffix) }}
{{- end }}
{{- $suffixes = append $suffixes .nameSuffix }}
{{- end }}
{{- if and .Values.autoscaling.enabled (gt (int .Values.autoscaling.minReplicas) (int .Values.autoscaling.maxReplicas)) }}
{{- fail "autoscaling.minReplicas must be <= autoscaling.maxReplicas" }}
{{- end }}
{{- if .Values.autoscaling.enabled }}
{{- range .Values.autoscaling.metrics }}
{{- $res := dig "resource" "name" "" . }}
{{- if and (eq .type "Resource") $res }}
{{- if not (dig "requests" $res "" $.Values.resources) }}
{{- fail (printf "autoscaling: a %s Resource metric needs resources.requests.%s" $res $res) }}
{{- end }}
{{- if and $.Values.verticalPodAutoscaler.enabled (ne $.Values.verticalPodAutoscaler.updateMode "Off") (has $res $.Values.verticalPodAutoscaler.controlledResources) }}
{{- fail (printf "HPA and VPA must not act on the same resource metric (%s): set verticalPodAutoscaler.updateMode to Off or drop %s from controlledResources" $res $res) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
NOTES line for one Ingress: the dig command that tests it.
*/}}
{{- define "numa-dns.notesIngress" -}}
{{- $host := first .ing.hosts }}
{{- if eq (default "doh" .ing.port) "doh" }}
{{ .name }}, DNS over HTTPS: kdig +https @{{ $host }} example.com
{{- else }}
{{ .name }}, DNS over TLS: kdig +tls @{{ $host }} example.com
{{- end }}
{{- end }}

{{/*
Chart name, truncated to the 63-character label limit.
*/}}
{{- define "cert-manager-crds.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart name and version as used by the helm.sh/chart label.
*/}}
{{- define "cert-manager-crds.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Standard labels applied to every CRD.
*/}}
{{- define "cert-manager-crds.labels" -}}
helm.sh/chart: {{ include "cert-manager-crds.chart" . }}
app.kubernetes.io/name: {{ include "cert-manager-crds.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Extra annotations applied to every CRD (.Values.annotations plus the keep policy), as YAML.
Renders "{}" when empty so callers can guard with `with ... | fromYaml`.
*/}}
{{- define "cert-manager-crds.crdAnnotations" -}}
{{- $a := dict -}}
{{- range $k, $v := (default (dict) .Values.annotations) }}{{- $_ := set $a $k $v }}{{- end -}}
{{- if .Values.keepOnUninstall }}{{- $_ := set $a "helm.sh/resource-policy" "keep" }}{{- end -}}
{{- toYaml $a -}}
{{- end }}

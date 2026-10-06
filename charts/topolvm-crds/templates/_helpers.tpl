{{/*
Chart name, truncated to the 63-character label limit.
*/}}
{{- define "topolvm-crds.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart name and version as used by the helm.sh/chart label.
*/}}
{{- define "topolvm-crds.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels applied to every CRD (standard labels, overridden by .Values.labels), as a JSON object.
*/}}
{{- define "topolvm-crds.crdLabels" -}}
{{- $l := dict -}}
{{- $_ := set $l "helm.sh/chart" (include "topolvm-crds.chart" .) -}}
{{- $_ := set $l "app.kubernetes.io/name" (include "topolvm-crds.name" .) -}}
{{- $_ := set $l "app.kubernetes.io/instance" .Release.Name -}}
{{- $_ := set $l "app.kubernetes.io/version" .Chart.AppVersion -}}
{{- $_ := set $l "app.kubernetes.io/managed-by" .Release.Service -}}
{{- range $k, $v := (default (dict) .Values.labels) }}{{- $_ := set $l $k $v }}{{- end -}}
{{- toJson $l -}}
{{- end }}

{{/*
Extra annotations applied to every CRD (.Values.annotations plus the keep policy), as a JSON object.
Renders "{}" when empty.
*/}}
{{- define "topolvm-crds.crdAnnotations" -}}
{{- $a := dict -}}
{{- range $k, $v := (default (dict) .Values.annotations) }}{{- $_ := set $a $k $v }}{{- end -}}
{{- if .Values.keepOnUninstall }}{{- $_ := set $a "helm.sh/resource-policy" "keep" }}{{- end -}}
{{- toJson $a -}}
{{- end }}

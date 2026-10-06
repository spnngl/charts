# Sanitized CRD record → Helm template text. The ONLY step that manipulates text.
#
# Output is JSON (valid YAML, so Helm and Kubernetes read it as usual),
# serialised with `to json --indent 0`: one token per line, no indentation.
# Helm stores every template base64-encoded inside the gzipped release, where
# YAML indentation compresses poorly; this shrinks the release Secret by ~25 %
# while keeping line-based diffs. Every structural brace sits on its own line,
# so `{{`/`}}` can only come from string content, which `template escape` handles.
#
# Strategy: put sentinel keys FIRST in the maps that get injected content,
# serialise, escape Go-template delimiters, then replace each sentinel line
# (`"<sentinel>": ""` plus a trailing comma when more members follow) with
# template directives emitting JSON members.

const LABELS_SENTINEL = "__CRDGEN_LABELS__"
const ANNOTATIONS_SENTINEL = "__CRDGEN_ANNOTATIONS__"
const ANNOTATIONS_BLOCK_SENTINEL = "__CRDGEN_ANNOTATIONS_BLOCK__"

# Make every run of braces containing `{{` or `}}` render literally by turning
# the whole run into a Go string literal action. Escaping whole runs (instead
# of each `{{`/`}}`) keeps a neighbouring single brace from merging with the
# generated delimiters, e.g. `{}}` must not become `{{{ "}}" }}`.
export def "template escape" [text: string]: nothing -> string {
  $text | str replace -ra '([{}]*(?:\{\{|\}\})[{}]*)' '{{ "${1}" }}'
}

# JSON members of an object rendered by `helper` (a JSON object), without braces.
def members [chart: string, helper: string]: nothing -> string {
  $'include "($chart).($helper)" . | trimPrefix "{" | trimSuffix "}"'
}

# Inside `labels`: injected labels are never empty.
def labels-block [chart: string, comma: string]: nothing -> string {
  $'{{ (members $chart "crdLabels") }}($comma)'
}

# Inside an existing `annotations` map; upstream members follow, hence the comma.
def annotations-inline-block [chart: string, comma: string]: nothing -> string {
  $'{{- with (members $chart "crdAnnotations") }}{{ . }}($comma){{- end }}'
}

# Whole `annotations` key in `metadata`, emitted only when there is something to put in it.
def annotations-key-block [chart: string, comma: string]: nothing -> string {
  $'{{- with include "($chart).crdAnnotations" . | fromJson }}"annotations": {{ toJson . }}($comma){{- end }}'
}

# Replace every line `"<sentinel>": ""[,]` with the block built for its trailing comma.
def replace-sentinel [text: string, sentinel: string, block: closure]: nothing -> string {
  $text
  | lines
  | each {|line|
      let m = ($line | parse --regex (['^"' $sentinel '": ""(,?)$'] | str join ''))
      if ($m | is-empty) { $line } else { do $block $m.0.capture0 }
    }
  | str join "\n"
}

export def "templatize crd" [crd: record, chart: string]: nothing -> string {
  let labels = ({$LABELS_SENTINEL: ""} | merge ($crd.metadata | get -o labels | default {}))
  let annotations = ($crd.metadata | get -o annotations | default {})
  let metadata = (
    if ($annotations | is-empty) {
      {$ANNOTATIONS_BLOCK_SENTINEL: ""} | merge ($crd.metadata | reject -o annotations)
    } else {
      $crd.metadata | upsert annotations ({$ANNOTATIONS_SENTINEL: ""} | merge $annotations)
    }
    | upsert labels $labels
  )
  template escape ($crd | upsert metadata $metadata | to json --indent 0)
  | replace-sentinel $in $LABELS_SENTINEL {|comma| labels-block $chart $comma }
  | replace-sentinel $in $ANNOTATIONS_SENTINEL {|comma| annotations-inline-block $chart $comma }
  | replace-sentinel $in $ANNOTATIONS_BLOCK_SENTINEL {|comma| annotations-key-block $chart $comma }
  | $"($in)\n"
}

# _helpers.tpl content for a chart.
export def "templatize helpers" [chart: string]: nothing -> string {
  let c = $chart
  [
    '{{/*'
    'Chart name, truncated to the 63-character label limit.'
    '*/}}'
    $'{{- define "($c).name" -}}'
    '{{- .Chart.Name | trunc 63 | trimSuffix "-" }}'
    '{{- end }}'
    ''
    '{{/*'
    'Chart name and version as used by the helm.sh/chart label.'
    '*/}}'
    $'{{- define "($c).chart" -}}'
    '{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}'
    '{{- end }}'
    ''
    '{{/*'
    'Labels applied to every CRD (standard labels, overridden by .Values.labels), as a JSON object.'
    '*/}}'
    $'{{- define "($c).crdLabels" -}}'
    '{{- $l := dict -}}'
    (['{{- $_ := set $l "helm.sh/chart" (include "' $c '.chart" .) -}}'] | str join '')
    (['{{- $_ := set $l "app.kubernetes.io/name" (include "' $c '.name" .) -}}'] | str join '')
    '{{- $_ := set $l "app.kubernetes.io/instance" .Release.Name -}}'
    '{{- $_ := set $l "app.kubernetes.io/version" .Chart.AppVersion -}}'
    '{{- $_ := set $l "app.kubernetes.io/managed-by" .Release.Service -}}'
    '{{- range $k, $v := (default (dict) .Values.labels) }}{{- $_ := set $l $k $v }}{{- end -}}'
    '{{- toJson $l -}}'
    '{{- end }}'
    ''
    '{{/*'
    'Extra annotations applied to every CRD (.Values.annotations plus the keep policy), as a JSON object.'
    'Renders "{}" when empty.'
    '*/}}'
    $'{{- define "($c).crdAnnotations" -}}'
    '{{- $a := dict -}}'
    '{{- range $k, $v := (default (dict) .Values.annotations) }}{{- $_ := set $a $k $v }}{{- end -}}'
    '{{- if .Values.keepOnUninstall }}{{- $_ := set $a "helm.sh/resource-policy" "keep" }}{{- end -}}'
    '{{- toJson $a -}}'
    '{{- end }}'
    ''
  ] | str join "\n"
}

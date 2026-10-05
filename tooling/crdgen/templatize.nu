# Sanitized CRD record → Helm template text. The ONLY step that manipulates text.
#
# Strategy: put sentinel keys into the record, serialise with `to yaml`, escape
# Go-template delimiters that upstream may have in descriptions, then replace
# the sentinel lines with template directives at the same indentation.

const LABELS_SENTINEL = "__CRDGEN_LABELS__"
const ANNOTATIONS_SENTINEL = "__CRDGEN_ANNOTATIONS__"
const ANNOTATIONS_BLOCK_SENTINEL = "__CRDGEN_ANNOTATIONS_BLOCK__"

# Escape `{{` and `}}` so Helm renders them literally.
export def "template escape" [text: string]: nothing -> string {
  $text
  | str replace -a '{{' "\u{1}"
  | str replace -a '}}' "\u{2}"
  | str replace -a "\u{1}" '{{ "{{" }}'
  | str replace -a "\u{2}" '{{ "}}" }}'
}

def labels-block [chart: string, indent: int]: nothing -> string {
  [
    $'{{- include "($chart).labels" . | nindent ($indent) }}'
    '{{- with .Values.labels }}'
    $'{{- toYaml . | nindent ($indent) }}'
    '{{- end }}'
  ] | str join "\n"
}

# Inside an existing `annotations:` map.
def annotations-inline-block [chart: string, indent: int]: nothing -> string {
  [
    (['{{- with (include "' $chart '.crdAnnotations" . | fromYaml) }}'] | str join '')
    $'{{- toYaml . | nindent ($indent) }}'
    '{{- end }}'
  ] | str join "\n"
}

# Whole `annotations:` key, emitted only when there is something to put in it.
def annotations-key-block [chart: string, indent: int]: nothing -> string {
  let pad = ("" | fill -w $indent -c " ")
  [
    (['{{- with (include "' $chart '.crdAnnotations" . | fromYaml) }}'] | str join '')
    $'($pad)annotations:'
    $'($pad)  {{- toYaml . | nindent ($indent + 2) }}'
    '{{- end }}'
  ] | str join "\n"
}

# Replace every line `<spaces><sentinel>: ""` with the block built for that indentation.
def replace-sentinel [text: string, sentinel: string, block: closure]: nothing -> string {
  $text
  | lines
  | each {|line|
      let m = ($line | parse --regex (['^( *)' $sentinel ': ""$'] | str join ''))
      if ($m | is-empty) { $line } else { do $block ($m.0.capture0 | str length) }
    }
  | str join "\n"
}

export def "templatize crd" [crd: record, chart: string]: nothing -> string {
  let has_annotations = (($crd.metadata | get -o annotations | default {} | columns | length) > 0)
  let marked = (
    $crd
    | upsert ([metadata labels $LABELS_SENTINEL] | into cell-path) ""
    | if $has_annotations {
        $in | upsert ([metadata annotations $ANNOTATIONS_SENTINEL] | into cell-path) ""
      } else {
        $in | upsert ([metadata $ANNOTATIONS_BLOCK_SENTINEL] | into cell-path) ""
      }
  )
  let yaml = (template escape ($marked | to yaml))
  let out = (
    $yaml
    | replace-sentinel $in $LABELS_SENTINEL {|indent| labels-block $chart $indent }
    | replace-sentinel $in $ANNOTATIONS_SENTINEL {|indent| annotations-inline-block $chart $indent }
    | replace-sentinel $in $ANNOTATIONS_BLOCK_SENTINEL {|indent| annotations-key-block $chart $indent }
  )
  $out | str trim --right | $"($in)\n"
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
    'Standard labels applied to every CRD.'
    '*/}}'
    $'{{- define "($c).labels" -}}'
    $'helm.sh/chart: {{ include "($c).chart" . }}'
    $'app.kubernetes.io/name: {{ include "($c).name" . }}'
    'app.kubernetes.io/instance: {{ .Release.Name }}'
    'app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}'
    'app.kubernetes.io/managed-by: {{ .Release.Service }}'
    '{{- end }}'
    ''
    '{{/*'
    'Extra annotations applied to every CRD (.Values.annotations plus the keep policy), as YAML.'
    'Renders "{}" when empty so callers can guard with `with ... | fromYaml`.'
    '*/}}'
    $'{{- define "($c).crdAnnotations" -}}'
    '{{- $a := dict -}}'
    '{{- range $k, $v := (default (dict) .Values.annotations) }}{{- $_ := set $a $k $v }}{{- end -}}'
    '{{- if .Values.keepOnUninstall }}{{- $_ := set $a "helm.sh/resource-policy" "keep" }}{{- end -}}'
    '{{- toYaml $a -}}'
    '{{- end }}'
    ''
  ] | str join "\n"
}

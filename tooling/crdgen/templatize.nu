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

# Helm template text (JSON) for one sanitized CRD, with the label and annotation injection blocks.
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

# static/_helpers.tpl (piped in) for a chart: fills the `<chart>` placeholder.
export def "templatize helpers" [chart: string]: string -> string {
  $in | str replace -a "<chart>" $chart
}

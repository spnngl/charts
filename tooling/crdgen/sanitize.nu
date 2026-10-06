# Strip build noise and upstream Helm-isms from a CRD; apply manifest patches.
# Pure record → record. Everything not listed here is kept verbatim.

use config.nu [INJECTED_LABEL_PATTERNS INJECTED_ANNOTATION_PATTERNS]

const SERVER_SIDE_FIELDS = [
  $.status
  $.metadata.creationTimestamp
  $.metadata.namespace
  $.metadata.resourceVersion
  $.metadata.uid
  $.metadata.generation
  $.metadata.managedFields
  $.metadata.selfLink
]

# JSONSchemaProps keys that only document, never validate.
const DOC_KEYS = [description title example externalDocs]
# JSONSchemaProps keys holding sub-schemas, by shape. Everything else (`default`,
# `enum`, `example`, ...) is data and must not be walked: it may contain a
# `description` key of its own, as may `properties` (a field named description).
const SCHEMA_MAP_KEYS = [properties patternProperties definitions dependencies]
const SCHEMA_LIST_KEYS = [allOf anyOf oneOf]
const SCHEMA_KEYS = [items additionalProperties additionalItems not]

# Apply `f` to the value under `key`, if present. Keys are taken literally (no dot splitting).
def update-key [r: record, key: string, f: closure]: nothing -> record {
  let cp = ([$key] | into cell-path)
  let v = ($r | get -o $cp)
  if $v == null { $r } else { $r | upsert $cp (do $f $v) }
}

# Remove DOC_KEYS from a schema node and, recursively, from its sub-schemas.
# Non-record nodes (`additionalProperties: true`, string-list dependencies) pass through.
# `any`: a schema node is a record, or a bool/list in places (external data).
def "strip-docs schema" [s: any]: nothing -> any {
  if ($s | describe -d).type != record { return $s }
  let s = ($s | reject -o ...$DOC_KEYS)
  let s = ($SCHEMA_MAP_KEYS | reduce --fold $s {|k, acc|
    update-key $acc $k {|m|
      if ($m | describe -d).type != record { $m } else {
        $m | columns | reduce --fold $m {|name, m2| update-key $m2 $name {|sub| strip-docs schema $sub } }
      }
    }
  })
  let s = ($SCHEMA_LIST_KEYS | reduce --fold $s {|k, acc| update-key $acc $k {|l| $l | each {|sub| strip-docs schema $sub } } })
  $SCHEMA_KEYS | reduce --fold $s {|k, acc|
    update-key $acc $k {|v| if ($v | describe -d).type == list { $v | each {|sub| strip-docs schema $sub } } else { strip-docs schema $v } }
  }
}

# Strip schema and printer-column documentation from every version of a CRD.
# Each version's top-level description is kept: a sentence per kind, it feeds
# `kubectl explain <kind>`, the README and the Artifact Hub CRD list.
def "strip-docs crd" [crd: record]: nothing -> record {
  let strip_keep_root = {|s|
    let root_desc = ($s | get -o description)
    let stripped = (strip-docs schema $s)
    if $root_desc == null { $stripped } else { $stripped | insert description $root_desc }
  }
  $crd | update spec.versions {|c|
    $c.spec.versions | each {|v|
      let v = (update-key $v schema {|sch| update-key $sch openAPIV3Schema $strip_keep_root })
      update-key $v additionalPrinterColumns {|cols| $cols | each {|col| $col | reject -o description } }
    }
  }
}

# Remove record keys matching any pattern. Returns the record, or null when empty.
def prune-map [m: oneof<record, nothing>, patterns: list<string>]: nothing -> oneof<record, nothing> {
  if $m == null { return null }
  let kept = ($m | transpose key value | where {|r| not ($patterns | any {|p| $r.key =~ $p }) })
  if ($kept | is-empty) { null } else { $kept | transpose -rd }
}

# Set `metadata.<field>` to the pruned map, dropping the key when nothing is left.
def prune-metadata-map [crd: record, field: string, patterns: list<string>]: nothing -> record {
  let pruned = (prune-map ($crd.metadata | get -o $field) $patterns)
  if $pruned == null {
    $crd | reject -o ([metadata $field] | into cell-path)
  } else {
    $crd | upsert ([metadata $field] | into cell-path) $pruned
  }
}

# Remove the labels and annotations the chart template injects. A map left empty is dropped.
export def "sanitize strip-injected" [crd: record]: nothing -> record {
  let cleaned = (prune-metadata-map $crd "labels" $INJECTED_LABEL_PATTERNS)
  prune-metadata-map $cleaned "annotations" $INJECTED_ANNOTATION_PATTERNS
}

# JSON pointer ("/spec/versions/0/served") → cell-path.
def "pointer to-cell-path" [pointer: string]: nothing -> cell-path {
  $pointer
  | split row '/'
  | skip 1
  | each {|seg|
      let s = ($seg | str replace -a '~1' '/' | str replace -a '~0' '~')
      if ($s =~ '^\d+$') { $s | into int } else { $s }
    }
  | into cell-path
}

# Apply one JSON6902-style patch (add | replace | remove).
def "patch apply" [crd: record, patch: record]: nothing -> record {
  let cp = (pointer to-cell-path $patch.path)
  match $patch.op {
    "add" | "replace" => ($crd | upsert $cp $patch.value)
    "remove" => ($crd | reject $cp)
    _ => { error make {msg: $"unsupported patch op ($patch.op)"} }
  }
}

export def "sanitize crd" [crd: record, transform: record]: nothing -> record {
  let cleaned = (
    $crd
    | reject -o ...$SERVER_SIDE_FIELDS
  )
  let cleaned = (sanitize strip-injected $cleaned)
  # Before patches, so a patch may still add documentation on purpose.
  let cleaned = (if $transform.stripDocs { strip-docs crd $cleaned } else { $cleaned })
  $transform.patches | reduce --fold $cleaned {|p, acc| patch apply $acc $p }
}

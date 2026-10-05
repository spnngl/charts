# Strip build noise and upstream Helm-isms from a CRD; apply manifest patches.
# Pure record → record. Everything not listed here is kept verbatim.

use config.nu [INJECTED_LABEL_PATTERNS INJECTED_ANNOTATION_PATTERNS]

const SERVER_SIDE_FIELDS = [
  status
  metadata.creationTimestamp
  metadata.namespace
  metadata.resourceVersion
  metadata.uid
  metadata.generation
  metadata.managedFields
  metadata.selfLink
]

# Remove record keys matching any pattern. Returns the record, or null when empty.
def prune-map [m: any, patterns: list<string>]: nothing -> any {
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

# JSON pointer ("/spec/versions/0/served") → cell-path.
export def "pointer to-cell-path" [pointer: string]: nothing -> cell-path {
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
export def "patch apply" [crd: record, patch: record]: nothing -> record {
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
    | reject -o ...($SERVER_SIDE_FIELDS | each {|f| $f | split row '.' | into cell-path })
  )
  let cleaned = (prune-metadata-map $cleaned "labels" $INJECTED_LABEL_PATTERNS)
  let cleaned = (prune-metadata-map $cleaned "annotations" $INJECTED_ANNOTATION_PATTERNS)
  $transform.patches | reduce --fold $cleaned {|p, acc| patch apply $acc $p }
}

# Merge CRDs coming from several sources. Same metadata.name must mean same content.

export def "dedupe crds" [crds: list<record>]: nothing -> list<record> {
  let groups = ($crds | group-by {|c| $c.metadata.name } --to-table | rename name items)
  let conflicts = ($groups | where {|g| ($g.items | uniq | length) > 1 } | get name)
  if not ($conflicts | is-empty) {
    error make {msg: $"CRDs defined differently by several sources: ($conflicts | str join ', '). Fix the manifest with include/exclude or drop a source."}
  }
  $groups
  | each {|g| $g.items.0 }
  | sort-by {|c| $c.metadata.name }
}

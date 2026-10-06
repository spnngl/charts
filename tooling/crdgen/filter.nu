# Keep CustomResourceDefinitions only; apply include/exclude; report what was dropped.

const CRD_API = "apiextensions.k8s.io/v1"
const CRD_KIND = "CustomResourceDefinition"

def is-crd [d: record]: nothing -> bool {
  ($d | get -o apiVersion) == $CRD_API and ($d | get -o kind) == $CRD_KIND
}

def matches-any [name: string, patterns: list<string>]: nothing -> bool {
  $patterns | any {|p| $name =~ $p }
}

# Returns {crds: list<record>, dropped: list<string>} where `dropped` lists
# non-CRD kinds (apiVersion/kind) and excluded CRD names, for the README and PR body.
export def "filter crds" [docs: list<record>, transform: record]: nothing -> record<crds: list<record>, dropped: list<string>> {
  # kustomization.yaml files are build inputs, not shipped resources: not worth reporting.
  let non_crd = ($docs | where {|d| (not (is-crd $d)) and ($d | get -o kind) != "Kustomization" })
  let crds = ($docs | where {|d| is-crd $d })
  let legacy = ($docs | where {|d| ($d | get -o kind) == $CRD_KIND and ($d | get -o apiVersion) != $CRD_API })
  if not ($legacy | is-empty) {
    error make {msg: $"($legacy | length) CRD\(s\) use ($legacy.0.apiVersion); only ($CRD_API) is supported"}
  }
  let dropped_kinds = (
    $non_crd
    | each {|d| $"($d | get -o apiVersion | default '?')/($d | get -o kind | default '?')" }
    | uniq
    | sort
  )
  let is_selected = {|c|
    let name = $c.metadata.name
    let included = (($transform.include | is-empty) or (matches-any $name $transform.include))
    let excluded = (matches-any $name $transform.exclude)
    $included and (not $excluded)
  }
  let selected = ($crds | where $is_selected)
  let dropped_crds = (
    $crds
    | where {|c| not (do $is_selected $c) }
    | each {|c| $"CustomResourceDefinition ($c.metadata.name) \(excluded by manifest\)" }
  )
  if ($selected | is-empty) {
    error make {msg: $"zero CRDs after filtering \(($docs | length) documents rendered, ($crds | length) CRDs before include/exclude\)"}
  }
  {crds: $selected, dropped: ($dropped_kinds | append $dropped_crds)}
}

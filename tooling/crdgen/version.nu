# Chart version computation against the base branch (deterministic, idempotent).
#
#   appVersion = upstream version
#   new chart                      → version = appVersion
#   upstream changed               → version = appVersion if > previous else previous.PATCH+1
#   upstream same, content changed → version = previous.PATCH+1   (tooling trigger)
#   nothing changed                → version = previous

use config.nu [ANNOTATION_PREFIX]

def ref-exists [ref: string]: nothing -> bool {
  (^git rev-parse --verify --quiet $ref | complete | get exit_code) == 0
}

# Git ref the generated output is compared against. null on a repo without history.
export def "version base-ref" []: nothing -> any {
  let override = ($env.CRDGEN_BASE_REF? | default "")
  if not ($override | is-empty) {
    if not (ref-exists $override) { error make {msg: $"CRDGEN_BASE_REF '($override)' does not exist"} }
    return $override
  }
  for r in ["origin/main" "main"] {
    if (ref-exists $r) { return $r }
  }
  null
}

# Previously committed Chart.yaml for a chart at `base_ref`, or null.
export def "version previous" [name: string, base_ref: any]: nothing -> any {
  if $base_ref == null { return null }
  let out = (^git show $"($base_ref):charts/($name)/Chart.yaml" | complete)
  if $out.exit_code != 0 { return null }
  $out.stdout | from yaml
}

# {path, hash} for every blob under charts/<name> at base_ref (paths relative to the chart dir).
export def "version tree-hashes" [name: string, base_ref: any]: nothing -> table<path: string, hash: string> {
  if $base_ref == null { return [] }
  let out = (^git ls-tree -r $base_ref -- $"charts/($name)" | complete)
  if $out.exit_code != 0 { return [] }
  $out.stdout
  | lines
  | parse "{mode} {type} {hash}\t{path}"
  | each {|r| {path: ($r.path | str replace $"charts/($name)/" ""), hash: $r.hash} }
}

# {path, hash} for every file under a generated directory (git blob hashes).
export def "version dir-hashes" [dir: path]: nothing -> table<path: string, hash: string> {
  glob ($dir | path join "**" "*") --no-dir
  | sort
  | each {|f| {path: ($f | path relative-to $dir), hash: (^git hash-object $f | str trim)} }
}

def strip-volatile [chart_yaml: record]: nothing -> record {
  $chart_yaml
  | reject -o version
  | reject -o ([annotations "artifacthub.io/changes"] | into cell-path)
}

def bump-patch [version: string]: nothing -> string {
  $version | into semver | semver bump patch | into string
}

# Pure decision: version, trigger and change note from the previous Chart.yaml
# (null for a new chart), the resolved pin, the Chart.yaml record without
# version/changes, and whether any file other than Chart.yaml differs from base.
export def "version decide" [
  input: record<previous: any, resolved: record, chart_record: record, files_changed: bool>
]: nothing -> record<version: string, trigger: string, changes: list<string>> {
  let prev = $input.previous
  let app_version = $input.resolved.appVersion
  let resolved_tag = $input.resolved.tag
  if $prev == null {
    return {
      version: $app_version
      trigger: "new"
      changes: [$"Initial release, CRDs from upstream ($resolved_tag)"]
    }
  }
  let prev_version = ($prev.version | into string)
  let prev_app = ($prev.appVersion | into string)
  if $prev_app != $app_version {
    let candidate = (if ($app_version | into semver) > ($prev_version | into semver) { $app_version } else { bump-patch $prev_version })
    let prev_tag = ($prev | get -o ([annotations $"($ANNOTATION_PREFIX)/upstream-tag"] | into cell-path) | default $prev_app)
    return {
      version: $candidate
      trigger: "upstream"
      changes: [$"Upstream CRDs updated from ($prev_tag) to ($resolved_tag)"]
    }
  }
  let chart_changed = ((strip-volatile $prev) != (strip-volatile $input.chart_record))
  if (not $input.files_changed) and (not $chart_changed) {
    let prev_changes = ($prev | get -o ([annotations "artifacthub.io/changes"] | into cell-path) | default "" | from yaml | default [])
    return {version: $prev_version, trigger: "none", changes: $prev_changes}
  }
  {
    version: (bump-patch $prev_version)
    trigger: "tooling"
    changes: [$"Chart regenerated with updated tooling \(upstream unchanged at ($resolved_tag)\)"]
  }
}

# Decide version + change note. `generated_dir` holds everything except Chart.yaml;
# `chart_record` is the Chart.yaml content without version/changes.
export def "version compute" [
  name: string
  app_version: string
  resolved_tag: string
  generated_dir: path
  chart_record: record
  base_ref: any
]: nothing -> record<version: string, trigger: string, changes: list<string>> {
  let base_files = (version tree-hashes $name $base_ref | where path != "Chart.yaml" | sort-by path)
  let new_files = (version dir-hashes $generated_dir | where path != "Chart.yaml" | sort-by path)
  version decide {
    previous: (version previous $name $base_ref)
    resolved: {tag: $resolved_tag, appVersion: $app_version}
    chart_record: $chart_record
    files_changed: ($base_files != $new_files)
  }
}

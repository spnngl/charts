#!/usr/bin/env nu
# List charts whose Chart.yaml version is not yet published in GHCR.
# Output: JSON array of {name, version, dir} (for a GitHub Actions matrix).
#   nu tooling/release/plan.nu [--all]      --all ignores the registry check

use ../crdgen/config.nu [OCI_BASE]

def published [name: string, version: string]: nothing -> bool {
  # `helm show chart` succeeds only if that exact version exists (anonymous read on public GHCR).
  (^helm show chart $"($OCI_BASE)/($name)" --version $version | complete | get exit_code) == 0
}

def main [--all]: nothing -> nothing {
  let root = (^git rev-parse --show-toplevel | str trim)
  let charts = (
    glob ($root | path join "charts" "*" "Chart.yaml")
    | sort
    | each {|f|
        let c = (open $f)
        {name: $c.name, version: ($c.version | into string), dir: ($f | path dirname | path relative-to $root)}
      }
  )
  let todo = (if $all { $charts } else { $charts | where {|c| not (published $c.name $c.version) } })
  for c in $charts {
    print -e $"(if $c in $todo { 'publish' } else { 'exists ' })  ($c.name) ($c.version)"
  }
  $todo | to json -r | print
}

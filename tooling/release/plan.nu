#!/usr/bin/env nu
# List charts whose Chart.yaml version has not been fully published.
# Output: JSON array of {name, version, dir} (for a GitHub Actions matrix).
#   nu tooling/release/plan.nu [--all]      --all ignores the completion check
#
# "Published" means the GitHub Release <name>-<version> exists: it is created
# as the last step of the publish job, so a run that failed after `helm push`
# (unsigned, unattested) is picked up again. The publish job never re-pushes
# an existing registry tag; it resumes from the digest already there.

def published [name: string, version: string]: nothing -> bool {
  (^gh release view $"($name)-($version)" --json tagName | complete | get exit_code) == 0
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

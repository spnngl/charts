#!/usr/bin/env nu
# crdgen — generate CRD-only Helm charts from sources/*.yaml manifests.
#
#   nu tooling/crdgen/mod.nu regen --all          regenerate every CRD chart
#   nu tooling/crdgen/mod.nu regen <name>...      regenerate specific charts
#   nu tooling/crdgen/mod.nu check --all          fail if charts/ differs from a fresh regeneration
#   nu tooling/crdgen/mod.nu sync --all           bump pins to newest upstream tags and regenerate
#   nu tooling/crdgen/mod.nu notice               rewrite the root NOTICE
#   nu tooling/crdgen/mod.nu list                 show manifests and pins

use config.nu *
use manifest.nu *
use resolve.nu *
use fetch.nu *
use render.nu *
use filter.nu *
use sanitize.nu *
use dedupe.nu *
use templatize.nu *
use emit.nu *
use version.nu *
use validate.nu *

export def repo-root []: nothing -> path {
  ^git rev-parse --show-toplevel | str trim
}

def select-manifests [names: list<string>, all: bool]: nothing -> list<record> {
  let root = (repo-root)
  let manifests = (manifest list ($root | path join "sources"))
  if $all { return $manifests }
  if ($names | is-empty) { error make {msg: "give chart names or --all"} }
  $names | each {|n|
    let m = ($manifests | where name == $n)
    if ($m | is-empty) { error make {msg: $"no manifest sources/($n).yaml"} }
    $m.0
  }
}

# Run the pipeline up to sanitized+deduped CRDs.
export def pipeline [manifest: record]: nothing -> record {
  let resolved = (resolve current $manifest)
  let repo_dir = (fetch repo $manifest $resolved)
  let license = (fetch license $manifest $repo_dir)
  let docs = ($manifest.sources | each {|s| render source $s $manifest $resolved $repo_dir } | docs normalize)
  let filtered = (filter crds $docs $manifest.transform)
  let crds = (dedupe crds ($filtered.crds | each {|c| sanitize crd $c $manifest.transform }))
  {resolved: $resolved, repo_dir: $repo_dir, license: $license, crds: $crds, dropped: $filtered.dropped, documents: ($docs | length)}
}

# Generate a chart into a fresh temp dir; returns {dir, summary}.
export def generate [manifest: record, --skip-validate]: nothing -> record {
  let p = (pipeline $manifest)
  let tmp = (mktemp -d -t $"crdgen-($manifest.name).XXXXXX")
  let dir = ($tmp | path join $manifest.name)
  emit chart-files $dir $manifest $p.resolved $p.crds $p.dropped $p.license
  let chart_record = (emit chart-record $manifest $p.resolved $p.crds $p.license)
  # The README depends on the size (SQL driver note), so the size is always
  # estimated, even with --skip-validate. The note only grows the release.
  # The README must be final before `version compute` hashes the directory,
  # so size it with a deterministic provisional Chart.yaml (appVersion, no
  # changes); the final one differs by a few bytes.
  emit chart-yaml $chart_record $p.resolved.appVersion [] | save -f ($dir | path join "Chart.yaml")
  let budget = (validate size-budget $dir)
  let budget = (if $budget.status != "oversized" { $budget } else {
    emit readme $manifest $p.resolved $p.crds $p.dropped $p.license --oversized | save -f ($dir | path join "README.md")
    validate size-budget $dir
  })
  let base_ref = (version base-ref)
  let v = (version compute $manifest.name $p.resolved.appVersion $p.resolved.tag $dir $chart_record $base_ref)
  emit chart-yaml $chart_record $v.version $v.changes | save -f ($dir | path join "Chart.yaml")
  if not $skip_validate { validate chart $dir $p.crds }
  {
    dir: $dir
    summary: {
      name: $manifest.name
      version: $v.version
      appVersion: $p.resolved.appVersion
      tag: $p.resolved.tag
      commit: $p.resolved.sha
      trigger: $v.trigger
      base: ($base_ref | default "none")
      crds: ($p.crds | length)
      dropped: $p.dropped
      release_secret: ($budget.bytes | into filesize)
    }
  }
}

def install [generated_dir: path, name: string]: nothing -> nothing {
  let target = ((repo-root) | path join "charts" $name)
  if ($target | path exists) { rm -rf $target }
  mkdir ($target | path dirname)
  mv $generated_dir $target
}

def emit-result [rows: table, json: bool]: nothing -> nothing {
  if $json { print ($rows | to json -r) } else { print ($rows | table -e) }
}

# Regenerate charts from their manifests.
export def "main regen" [...names: string, --all, --skip-validate, --json]: nothing -> nothing {
  let results = (select-manifests $names $all | each {|m|
    let g = (generate $m --skip-validate=$skip_validate)
    install $g.dir $m.name
    $g.summary
  })
  main notice
  emit-result $results $json
}

# Drift check: regenerate into temp and compare with the committed chart, byte for byte.
export def "main check" [...names: string, --all]: nothing -> nothing {
  let root = (repo-root)
  let drift = (select-manifests $names $all | each {|m|
    let g = (generate $m)
    let committed = ($root | path join "charts" $m.name)
    let a = (version dir-hashes $g.dir | sort-by path)
    let b = (if ($committed | path exists) { version dir-hashes $committed | sort-by path } else { [] })
    if $a == $b {
      print $"ok    ($m.name) ($g.summary.version)"
      null
    } else {
      print $"DRIFT ($m.name): charts/($m.name) differs from regeneration"
      ^git --no-pager diff --no-index --stat $committed $g.dir | print
      $m.name
    }
  } | compact)
  # root NOTICE
  let want = (notice-text)
  let have = (if ($root | path join "NOTICE" | path exists) { open --raw ($root | path join "NOTICE") } else { "" })
  let drift = (if $want != $have { print "DRIFT NOTICE differs from regeneration"; $drift | append "NOTICE" } else { $drift })
  # naming invariant
  let chart_dirs = (ls ($root | path join "charts") | where type == dir | get name | path basename)
  let manifests = (manifest list ($root | path join "sources") | get name)
  let orphans = ($chart_dirs | where {|d| ($d | str ends-with "-crds") and $d not-in $manifests })
  let missing = ($manifests | where {|n| $n not-in $chart_dirs })
  if not ($orphans | is-empty) { print $"charts without manifest: ($orphans | str join ', ')" }
  if not ($missing | is-empty) { print $"manifests without chart: ($missing | str join ', ')" }
  if not ($drift | append $orphans | append $missing | is-empty) {
    error make {msg: "drift detected; run `nu tooling/crdgen/mod.nu regen --all` and commit"}
  }
}

# Rewrite `version.current` in a manifest file, preserving comments/layout.
def set-pin [path: path, tag: string]: nothing -> nothing {
  let lines = (open --raw $path | lines)
  let idx = ($lines | enumerate | where {|l| $l.item =~ '^\s+current:' } | get 0.index)
  $lines | update $idx ($"  current: ($tag)") | str join "\n" | $"($in)\n" | save -f $path
}

# Bump pins to the newest allowed upstream tag and regenerate.
# Rows: {name, from, to (null when up to date), updated, version}.
export def "main sync" [...names: string, --all, --dry-run, --json]: nothing -> nothing {
  let root = (repo-root)
  let rows = (select-manifests $names $all | each {|m|
    let latest = (resolve latest $m)
    if $latest == null {
      {name: $m.name, from: $m.version.current, to: null, updated: false, version: null}
    } else if $dry_run {
      {name: $m.name, from: $m.version.current, to: $latest.tag, updated: false, version: null}
    } else {
      set-pin ($root | path join "sources" $"($m.name).yaml") $latest.tag
      let fresh = (manifest load ($root | path join "sources" $"($m.name).yaml"))
      let g = (generate $fresh)
      install $g.dir $m.name
      main notice
      {name: $m.name, from: $m.version.current, to: $latest.tag, updated: true, version: $g.summary.version}
    }
  })
  emit-result $rows $json
}

def notice-text []: nothing -> string {
  let root = (repo-root)
  let rows = (manifest list ($root | path join "sources") | each {|m|
    $"- ($m.name): CRDs from ($m.upstream.repo) \(($m.upstream.license)\)"
  })
  [
    "spnngl/charts"
    $"Copyright \(c\) ($OWNER). Licensed under the Apache License, Version 2.0 \(see LICENSE\)."
    ""
    "This repository redistributes modified copies of CustomResourceDefinition"
    "manifests from the following upstream projects. Each chart directory contains"
    "the upstream LICENSE, a NOTICE stating the pinned tag/commit and the"
    "modifications made, and attribution in its README."
    ""
  ] | append $rows | append [""] | str join "\n"
}

# Rewrite the root NOTICE (no per-version data, so concurrent sync PRs never conflict).
export def "main notice" []: nothing -> nothing {
  notice-text | save -f ((repo-root) | path join "NOTICE")
}

export def "main list" [--json]: nothing -> nothing {
  let rows = (manifest list ((repo-root) | path join "sources")
  | each {|m| {name: $m.name, upstream: $m.upstream.repo, pin: $m.version.current, allow: $m.version.allow, sources: ($m.sources | get kind | str join ",")} })
  emit-result $rows $json
}

export def main []: nothing -> nothing {
  help main
}

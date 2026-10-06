# Fetch upstream sources at the pinned tag, and read upstream license files.

use exec.nu [run-checked]
use manifest.nu ["manifest gh-slug"]

def cache-dir []: nothing -> path {
  $env.CRDGEN_CACHE? | default ($nu.cache-dir | path join "crdgen")
}

# Shallow clone of the upstream repo at `resolved.tag`. Cached by (repo, tag);
# the cached checkout is verified against the resolved commit so a moved tag
# never goes unnoticed.
export def "fetch repo" [manifest: record, resolved: record]: nothing -> path {
  let cache = (cache-dir)
  let slug = ($manifest.upstream.repo | str replace -r '^https?://' '' | str replace -a '/' '__')
  let dir = ($cache | path join $"($slug)@($resolved.tag)")
  if not ($dir | path join ".git" | path exists) {
    mkdir $cache
    if ($dir | path exists) { rm -rf $dir }
    run-checked $"git clone ($manifest.upstream.repo) at ($resolved.tag)" { ^git clone --quiet --depth 1 --branch $resolved.tag $manifest.upstream.repo $dir } | ignore
  }
  let head = (^git -C $dir rev-parse HEAD | str trim)
  if $head != $resolved.sha {
    error make {msg: $"cached checkout ($dir) is at ($head) but tag ($resolved.tag) resolves to ($resolved.sha); upstream moved the tag or the cache is stale \(delete it\)"}
  }
  $dir
}

# Download one GitHub release asset into a temp dir; returns the file path.
# On success the caller owns the file's parent directory and must remove it.
export def "fetch release-asset" [manifest: record, resolved: record, asset: string]: nothing -> path {
  let slug = (manifest gh-slug $manifest)
  let dir = (mktemp -d -t crdgen-asset.XXXXXX)
  try {
    run-checked $"gh release download ($slug) ($resolved.tag) pattern '($asset)'" { ^gh release download $resolved.tag -R $slug -p $asset -D $dir } | ignore
    let files = (ls $dir | get name)
    if ($files | length) != 1 {
      error make {msg: $"asset pattern '($asset)' matched ($files | length) files in ($slug) ($resolved.tag); must match exactly one"}
    }
    $files.0
  } catch {|e|
    rm -rf $dir
    error make {msg: $e.msg}
  }
}

# Detect the SPDX id of a license text. Returns null when unknown.
export def "license detect" [text: string]: nothing -> oneof<string, nothing> {
  let t = ($text | str replace -ra '\s+' ' ')
  if ($t =~ 'Apache License' and $t =~ 'Version 2\.0') { return "Apache-2.0" }
  if ($t =~ 'Permission is hereby granted, free of charge') { return "MIT" }
  if ($t =~ 'Redistribution and use in source and binary forms') {
    if ($t =~ 'Neither the name') { return "BSD-3-Clause" }
    return "BSD-2-Clause"
  }
  null
}

# Upstream LICENSE/NOTICE at the checkout. Fails if LICENSE is missing or does
# not match the manifest's declared SPDX id.
export def "fetch license" [manifest: record, repo_dir: path]: nothing -> record<license_text: string, spdx: string, notice_text: oneof<string, nothing>> {
  let candidates = (ls $repo_dir | get name | where {|p| ($p | path basename) =~ '(?i)^(LICENSE|LICENCE|COPYING)(\.(md|txt))?$' })
  if ($candidates | is-empty) {
    error make {msg: $"no LICENSE file at the root of ($manifest.upstream.repo) @ ($manifest.version.current)"}
  }
  let license_path = $candidates.0
  let license_text = (open --raw $license_path)
  let detected = (license detect $license_text)
  if $detected != $manifest.upstream.license {
    error make {msg: $"upstream LICENSE detected as ($detected | default 'unknown') but manifest declares ($manifest.upstream.license); upstream may have relicensed \u{2014} human decision required"}
  }
  let notices = (ls $repo_dir | get name | where {|p| ($p | path basename) =~ '(?i)^NOTICE(\.(md|txt))?$' })
  {
    license_text: $license_text
    spdx: $detected
    notice_text: (if ($notices | is-empty) { null } else { open --raw $notices.0 })
  }
}

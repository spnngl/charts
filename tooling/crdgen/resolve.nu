# Resolve manifest pins against the upstream git remote.

use semver.nu *

# All upstream tags matching tagPattern: [{tag, appVersion, sha}], ascending.
export def "resolve tags" [manifest: record]: nothing -> table<tag: string, appVersion: string, sha: string> {
  let out = (^git ls-remote --tags --refs $manifest.upstream.repo | complete)
  if $out.exit_code != 0 {
    error make {msg: $"git ls-remote failed for ($manifest.upstream.repo): ($out.stderr)"}
  }
  $out.stdout
  | lines
  | parse "{sha}\trefs/tags/{tag}"
  | each {|r|
      let cap = ($r.tag | parse --regex $manifest.version.tagPattern)
      if ($cap | is-empty) { null } else { {tag: $r.tag, appVersion: ($cap | get capture0.0), sha: $r.sha} }
    }
  | compact
  | sort-by -c {|a, b| (semver cmp $a.appVersion $b.appVersion) < 0 }
}

# Resolve `version.current` to {tag, appVersion, sha}. sha is the peeled commit.
export def "resolve current" [manifest: record]: nothing -> record<tag: string, appVersion: string, sha: string> {
  let tag = $manifest.version.current
  let cap = ($tag | parse --regex $manifest.version.tagPattern)
  if ($cap | is-empty) {
    error make {msg: $"version.current '($tag)' does not match tagPattern"}
  }
  let out = (^git ls-remote --tags $manifest.upstream.repo $"refs/tags/($tag)" $"refs/tags/($tag)^{}" | complete)
  if $out.exit_code != 0 or ($out.stdout | str trim | is-empty) {
    error make {msg: $"tag '($tag)' not found in ($manifest.upstream.repo)"}
  }
  let refs = ($out.stdout | lines | parse "{sha}\t{ref}")
  # annotated tags expose the commit via the peeled ^{} ref; lightweight tags don't have one
  let peeled = ($refs | where ref =~ '\^\{\}$')
  let sha = (if ($peeled | is-empty) { $refs.0.sha } else { $peeled.0.sha })
  {tag: $tag, appVersion: ($cap | get capture0.0), sha: $sha}
}

# Newest allowed upstream version above `current`, or null.
export def "resolve latest" [manifest: record]: nothing -> any {
  let current_app = ($manifest.version.current | parse --regex $manifest.version.tagPattern | get capture0.0)
  resolve tags $manifest
  | where {|t| (semver cmp $t.appVersion $current_app) > 0 }
  | where {|t| semver allowed $current_app $t.appVersion $manifest.version.allow }
  | last
}

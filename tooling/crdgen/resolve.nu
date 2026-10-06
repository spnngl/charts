# Resolve manifest pins against the upstream git remote.

# `git ls-remote --tags --refs` text → tags matching `tag_pattern`: [{tag, appVersion, sha}], ascending.
# A matching tag whose capture is not a semantic version is skipped with a warning.
export def parse-tags [tag_pattern: string]: string -> table<tag: string, appVersion: string, sha: string> {
  $in
  | lines
  | parse "{sha}\trefs/tags/{tag}"
  | each {|r|
      let cap = ($r.tag | parse --regex $tag_pattern)
      if ($cap | is-empty) { return null }
      let app_version = $cap.capture0.0
      if (try { $app_version | into semver; true } catch { false }) {
        {tag: $r.tag, appVersion: $app_version, sha: $r.sha}
      } else {
        print -e $"::warning::skipping tag ($r.tag): not a semantic version"
        null
      }
    }
  | compact
  | sort-by {|t| $t.appVersion | into semver }
}

# All upstream tags matching tagPattern: [{tag, appVersion, sha}], ascending.
export def "resolve tags" [manifest: record]: nothing -> table<tag: string, appVersion: string, sha: string> {
  let out = (^git ls-remote --tags --refs $manifest.upstream.repo | complete)
  if $out.exit_code != 0 {
    error make {msg: $"git ls-remote failed for ($manifest.upstream.repo): ($out.stderr)"}
  }
  $out.stdout | parse-tags $manifest.version.tagPattern
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

# Is `candidate` an allowed upgrade from `current` under policy all|minor|patch?
export def "resolve allowed" [current: string, candidate: string, policy: string]: nothing -> bool {
  let a = ($current | into semver)
  let b = ($candidate | into semver)
  match $policy {
    "all" => true
    "minor" => ($a.major == $b.major)
    "patch" => ($a.major == $b.major and $a.minor == $b.minor)
    _ => { error make {msg: $"unknown allow policy '($policy)'"} }
  }
}

# Newest allowed upstream version above `current`, or null.
export def "resolve latest" [manifest: record]: nothing -> any {
  let current_app = ($manifest.version.current | parse --regex $manifest.version.tagPattern | get capture0.0)
  resolve tags $manifest
  | where {|t| ($t.appVersion | into semver) > ($current_app | into semver) }
  | where {|t| resolve allowed $current_app $t.appVersion $manifest.version.allow }
  | last
}

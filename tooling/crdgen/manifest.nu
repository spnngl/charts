# Load and validate sources/<name>-crds.yaml manifests.

use config.nu [LICENSE_ALLOWLIST SOURCE_PATH_FIELD ALLOW_VALUES]

def fail [name: string, msg: string] {
  error make {msg: $"manifest ($name): ($msg)"}
}

def require-string [m: record, name: string, path: string] {
  let v = ($m | get -o ($path | split row '.' | into cell-path))
  if ($v | describe -d).type != string or ($v | str trim | is-empty) {
    fail $name $"'($path)' must be a non-empty string"
  }
}

# Validate one source entry (`s` is untyped manifest data).
def validate-source [name: string, s: any, idx: int] {
  if ($s | describe -d).type != record {
    fail $name $"sources[($idx)] must be a record"
  }
  let kind = ($s | get -o kind)
  let kinds = ($SOURCE_PATH_FIELD | columns)
  if $kind not-in $kinds {
    fail $name $"sources[($idx)].kind must be one of ($kinds | str join ', '), got '($kind)'"
  }
  let field = ($SOURCE_PATH_FIELD | get $kind)
  if ($s | get -o $field | default "" | is-empty) { fail $name $"sources[($idx)].($field) is required for ($kind)" }
}

# Validate a manifest record. `name` is the file stem; must equal manifest.name.
export def "manifest validate" [m: record, name: string]: nothing -> nothing {
  if ($m | get -o name) != $name {
    fail $name $"'name' must equal the file name '($name)', got '($m | get -o name)'"
  }
  if not ($name | str ends-with "-crds") {
    fail $name "'name' must end with '-crds'"
  }
  require-string $m $name "description"
  require-string $m $name "upstream.repo"
  require-string $m $name "upstream.homepage"
  require-string $m $name "upstream.license"
  if not ($m.upstream.repo | str starts-with "https://") {
    fail $name "'upstream.repo' must be an https URL"
  }
  if $m.upstream.license not-in $LICENSE_ALLOWLIST {
    fail $name $"'upstream.license' ($m.upstream.license) is not in the allowlist ($LICENSE_ALLOWLIST | str join ', '); onboarding needs a deliberate allowlist change"
  }
  require-string $m $name "version.tagPattern"
  require-string $m $name "version.current"
  let allow = ($m | get -o version.allow | default "all")
  if $allow not-in $ALLOW_VALUES {
    fail $name $"'version.allow' must be one of ($ALLOW_VALUES | str join ', ')"
  }
  # tagPattern must compile and must capture exactly one group on `current`
  let cap = (try { $m.version.current | parse --regex $m.version.tagPattern } catch {|e| fail $name $"'version.tagPattern' is not a valid regex: ($e.msg)" })
  if ($cap | is-empty) {
    fail $name $"'version.current' ($m.version.current) does not match 'version.tagPattern'"
  }
  if "capture0" not-in ($cap | columns) {
    fail $name "'version.tagPattern' must contain one capture group for the appVersion"
  }
  let sources = ($m | get -o sources)
  if ($sources | describe -d).type != list or ($sources | is-empty) {
    fail $name "'sources' must be a non-empty list"
  }
  for e in ($sources | enumerate) { validate-source $name $e.item $e.index }
  let conflicts = ($m | get -o conflictsWith | default [])
  for c in $conflicts {
    if ($c | describe -d).type != string { fail $name "'conflictsWith' entries must be strings" }
  }
  let t = ($m | get -o transform | default {})
  for k in ($t | columns) {
    if $k not-in [include exclude patches stripDocs] { fail $name $"unknown 'transform.($k)'" }
  }
  if ($t | get -o stripDocs | default false | describe -d).type != bool { fail $name "'transform.stripDocs' must be a boolean" }
  for p in ($t | get -o patches | default []) {
    if ($p | get -o reason | default "" | is-empty) { fail $name "every 'transform.patches' entry needs a 'reason'" }
    if ($p | get -o op) not-in [add replace remove] { fail $name "'transform.patches[].op' must be add|replace|remove" }
    if ($p | get -o path | default "" | is-empty) { fail $name "'transform.patches[].path' is required" }
  }
}

# Fill optional fields with defaults so downstream code never needs `get -o`.
export def "manifest defaults" [m: record]: nothing -> record {
  $m
  | upsert upstream.icon ($m | get -o upstream.icon)
  | upsert version.allow ($m | get -o version.allow | default "all")
  | upsert conflictsWith ($m | get -o conflictsWith | default [])
  | upsert transform {
      include: ($m | get -o transform.include | default [])
      exclude: ($m | get -o transform.exclude | default [])
      patches: ($m | get -o transform.patches | default [])
      stripDocs: ($m | get -o transform.stripDocs | default false)
    }
}

# Load + validate + default a manifest from its path.
export def "manifest load" [path: path]: nothing -> record {
  let name = ($path | path basename | str replace -r '\.ya?ml$' '')
  let m = (open $path)
  manifest validate $m $name
  manifest defaults $m
}

# All manifests in sources/, sorted by name.
export def "manifest list" [sources_dir: path]: nothing -> list<record> {
  glob ($sources_dir | path join "*.yaml")
  | sort
  | each {|p| manifest load $p }
}

# owner/repo from upstream.repo URL.
export def "manifest gh-slug" [m: record]: nothing -> string {
  $m.upstream.repo
  | str replace -r '^https://github\.com/' ''
  | str replace -r '(\.git)?/?$' ''
}

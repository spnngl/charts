# Minimal semver (MAJOR.MINOR.PATCH, no pre-release/build) helpers.

export def "semver parse" [v: string]: nothing -> record<major: int, minor: int, patch: int> {
  let parts = ($v | str trim | str replace -r '^v' '' | split row '.')
  if ($parts | length) != 3 {
    error make {msg: $"not a MAJOR.MINOR.PATCH version: '($v)'"}
  }
  {
    major: ($parts.0 | into int)
    minor: ($parts.1 | into int)
    patch: ($parts.2 | into int)
  }
}

export def "semver format" [v: record]: nothing -> string {
  $"($v.major).($v.minor).($v.patch)"
}

# -1 if a < b, 0 if equal, 1 if a > b
export def "semver cmp" [a: string, b: string]: nothing -> int {
  let pa = (semver parse $a)
  let pb = (semver parse $b)
  for k in [major minor patch] {
    if ($pa | get $k) < ($pb | get $k) { return (-1) }
    if ($pa | get $k) > ($pb | get $k) { return 1 }
  }
  0
}

export def "semver bump-patch" [v: string]: nothing -> string {
  let p = (semver parse $v)
  semver format ($p | update patch ($p.patch + 1))
}

# Is `candidate` an allowed upgrade from `current` under policy all|minor|patch?
export def "semver allowed" [current: string, candidate: string, policy: string]: nothing -> bool {
  let a = (semver parse $current)
  let b = (semver parse $candidate)
  match $policy {
    "all" => true
    "minor" => ($a.major == $b.major)
    "patch" => ($a.major == $b.major and $a.minor == $b.minor)
    _ => { error make {msg: $"unknown allow policy '($policy)'"} }
  }
}

# Sort a list of version strings ascending.
export def "semver sort" []: list<string> -> list<string> {
  $in | sort-by -c {|a, b| (semver cmp $a $b) < 0 }
}

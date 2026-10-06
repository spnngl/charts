#!/usr/bin/env nu
# Register published charts on Artifact Hub (one AH repository per OCI chart)
# and push the AH metadata artifact (artifacthub-repo.yml carrying the
# repositoryID, which enables the Verified Publisher badge). Idempotent.
#   nu tooling/release/artifacthub.nu <chart>...     specific charts
#   nu tooling/release/artifacthub.nu --all           every published chart
# Env: AH_API_KEY_ID, AH_API_KEY_SECRET (skips with a warning when absent).
# Needs `oras` logged in to the registry.

use ../crdgen/config.nu [OCI_BASE OCI_HOST_PATH OWNER]

const AH_API = "https://artifacthub.io/api/v1"
const METADATA_LAYER_TYPE = "application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml"

def headers []: nothing -> record {
  {"X-API-KEY-ID": $env.AH_API_KEY_ID, "X-API-KEY-SECRET": $env.AH_API_KEY_SECRET}
}

# AH repository names must match ^[a-z][a-z0-9-]*$ and be unique per user.
def ah-repo-name [chart: string]: nothing -> string {
  $"($OWNER)-($chart)"
}

# Parsed response body: untyped external data.
def ah-get [path: string]: nothing -> any {
  let r = (http get -H (headers) -e -f $"($AH_API)($path)")
  if $r.status >= 400 {
    error make {msg: $"Artifact Hub GET ($path) -> HTTP ($r.status): ($r.body)"}
  }
  $r.body
}

def ah-post [path: string, body: record]: nothing -> nothing {
  let r = (http post -H (headers) -e -f --content-type application/json $"($AH_API)($path)" $body)
  if $r.status >= 400 {
    error make {msg: $"Artifact Hub POST ($path) -> HTTP ($r.status): ($r.body)"}
  }
}

# Artifact Hub caches search responses per query string, so a lookup made
# before creation would keep returning [] afterwards: bust it with a nonce.
def find-repository [url: string]: nothing -> oneof<record, nothing> {
  let nonce = (date now | format date %s%f)
  ah-get $"/repositories/search?url=($url)&limit=10&nonce=($nonce)" | where url == $url | get 0?
}

# Creation is asynchronous on the AH side; poll a few times.
def find-repository-retry [url: string]: nothing -> oneof<record, nothing> {
  for attempt in 1..6 {
    sleep 5sec
    let found = (find-repository $url)
    if $found != null { return $found }
    print $"  waiting for Artifact Hub to list ($url) \(attempt ($attempt)/6\)"
  }
  null
}

def is-published [chart: string]: nothing -> bool {
  (^oras repo tags $"($OCI_HOST_PATH)/($chart)" | complete | get exit_code) == 0
}

# Ensure the AH repository exists and the metadata artifact is pushed. Returns the repositoryID.
def ensure [chart: string, template: record]: nothing -> string {
  let url = $"($OCI_BASE)/($chart)"
  let existing = (find-repository $url)
  let repo = (if $existing == null {
    print $"  registering ($url) as ($chart)"
    ah-post "/repositories/user" {kind: 0, name: (ah-repo-name $chart), display_name: $chart, url: $url}
    find-repository-retry $url
  } else {
    $existing
  })
  if $repo == null {
    error make {msg: $"Artifact Hub repository for ($url) not found after creation"}
  }
  let dir = (mktemp -d -t ah.XXXXXX)
  $template | upsert repositoryID $repo.repository_id | to yaml | save -f ($dir | path join "artifacthub-repo.yml")
  let push = (do { cd $dir; ^oras push $"($OCI_HOST_PATH)/($chart):artifacthub.io" $"artifacthub-repo.yml:($METADATA_LAYER_TYPE)" } | complete)
  rm -rf $dir
  if $push.exit_code != 0 {
    error make {msg: $"oras push of Artifact Hub metadata for ($chart) failed:\n($push.stderr)"}
  }
  $repo.repository_id
}

def main [...charts: string, --all]: nothing -> nothing {
  if ($env.AH_API_KEY_ID? | default "" | is-empty) or ($env.AH_API_KEY_SECRET? | default "" | is-empty) {
    print "::warning::Artifact Hub secrets not set, skipping registration"
    return
  }
  let root = (^git rev-parse --show-toplevel | str trim)
  let template = (open ($root | path join "artifacthub-repo.yml"))
  let selected = (if $all {
    glob ($root | path join "charts" "*" "Chart.yaml") | each {|f| open $f | get name } | sort
  } else if ($charts | is-empty) {
    error make {msg: "give chart names or --all"}
  } else { $charts })
  for chart in $selected {
    if not (is-published $chart) {
      print $"skip  ($chart): not published yet"
      continue
    }
    let id = (ensure $chart $template)
    print $"ok    ($chart): https://artifacthub.io/packages/helm/(ah-repo-name $chart)/($chart) \(repository ($id)\)"
  }
}

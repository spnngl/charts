#!/usr/bin/env nu
# Register published charts on Artifact Hub (one AH repository per OCI chart)
# and push the AH metadata artifact (artifacthub-repo.yml carrying the
# repositoryID, which enables the Verified Publisher badge). Idempotent.
#   nu tooling/release/artifacthub.nu <chart>...     specific charts
#   nu tooling/release/artifacthub.nu --all           every published chart
# Env: AH_API_KEY_ID, AH_API_KEY_SECRET (skips with a warning when absent).
# Needs `oras` logged in to the registry.

use ../crdgen/config.nu [OCI_BASE OCI_HOST_PATH OWNER REPO_ROOT]
use ../crdgen/exec.nu [run-checked]

const AH_API = "https://artifacthub.io/api/v1"
const METADATA_LAYER_TYPE = "application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml"
const PAGE_SIZE = 60 # AH API maximum `limit`

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
# Parsed response body: untyped external data.
def ah-search [query: record]: nothing -> any {
  let nonce = (date now | format date %s%f)
  ah-get $"/repositories/search?($query | insert nonce $nonce | url build-query)"
}

# Every AH repository of the API key's user. One paginated listing rather
# than one search per chart, which trips the AH rate limit (HTTP 429).
def list-repositories []: nothing -> list<record> {
  let alias = (ah-get "/users/profile" | get -o alias)
  if ($alias | is-empty) {
    error make {msg: "Artifact Hub /users/profile returned no alias: check AH_API_KEY_ID and AH_API_KEY_SECRET"}
  }
  generate {|offset|
    let page = (ah-search {user: $alias, limit: $PAGE_SIZE, offset: $offset})
    if ($page | length) < $PAGE_SIZE { {out: $page} } else { {out: $page, next: ($offset + $PAGE_SIZE)} }
  } 0 | flatten
}

def find-repository [url: string]: nothing -> oneof<record, nothing> {
  ah-search {url: $url, limit: 10} | where url == $url | get 0?
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

# Register the AH repository of a chart. Returns it once AH lists it.
def register-repository [chart: string]: nothing -> record {
  let url = $"($OCI_BASE)/($chart)"
  print $"  registering ($url) as ($chart)"
  ah-post "/repositories/user" {kind: 0, name: (ah-repo-name $chart), display_name: $chart, url: $url}
  let created = (find-repository-retry $url)
  if $created == null {
    error make {msg: $"Artifact Hub repository for ($url) not found after creation"}
  }
  $created
}

# Digest of the metadata layer at <chart>:artifacthub.io, null when absent.
def pushed-metadata-digest [chart: string]: nothing -> oneof<string, nothing> {
  let r = (^oras manifest fetch $"($OCI_HOST_PATH)/($chart):artifacthub.io" | complete)
  if $r.exit_code != 0 { return null }
  $r.stdout | from json | get -o layers | default [] | where {|layer| $layer.mediaType? == $METADATA_LAYER_TYPE } | get -o 0.digest
}

# Push the AH metadata artifact (artifacthub-repo.yml) of a chart, unless the
# registry already holds the same content: a push always makes a new manifest
# (creation timestamp). Returns whether it pushed.
def push-metadata [chart: string, metadata: record]: nothing -> bool {
  let yaml = ($metadata | to yaml)
  if (pushed-metadata-digest $chart) == $"sha256:($yaml | hash sha256)" { return false }
  let dir = (mktemp -d -t ah.XXXXXX)
  $yaml | save -f ($dir | path join "artifacthub-repo.yml")
  try {
    run-checked $"oras push of Artifact Hub metadata for ($chart)" { cd $dir; ^oras push $"($OCI_HOST_PATH)/($chart):artifacthub.io" $"artifacthub-repo.yml:($METADATA_LAYER_TYPE)" } | ignore
  } finally { rm -rf $dir }
  true
}

# Register charts on Artifact Hub and push their metadata artifact.
def main [
  ...charts: string # charts to register (names from Chart.yaml)
  --all # register every chart under charts/
]: nothing -> nothing {
  if ($env.AH_API_KEY_ID? | default "" | is-empty) or ($env.AH_API_KEY_SECRET? | default "" | is-empty) {
    print "::warning::Artifact Hub secrets not set, skipping registration"
    return
  }
  let template = (open ($REPO_ROOT | path join "artifacthub-repo.yml"))
  let selected = (if $all {
    glob ($REPO_ROOT | path join "charts" "*" "Chart.yaml") | each {|f| open $f | get name } | sort
  } else if ($charts | is-empty) {
    error make {msg: "give chart names or --all"}
  } else { $charts })
  let repos = (list-repositories)
  for chart in $selected {
    let url = $"($OCI_BASE)/($chart)"
    let listed = ($repos | where url == $url | get 0?)
    # Listed on AH implies published: ask the registry only about the others.
    if $listed == null and not (is-published $chart) {
      print $"skip  ($chart): not published yet"
      continue
    }
    let id = (if $listed == null { register-repository $chart } else { $listed } | get repository_id)
    let metadata = (if (push-metadata $chart ($template | upsert repositoryID $id)) { "pushed" } else { "unchanged" })
    print $"ok    ($chart): https://artifacthub.io/packages/helm/(ah-repo-name $chart)/($chart) \(repository ($id), metadata ($metadata)\)"
  }
}

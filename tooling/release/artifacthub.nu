#!/usr/bin/env nu
# Ensure an Artifact Hub repository exists for a chart and push the AH metadata
# artifact (artifacthub-repo.yml with the repositoryID) next to the chart.
#   nu tooling/release/artifacthub.nu <chart-name>
# Env: AH_API_KEY_ID, AH_API_KEY_SECRET (skips with a warning when absent).

use ../crdgen/config.nu [OCI_BASE OCI_HOST_PATH OWNER]

const AH_API = "https://artifacthub.io/api/v1"

def headers []: nothing -> record {
  {"X-API-KEY-ID": $env.AH_API_KEY_ID, "X-API-KEY-SECRET": $env.AH_API_KEY_SECRET, "Content-Type": "application/json"}
}

# AH repository names: lowercase alphanumerics and dashes; keep ours predictable.
def ah-repo-name [chart: string]: nothing -> string {
  $"($OWNER)-($chart)"
}

def find-repository [url: string]: nothing -> any {
  let found = (http get -H (headers) $"($AH_API)/repositories/search?url=($url)&limit=10")
  $found | where url == $url | get 0?
}

def create-repository [chart: string, url: string]: nothing -> nothing {
  http post -H (headers) $"($AH_API)/repositories/user" {
    kind: 0
    name: (ah-repo-name $chart)
    display_name: $chart
    url: $url
  } | ignore
}

def main [chart: string]: nothing -> nothing {
  if ($env.AH_API_KEY_ID? | default "" | is-empty) or ($env.AH_API_KEY_SECRET? | default "" | is-empty) {
    print $"::warning::Artifact Hub secrets not set, skipping registration of ($chart)"
    return
  }
  let root = (^git rev-parse --show-toplevel | str trim)
  let url = $"($OCI_BASE)/($chart)"
  let existing = (find-repository $url)
  let repo = (if $existing == null {
    print $"Registering ($url) on Artifact Hub"
    create-repository $chart $url
    find-repository $url
  } else {
    $existing
  })
  if $repo == null {
    error make {msg: $"Artifact Hub repository for ($url) not found after creation"}
  }
  let template = (open ($root | path join "artifacthub-repo.yml"))
  let metadata = ($template | upsert repositoryID $repo.repository_id | to yaml)
  let dir = (mktemp -d -t ah.XXXXXX)
  $metadata | save -f ($dir | path join "artifacthub-repo.yml")
  cd $dir
  ^oras push $"($OCI_HOST_PATH)/($chart):artifacthub.io" --config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml artifacthub-repo.yml:application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml
  print $"Artifact Hub metadata pushed for ($chart) \(repository ($repo.repository_id)\)"
}

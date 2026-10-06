# Turn a manifest `sources[]` entry into a flat list of YAML documents (records).
# This is the only layout-specific step.

use exec.nu [run-checked]
use fetch.nu ["fetch release-asset"]

# Flatten one level of nesting (lists of documents per source), drop nulls and
# non-records (comment-only documents, scalars). Records are wrapped before
# `flatten` because `flatten` would otherwise explode their columns.
export def "docs normalize" []: list<any> -> list<record> {
  $in
  | each {|d| if ($d | describe -d).type == list { $d } else { [$d] } }
  | flatten
  | compact
  | where {|d| ($d | describe -d).type == record }
}

def read-yaml-file [file: path]: nothing -> list<any> {
  open --raw $file | from yaml --multiple list
}

# All YAML docs under a file or directory (recursive).
def read-yaml-path [root: path]: nothing -> list<any> {
  if ($root | path type) == "file" {
    read-yaml-file $root
  } else if ($root | path type) == "dir" {
    glob ($root | path join "**" "*.{yaml,yml}")
    | sort
    | each {|f| read-yaml-file $f }
    | flatten
  } else {
    error make {msg: $"source path does not exist: ($root)"}
  }
}

def render-git-path [source: record, repo_dir: path]: nothing -> list<any> {
  read-yaml-path ($repo_dir | path join $source.path)
}

def render-kustomize [source: record, repo_dir: path]: nothing -> list<any> {
  let dir = ($repo_dir | path join $source.path)
  run-checked $"kustomize build ($dir)" { ^kustomize build $dir } | from yaml --multiple list
}

def render-helm-template [source: record, repo_dir: path]: nothing -> list<any> {
  let chart = ($repo_dir | path join $source.chartPath)
  let values_file = (mktemp -t crdgen-values.XXXXXX.yaml)
  ($source | get -o values | default {}) | to yaml | save -f $values_file
  let templated = (
    try { run-checked $"helm template ($chart)" { ^helm template crdgen $chart -f $values_file --include-crds } } finally { rm -f $values_file }
    | from yaml --multiple list
  )
  let crds_dir = ($chart | path join "crds")
  let static = (if ($crds_dir | path exists) { read-yaml-path $crds_dir } else { [] })
  $templated | append $static
}

def render-release-asset [source: record, manifest: record, resolved: record]: nothing -> list<any> {
  let file = (fetch release-asset $manifest $resolved $source.asset)
  let archive_path = ($source | get -o archivePath)
  if ($file =~ '\.(tar\.gz|tgz)$') {
    let dir = (mktemp -d -t crdgen-extract.XXXXXX)
    ^tar -xzf $file -C $dir
    read-yaml-path ($dir | path join ($archive_path | default ""))
  } else if ($file =~ '\.zip$') {
    let dir = (mktemp -d -t crdgen-extract.XXXXXX)
    ^unzip -q $file -d $dir
    read-yaml-path ($dir | path join ($archive_path | default ""))
  } else {
    read-yaml-file $file
  }
}

# Render one source entry. Returns raw documents (not yet filtered).
export def "render source" [source: record, manifest: record, resolved: record, repo_dir: path]: nothing -> list<any> {
  match $source.kind {
    "git-path" => (render-git-path $source $repo_dir)
    "kustomize" => (render-kustomize $source $repo_dir)
    "helm-template" => (render-helm-template $source $repo_dir)
    "release-asset" => (render-release-asset $source $manifest $resolved)
    _ => { error make {msg: $"unknown source kind ($source.kind)"} }
  }
}

# Turn a manifest `sources[]` entry into a flat list of YAML documents (records).
# This is the only layout-specific step.
#
# Upstream content is untrusted and this step runs while `sync.yml` holds
# credentials. Never add `--enable-exec` / `--enable-alpha-plugins` to
# `kustomize build`, or `--post-renderer` to `helm template`. Files read from
# a checkout or archive must resolve (symlinks followed) inside it.

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

# All YAML docs under a file or directory (recursive). Every file must resolve
# inside `base`; checked before any file is opened.
def read-yaml-path [root: path, base: path]: nothing -> list<any> {
  let files = (match ($root | path type) {
    "file" => [$root]
    "dir" => (glob ($root | path join "**" "*.{yaml,yml}") | sort)
    _ => { error make {msg: $"source path does not exist: ($root)"} }
  })
  let base_real = ($base | path expand)
  for f in $files {
    if (try { $f | path expand | path relative-to $base_real; false } catch { true }) {
      error make {msg: $"($f) resolves outside ($base); upstream files must stay inside their checkout"}
    }
  }
  $files | each {|f| open --raw $f | from yaml --multiple list } | flatten
}

def render-git-path [source: record, repo_dir: path]: nothing -> list<any> {
  read-yaml-path ($repo_dir | path join $source.path) $repo_dir
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
  let static = (if ($crds_dir | path exists) { read-yaml-path $crds_dir $repo_dir } else { [] })
  $templated | append $static
}

def render-release-asset [source: record, manifest: record, resolved: record]: nothing -> list<any> {
  let file = (fetch release-asset $manifest $resolved $source.asset)
  let extracted = (mktemp -d -t crdgen-extract.XXXXXX)
  try {
    let inner = ($extracted | path join ($source | get -o archivePath | default ""))
    if ($file =~ '\.(tar\.gz|tgz)$') {
      run-checked $"tar -xzf ($file)" { ^tar -xzf $file -C $extracted } | ignore
      read-yaml-path $inner $extracted
    } else if ($file =~ '\.zip$') {
      run-checked $"unzip ($file)" { ^unzip -q $file -d $extracted } | ignore
      read-yaml-path $inner $extracted
    } else {
      read-yaml-path $file ($file | path dirname)
    }
  } finally { rm -rf ($file | path dirname) $extracted }
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

# Generator-side validation of an emitted chart (runs before ct in CI).

use config.nu *
use render.nu ["docs from-yaml" "docs normalize"]

def run-checked [cmd: closure, what: string]: nothing -> string {
  let out = (do $cmd | complete)
  if $out.exit_code != 0 {
    error make {msg: $"($what) failed:\n($out.stdout)\n($out.stderr)"}
  }
  $out.stdout
}

export def "validate helm-lint" [dir: path]: nothing -> nothing {
  run-checked { ^helm lint --strict $dir } $"helm lint ($dir)" | ignore
}

export def "validate helm-template" [dir: path, ...args: string]: nothing -> string {
  run-checked { ^helm template crdgen-validate $dir ...$args } $"helm template ($dir)"
}

# Strip what the chart injects so rendered output can be compared to sanitized input.
def strip-injected [doc: record]: nothing -> record {
  let patterns_l = ($INJECTED_LABEL_PATTERNS)
  let patterns_a = ($INJECTED_ANNOTATION_PATTERNS)
  let labels = ($doc.metadata | get -o labels | default {} | transpose k v | where {|r| not ($patterns_l | any {|p| $r.k =~ $p }) })
  let annotations = ($doc.metadata | get -o annotations | default {} | transpose k v | where {|r| not ($patterns_a | any {|p| $r.k =~ $p }) })
  let d = ($doc | reject -o metadata.labels metadata.annotations)
  let d = (if ($labels | is-empty) { $d } else { $d | upsert metadata.labels ($labels | transpose -rd) })
  if ($annotations | is-empty) { $d } else { $d | upsert metadata.annotations ($annotations | transpose -rd) }
}

def normalize [doc: record]: nothing -> record {
  let d = $doc
  let d = (if (($d.metadata | get -o labels | default {} | columns | is-empty)) { $d | reject -o metadata.labels } else { $d })
  if (($d.metadata | get -o annotations | default {} | columns | is-empty)) { $d | reject -o metadata.annotations } else { $d }
}

# Rendered CRDs must equal the sanitized input, modulo injected labels/annotations.
export def "validate round-trip" [dir: path, crds: list<record>]: nothing -> nothing {
  let rendered = (docs from-yaml (validate helm-template $dir) | docs normalize)
  if ($rendered | length) != ($crds | length) {
    error make {msg: $"($dir): rendered ($rendered | length) documents, expected ($crds | length)"}
  }
  let expected = ($crds | each {|c| normalize $c })
  for r in $rendered {
    let name = $r.metadata.name
    let want = ($expected | where metadata.name == $name)
    if ($want | is-empty) { error make {msg: $"($dir): rendered unexpected CRD ($name)"} }
    let got = (normalize (strip-injected $r))
    if $got != $want.0 {
      error make {msg: $"($dir): rendered CRD ($name) differs from sanitized input \(templating mangled it\)"}
    }
    # injected labels must all be present
    for l in ["helm.sh/chart" "app.kubernetes.io/name" "app.kubernetes.io/instance" "app.kubernetes.io/version" "app.kubernetes.io/managed-by"] {
      if ($r.metadata.labels | get -o $l) == null { error make {msg: $"($dir): CRD ($name) is missing label ($l)"} }
    }
    if ($r.metadata.annotations | get -o "helm.sh/resource-policy") != "keep" {
      error make {msg: $"($dir): CRD ($name) is missing helm.sh/resource-policy=keep with default values"}
    }
  }
}

# Values the schema must reject.
export def "validate schema-negative" [dir: path]: nothing -> nothing {
  for args in [["--set" "typo=1"] ["--set" "keepOnUninstall=notabool"] ["--set" "labels=string"]] {
    let out = (do { ^helm template crdgen-validate $dir ...$args } | complete)
    if $out.exit_code == 0 {
      error make {msg: $"($dir): values.schema.json accepted invalid values ($args | str join ' ')"}
    }
  }
}

# keepOnUninstall=false must drop the keep annotation; custom labels/annotations must land.
export def "validate values-behaviour" [dir: path]: nothing -> nothing {
  let rendered = (docs from-yaml (validate helm-template $dir "--set" "keepOnUninstall=false" "--set" "labels.team=a" "--set" "annotations.note=b") | docs normalize)
  for r in $rendered {
    if ($r.metadata.annotations | get -o "helm.sh/resource-policy") != null {
      error make {msg: $"($dir): keepOnUninstall=false still rendered helm.sh/resource-policy on ($r.metadata.name)"}
    }
    if ($r.metadata.labels | get -o team) != "a" or ($r.metadata.annotations | get -o note) != "b" {
      error make {msg: $"($dir): custom labels/annotations not rendered on ($r.metadata.name)"}
    }
  }
}

# Structural sanity of each CRD. (kubeconform cannot do this: the public
# kubernetes-json-schema set ships no CustomResourceDefinition schema. Full
# API-server validation happens in `ct install` against kind.)
export def "validate structure" [crds: list<record>]: nothing -> nothing {
  for c in $crds {
    let name = ($c | get -o metadata.name | default "<unnamed>")
    def need [cond: bool, what: string] {
      if not $cond { error make {msg: $"CRD ($name): ($what)"} }
    }
    need (($c | get -o spec.group | default "" | is-not-empty)) "spec.group missing"
    need (($c | get -o spec.names.kind | default "" | is-not-empty)) "spec.names.kind missing"
    need (($c | get -o spec.names.plural | default "" | is-not-empty)) "spec.names.plural missing"
    need (($c | get -o spec.scope) in ["Namespaced" "Cluster"]) "spec.scope must be Namespaced or Cluster"
    need ($name == $"($c.spec.names.plural).($c.spec.group)") "metadata.name must be <plural>.<group>"
    let versions = ($c | get -o spec.versions | default [])
    need (not ($versions | is-empty)) "spec.versions is empty"
    need (($versions | where {|v| ($v | get -o storage | default false) } | length) == 1) "exactly one storage version required"
    for v in $versions {
      need (($v | get -o schema.openAPIV3Schema) != null) $"version ($v.name) has no openAPIV3Schema"
    }
  }
}

def gzip-size [text: string]: nothing -> int {
  $text | ^gzip -c | ^wc -c | str trim | into int
}

# Projected Helm release Secret payload. Mirrors what Helm stores: a JSON release
# object whose chart templates/files are base64 strings, plus the rendered
# manifest, gzipped, then base64-encoded into Secret.data.release. Measured
# within 1% of a real release.
export def "validate size-budget" [dir: path]: nothing -> record<bytes: int, status: string> {
  let dir = ($dir | path expand)
  let b64 = {|f| {name: ($f | path relative-to $dir), data: (open --raw $f | encode base64)} }
  let templates = (glob ($dir | path join "templates" "*") --no-dir | sort | each $b64)
  let files = (glob ($dir | path join "**" "*") --no-dir | where {|f| ($f | path relative-to $dir) !~ '^(templates/|Chart\.yaml$|values\.yaml$)' } | sort | each $b64)
  let manifest = (validate helm-template $dir)
  let release = {
    name: "release-name"
    info: {status: "deployed"}
    chart: {
      metadata: (open ($dir | path join "Chart.yaml"))
      templates: $templates
      values: (open ($dir | path join "values.yaml"))
      files: $files
    }
    manifest: $manifest
    version: 1
    namespace: "release-namespace"
  }
  let bytes = ((gzip-size ($release | to json -r)) * 4 / 3 | math round | into int)
  let status = (if $bytes > $SIZE_BUDGET_FAIL { "fail" } else if $bytes > $SIZE_BUDGET_WARN { "warn" } else { "ok" })
  if $status == "fail" {
    error make {msg: $"($dir): projected release Secret ($bytes | into filesize) exceeds budget ($SIZE_BUDGET_FAIL | into filesize); Helm caps releases at 1 MiB"}
  }
  if $status == "warn" {
    print -e $"::warning::($dir): projected release Secret ($bytes | into filesize) above ($SIZE_BUDGET_WARN | into filesize)"
  }
  {bytes: $bytes, status: $status}
}

export def "validate chart" [dir: path, crds: list<record>]: nothing -> record {
  validate helm-lint $dir
  validate round-trip $dir $crds
  validate schema-negative $dir
  validate values-behaviour $dir
  validate structure $crds
  validate size-budget $dir
}

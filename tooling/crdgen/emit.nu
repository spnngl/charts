# Write a complete CRD chart directory from sanitized CRDs + metadata.

use config.nu *
use manifest.nu ["manifest gh-slug"]
use templatize.nu *

const STATIC_DIR = (path self static)
const SCHEMA_HEADER = "# yaml-language-server: $schema=https://json.schemastore.org/chart.json"

# --- helpers ------------------------------------------------------------------

def storage-version [crd: record]: nothing -> record {
  let versions = ($crd.spec.versions | default [])
  let storage = ($versions | where {|v| ($v | get -o storage | default false) })
  if ($storage | is-empty) { $versions | last } else { $storage.0 }
}

# First sentence of the storage version's schema description, single line, bounded.
def crd-description [crd: record]: nothing -> string {
  let desc = (storage-version $crd | get -o schema.openAPIV3Schema.description | default "")
  let one_line = ($desc | str replace -ra '\s+' ' ' | str trim)
  let first = ($one_line | split row '. ' | get 0 | str trim)
  let bounded = (if ($first | str length) > 200 { ($first | str substring 0..197) + "..." } else { $first })
  if ($bounded | is-empty) { $"($crd.spec.names.kind) custom resource" } else { $bounded }
}

# Only the JSON key counts: a description that mentions it has the quote escaped.
def uses-cel [crds: list<record>]: nothing -> bool {
  $crds | to json | str contains 'x-kubernetes-validations":'
}

export def "emit kube-version" [crds: list<record>]: nothing -> string {
  if (uses-cel $crds) { ">=1.25.0-0" } else { ">=1.16.0-0" }
}

def ah-crds-annotation [crds: list<record>]: nothing -> string {
  $crds
  | each {|c| {
      kind: $c.spec.names.kind
      version: (storage-version $c).name
      name: $c.metadata.name
      displayName: $c.spec.names.kind
      description: (crd-description $c)
    } }
  | to yaml
}

# {kind, path} of every source; `path` is the field SOURCE_PATH_FIELD names for its kind.
def source-paths [manifest: record]: nothing -> table<kind: string, path: string> {
  $manifest.sources | each {|s| {kind: $s.kind, path: ($s | get ($SOURCE_PATH_FIELD | get $s.kind))} }
}

# Source paths as shown in prose: a release asset is not a repository path.
def source-labels [manifest: record]: nothing -> list<string> {
  source-paths $manifest | each {|p| if $p.kind == "release-asset" { $"release asset ($p.path)" } else { $p.path } }
}

def upstream-tree-url [manifest: record, tag: string, path: string]: nothing -> string {
  $"($manifest.upstream.repo)/tree/($tag)/($path)"
}

# --- Chart.yaml ----------------------------------------------------------------

# Chart.yaml as a record, WITHOUT version and artifacthub.io/changes (added by `emit chart-yaml`).
export def "emit chart-record" [chart: record]: nothing -> record {
  let manifest = $chart.manifest
  let resolved = $chart.resolved
  let crds = $chart.crds
  let license = $chart.license
  let links = (
    [
      {name: "Upstream project", url: $manifest.upstream.homepage}
      {name: "Upstream repository", url: $manifest.upstream.repo}
    ]
    | append (source-paths $manifest | where kind != "release-asset" | each {|p| {name: $"Upstream CRD source \(($p.path)\)", url: (upstream-tree-url $manifest $resolved.tag $p.path)} })
    | append [
      {name: "Chart source", url: $"($REPO_URL)/tree/main/charts/($manifest.name)"}
      {name: "Verify signature and attestations", url: $"($REPO_URL)#verifying-what-you-install"}
    ]
  )
  let annotations = {
    "artifacthub.io/license": $license.spdx
    "artifacthub.io/crds": (ah-crds-annotation $crds)
    "artifacthub.io/links": ($links | to yaml)
    $"($ANNOTATION_PREFIX)/upstream-repo": $manifest.upstream.repo
    $"($ANNOTATION_PREFIX)/upstream-tag": $resolved.tag
    $"($ANNOTATION_PREFIX)/upstream-commit": $resolved.sha
  }
  {
    apiVersion: "v2"
    name: $manifest.name
    description: $manifest.description
    type: "application"
    appVersion: $resolved.appVersion
    kubeVersion: (emit kube-version $crds)
    home: $manifest.upstream.homepage
    ...(if $manifest.upstream.icon != null { {icon: $manifest.upstream.icon} } else { {} })
    sources: [$REPO_URL $manifest.upstream.repo]
    keywords: ["crds" ($manifest.name | str replace -r '-crds$' '')]
    maintainers: [{name: $OWNER, url: $"https://github.com/($OWNER)"}]
    annotations: $annotations
  }
}

# Final Chart.yaml text from the piped `emit chart-record` plus `v` ({version, changes}),
# keys in conventional order.
export def "emit chart-yaml" [v: record<version: string, changes: list<string>>]: record -> string {
  let chart_record = $in
  let ordered = (
    {apiVersion: $chart_record.apiVersion, name: $chart_record.name, description: $chart_record.description, type: $chart_record.type, version: $v.version, appVersion: $chart_record.appVersion}
    | merge ($chart_record | reject apiVersion name description type appVersion annotations)
    | insert annotations ($chart_record.annotations | insert "artifacthub.io/changes" ($v.changes | to yaml))
  )
  [
    $SCHEMA_HEADER
    "# GENERATED by tooling/crdgen from sources/<name>.yaml. Do not edit."
    ($ordered | to yaml)
  ] | str join "\n"
}

# --- values ---------------------------------------------------------------------

export def "emit values-schema" []: nothing -> string {
  {
    "$schema": "https://json-schema.org/draft-07/schema#"
    "$id": $"($REPO_URL)/values.schema.json"
    title: "CRD chart values"
    type: "object"
    additionalProperties: false
    properties: {
      annotations: {type: "object", additionalProperties: {type: "string"}, description: "Extra annotations added to every CRD."}
      labels: {type: "object", additionalProperties: {type: "string"}, description: "Extra labels added to every CRD."}
      keepOnUninstall: {type: "boolean", description: "Add helm.sh/resource-policy: keep so CRDs survive helm uninstall."}
    }
  } | to json --indent 2 | $"($in)\n"
}

# --- NOTICE / README ----------------------------------------------------------

export def "emit notice" [chart: record]: nothing -> string {
  let manifest = $chart.manifest
  let resolved = $chart.resolved
  let license = $chart.license
  let ours = [
    $"The CustomResourceDefinition manifests under templates/ were copied from"
    $"  ($manifest.upstream.repo)"
    $"at tag ($resolved.tag) \(commit ($resolved.sha)\), path\(s\): (source-labels $manifest | str join ', ')"
    $"and modified by ($REPO_URL): Helm labels, annotations and templating were"
    $"added; server-side metadata and upstream Helm release metadata were removed."
    ...(if $manifest.transform.stripDocs { ["Field-level schema documentation (descriptions, titles, examples) was removed."] } else { [] })
    $"Upstream license: ($license.spdx) \(see LICENSE in this directory\)."
    ""
  ]
  let upstream_notice = (if $license.notice_text == null { [] } else { [($license.notice_text | str trim) "" "----" ""] })
  $upstream_notice | append $ours | str join "\n"
}

def crd-table [crds: list<record>]: nothing -> list<string> {
  let rows = ($crds | each {|c|
    let storage = (storage-version $c).name
    let versions = ($c.spec.versions | each {|v|
      let served = ($v | get -o served | default false)
      let label = (if $v.name == $storage { $"**($v.name)**" } else { $v.name })
      if $served { $label } else { $"~~($label)~~" }
    } | str join ", ")
    $"| `($c.metadata.name)` | ($c.spec.names.kind) | ($c.spec.group) | ($c.spec.scope) | ($versions) |"
  })
  [
    "| CRD | Kind | Group | Scope | Versions |"
    "|-----|------|-------|-------|----------|"
  ] | append $rows
}

export def "emit readme" [
  chart: record
  --oversized # projected release above SIZE_BUDGET_CAP (see `validate size-budget`)
]: nothing -> string {
  let manifest = $chart.manifest
  let resolved = $chart.resolved
  let crds = $chart.crds
  let dropped = $chart.dropped
  let license = $chart.license
  let name = $manifest.name
  let oci = $"($OCI_BASE)/($name)"
  let slug = (manifest gh-slug $manifest)
  let crd_names = ($crds | get metadata.name | str join " ")
  let paths = (source-labels $manifest | each {|p| $"`($p)`" } | str join ", ")
  let conflicts = ($manifest.conflictsWith | each {|c| $"`($c)`" } | str join ", ")
  let release = ($name | str replace -r '-crds$' '')
  [
    $"# ($name)"
    ""
    "<!-- GENERATED by tooling/crdgen. Do not edit. -->"
    ""
    $"($manifest.description)."
    ""
    $"CRDs are copied (if $manifest.transform.stripDocs { '' } else { 'verbatim ' })from [($slug)]\(($manifest.upstream.repo)\)"
    $"at tag [`($resolved.tag)`]\(($manifest.upstream.repo)/tree/($resolved.tag)\) \(commit `($resolved.sha)`\),"
    $"path\(s\) ($paths), and rendered as regular Helm templates so that"
    "`helm upgrade` updates them \(Helm's own `crds/` directory never upgrades\)."
    ""
    ...(if $manifest.transform.stripDocs {
      [
        "Field-level schema documentation \(descriptions, titles, examples\) is stripped so the Helm release fits"
        "Helm's 1 MiB release Secret: validation is unchanged, but `kubectl explain` shows field"
        "types only. Refer to the upstream documentation for field descriptions."
        ""
      ]
    } else { [] })
    ...(if not ($manifest.conflictsWith | is-empty) {
      [
        $"> **Warning:** this chart defines the same CRD names as ($conflicts). Install only one of them on a cluster."
        ""
      ]
    } else { [] })
    "## Install"
    ""
    ...(if $oversized {
      [
        "> **Too large for Helm's default storage.** Helm stores each release in one Secret"
        "> \(or ConfigMap\), capped at 1 MiB; this chart's release exceeds it. Use the SQL"
        "> storage driver \(PostgreSQL\):"
        ""
        "```sh"
        "export HELM_DRIVER=sql"
        "export HELM_DRIVER_SQL_CONNECTION_STRING='postgresql://<user>:<password>@<host>:5432/<db>'"
        $"helm upgrade --install ($release) ($oci) --version <version> --history-max=1"
        "```"
        ""
      ]
    } else {
      [
        "```sh"
        $"helm install ($release) ($oci) --version <version>"
        "```"
        ""
      ]
    })
    "Chart `version` equals the upstream version it ships; `appVersion` is always the exact upstream version."
    $"Installing requires Kubernetes (emit kube-version $crds | str replace '-0' '')."
    ""
    "### Already have these CRDs?"
    ""
    "If the CRDs were installed by the operator chart or `kubectl apply`, Helm refuses with"
    "\"rendered manifests contain a resource that already exists\". Either let Helm adopt them:"
    ""
    "```sh"
    $"helm install ($release) ($oci) --version <version> --take-ownership   # Helm >= 3.17"
    "```"
    ""
    "or, on older Helm, hand them over first \(replace `<release>` and `<namespace>`\):"
    ""
    "```sh"
    $"kubectl annotate crd ($crd_names) \\"
    "  meta.helm.sh/release-name=<release> meta.helm.sh/release-namespace=<namespace> --overwrite"
    $"kubectl label crd ($crd_names) \\"
    "  app.kubernetes.io/managed-by=Helm --overwrite"
    "```"
    ""
    "## Values"
    ""
    "| Key | Type | Default | Description |"
    "|-----|------|---------|-------------|"
    "| `annotations` | object | `{}` | Extra annotations added to every CRD. |"
    "| `labels` | object | `{}` | Extra labels added to every CRD. |"
    "| `keepOnUninstall` | bool | `true` | Add `helm.sh/resource-policy: keep` so CRDs \(and all their custom resources\) survive `helm uninstall`. |"
    ""
    "Unknown keys are rejected \(`values.schema.json`\)."
    ""
    "## CRDs"
    ""
    ...(crd-table $crds)
    ""
    "Bold = storage version, ~~struck~~ = not served."
    ""
    ...(if not ($dropped | is-empty) {
      [
        "## Not included"
        ""
        "Upstream ships these alongside the CRDs; this chart intentionally contains"
        "CustomResourceDefinitions only:"
        ""
        ...($dropped | each {|d| $"- `($d)`" })
        ""
      ]
    } else { [] })
    "## Verify"
    ""
    "```sh"
    $"REF=($OCI_HOST_PATH)/($name):<version>"
    "cosign verify \\"
    $"  --certificate-identity-regexp '($COSIGN_IDENTITY_REGEXP)' \\"
    $"  --certificate-oidc-issuer ($COSIGN_OIDC_ISSUER) \\"
    "  $REF"
    "cosign verify-attestation --type spdxjson \\"
    $"  --certificate-identity-regexp '($COSIGN_IDENTITY_REGEXP)' \\"
    $"  --certificate-oidc-issuer ($COSIGN_OIDC_ISSUER) \\"
    "  $REF"
    $"gh attestation verify oci://$REF --owner ($OWNER)"
    "```"
    ""
    "## License and attribution"
    ""
    $"The CRD manifests are the work of the ($slug) project,"
    $"licensed under ($license.spdx) \(copy in [`LICENSE`]\(./LICENSE\), modification statement in [`NOTICE`]\(./NOTICE\)\)."
    $"Chart scaffolding is Apache-2.0, \u{00a9} ($OWNER). Generated by [spnngl/charts]\(($REPO_URL)\);"
    "updates are automated, please report problems there rather than upstream."
    ""
  ]
  | str join "\n"
}

# --- orchestration ---------------------------------------------------------------

# Write everything except Chart.yaml into `dir` (which is created empty).
# values.yaml, ci/ci-values.yaml, .helmignore and templates/_helpers.tpl come
# from static/, so editing those files changes every chart. .helmignore holds
# the standard `helm create` patterns plus `ci/`: ct reads ci/*-values.yaml from
# the chart directory, but the packaged chart (and the release) does not need it.
export def "emit chart-files" [dir: path, chart: record]: nothing -> nothing {
  if ($dir | path exists) { rm -rf $dir }
  mkdir ($dir | path join "templates") ($dir | path join "ci")
  for c in $chart.crds {
    templatize crd $c $chart.manifest.name | save -f ($dir | path join "templates" $"($c.metadata.name).yaml")
  }
  open --raw ($STATIC_DIR | path join "_helpers.tpl") | templatize helpers $chart.manifest.name | save -f ($dir | path join "templates" "_helpers.tpl")
  cp ($STATIC_DIR | path join "values.yaml") ($dir | path join "values.yaml")
  emit values-schema | save -f ($dir | path join "values.schema.json")
  cp ($STATIC_DIR | path join "ci-values.yaml") ($dir | path join "ci" "ci-values.yaml")
  $chart.license.license_text | save -f ($dir | path join "LICENSE")
  emit notice $chart | save -f ($dir | path join "NOTICE")
  emit readme $chart | save -f ($dir | path join "README.md")
  cp ($STATIC_DIR | path join "helmignore") ($dir | path join ".helmignore")
}

#!/usr/bin/env nu
# Unit tests for crdgen. No network (kubeconform is skipped via CRDGEN_OFFLINE).
# Needs `helm` on PATH for the templating tests.
#   nu tooling/crdgen/tests/run.nu

use std/assert
use ../manifest.nu *
use ../resolve.nu [parse-tags "resolve allowed"]
use ../version.nu ["version decide"]
use ../fetch.nu ["license detect"]
use ../render.nu *
use ../filter.nu *
use ../sanitize.nu *
use ../dedupe.nu *
use ../templatize.nu *
use ../emit.nu *
use ../validate.nu *

const FIXTURES = (path self | path dirname | path join "fixtures")
const NO_TRANSFORM = {include: [], exclude: [], patches: [], stripDocs: false}

def fixture-docs [layout: string]: nothing -> list<record> {
  render source {kind: "git-path", path: $layout} {} {} $FIXTURES | docs normalize
}

def expect-error [body: closure, pattern: string] {
  let failed = (try { do $body; false } catch {|e| assert ($e.msg =~ $pattern) $"error '($e.msg)' does not match /($pattern)/"; true })
  assert $failed "expected an error, got none"
}

def tests []: nothing -> list<record<name: string, run: closure>> {
  [
    {name: "resolve allowed", run: {
      assert (resolve allowed "1.6.2" "1.7.0" "minor")
      assert (not (resolve allowed "1.6.2" "2.0.0" "minor"))
      assert (not (resolve allowed "1.6.2" "1.7.0" "patch"))
      assert (resolve allowed "1.6.2" "2.0.0" "all")
      expect-error { resolve allowed "1.6.2" "1.7.0" "bogus" } "unknown allow policy"
    }}
    {name: "parse-tags: ascending semver order, drops non-matching tags", run: {
      let text = ["aaa\trefs/tags/v1.2.0" "bbb\trefs/tags/v1.10.0" "ccc\trefs/tags/nightly" "ddd\trefs/tags/v0.9.9" "eee\trefs/tags/v01.2.0"] | str join "\n"
      let tags = ($text | parse-tags '^v(\d+\.\d+\.\d+)$')
      assert equal ($tags | get appVersion) ["0.9.9" "1.2.0" "1.10.0"]
      assert equal ($tags | get tag) ["v0.9.9" "v1.2.0" "v1.10.0"]
      assert equal ($tags | get sha) ["ddd" "aaa" "bbb"]
    }}
    {name: "version decide: new, upstream, tooling, none", run: {
      let chart_record = {name: "x-crds", appVersion: "1.2.3", annotations: {"charts.spnngl.io/upstream-tag": "v1.2.3"}}
      let previous = {
        name: "x-crds", version: "1.2.3", appVersion: "1.2.3"
        annotations: {"charts.spnngl.io/upstream-tag": "v1.2.3", "artifacthub.io/changes": "- Initial release\n"}
      }
      let resolved = {tag: "v1.2.3", appVersion: "1.2.3", sha: "abc"}
      let base = {previous: $previous, resolved: $resolved, chart_record: $chart_record, files_changed: false}
      # new chart
      assert equal (version decide ($base | upsert previous null)) {version: "1.2.3", trigger: "new", changes: ["Initial release, CRDs from upstream v1.2.3"]}
      # upstream bump above the previous chart version
      let up = (version decide ($base | upsert resolved {tag: "v1.3.0", appVersion: "1.3.0", sha: "def"}))
      assert equal $up {version: "1.3.0", trigger: "upstream", changes: ["Upstream CRDs updated from v1.2.3 to v1.3.0"]}
      # upstream bump at or below the previous chart version: PATCH+1
      let ahead = ($previous | upsert version "1.5.2")
      assert equal (version decide ($base | upsert previous $ahead | upsert resolved {tag: "v1.5.0", appVersion: "1.5.0", sha: "def"})).version "1.5.3"
      let equal_ = ($previous | upsert version "1.5.0")
      assert equal (version decide ($base | upsert previous $equal_ | upsert resolved {tag: "v1.5.0", appVersion: "1.5.0", sha: "def"})).version "1.5.1"
      # tooling change: files differ, or Chart.yaml fields differ
      let tooling = (version decide ($base | upsert files_changed true))
      assert equal $tooling {version: "1.2.4", trigger: "tooling", changes: ["Chart regenerated with updated tooling (upstream unchanged at v1.2.3)"]}
      assert equal (version decide ($base | upsert chart_record ($chart_record | upsert description "new"))).trigger "tooling"
      # nothing changed: previous version and change note are kept
      assert equal (version decide $base) {version: "1.2.3", trigger: "none", changes: ["Initial release"]}
    }}
    {name: "version decide: previous tag falls back to appVersion", run: {
      let previous = {name: "x-crds", version: "1.0.0", appVersion: "1.0.0", annotations: {}}
      let d = (version decide {
        previous: $previous
        resolved: {tag: "v1.1.0", appVersion: "1.1.0", sha: "abc"}
        chart_record: {name: "x-crds"}
        files_changed: false
      })
      assert equal $d.changes ["Upstream CRDs updated from 1.0.0 to v1.1.0"]
    }}
    {name: "license detect", run: {
      assert equal (license detect "Apache License\n Version 2.0, January 2004") "Apache-2.0"
      assert equal (license detect "MIT License\nPermission is hereby granted, free of charge, to any person") "MIT"
      assert equal (license detect "Redistribution and use in source and binary forms ... Neither the name of") "BSD-3-Clause"
      assert equal (license detect "Redistribution and use in source and binary forms ...") "BSD-2-Clause"
      assert equal (license detect "GNU GENERAL PUBLIC LICENSE") null
    }}
    {name: "manifest validate rejects bad input", run: {
      let good = {
        name: "x-crds", description: "d"
        upstream: {repo: "https://github.com/o/r", homepage: "https://h", license: "Apache-2.0"}
        version: {tagPattern: '^v(\d+\.\d+\.\d+)$', current: "v1.0.0"}
        sources: [{kind: "git-path", path: "p"}]
      }
      manifest validate $good "x-crds"
      expect-error { manifest validate $good "y-crds" } "must equal the file name"
      expect-error { manifest validate ($good | upsert upstream.license "GPL-3.0") "x-crds" } "allowlist"
      expect-error { manifest validate ($good | upsert version.current "1.0.0") "x-crds" } "does not match"
      expect-error { manifest validate ($good | upsert sources [{kind: "ftp"}]) "x-crds" } "kind must be one of"
      expect-error { manifest validate ($good | upsert transform {patches: [{op: add, path: "/a"}]}) "x-crds" } "reason"
      expect-error { manifest validate ($good | upsert name "x") "x" } "must end with '-crds'"
      expect-error { manifest validate ($good | upsert transform {stripDocs: "yes"}) "x-crds" } "stripDocs.*boolean"
      manifest validate ($good | upsert transform {stripDocs: true}) "x-crds"
      let d = (manifest defaults $good)
      assert equal $d.transform $NO_TRANSFORM
      assert equal $d.version.allow "all"
    }}
    {name: "render git-path dir: multi-doc, comment docs, recursion", run: {
      let docs = (fixture-docs "layout-a")
      assert equal ($docs | length) 3
      assert equal ($docs | get metadata.name | sort) ["bars.example.io" "bazs.example.io" "foos.example.io"]
    }}
    {name: "filter keeps CRDs only and reports dropped kinds", run: {
      let f = (filter crds (fixture-docs "layout-c") $NO_TRANSFORM)
      assert equal ($f.crds | get metadata.name) ["foos.example.io"]
      assert equal $f.dropped ["admissionregistration.k8s.io/v1/ValidatingAdmissionPolicy" "apps/v1/Deployment" "v1/Namespace"]
    }}
    {name: "filter include/exclude and zero-CRD failure", run: {
      let docs = (fixture-docs "layout-a")
      let only = (filter crds $docs ($NO_TRANSFORM | upsert include ['^bar'])).crds
      assert equal ($only | get metadata.name) ["bars.example.io"]
      let f = (filter crds $docs ($NO_TRANSFORM | upsert exclude ['foos\.']))
      assert equal ($f.crds | length) 2
      assert ($f.dropped | any {|d| $d =~ "foos.example.io" })
      expect-error { filter crds $docs ($NO_TRANSFORM | upsert include ['^nothing$']) } "zero CRDs"
    }}
    {name: "sanitize strips noise and Helm-isms, keeps the rest", run: {
      let foo = (fixture-docs "layout-a" | where metadata.name == "foos.example.io" | get 0)
      let s = (sanitize crd $foo $NO_TRANSFORM)
      assert equal ($s | get -o status) null
      assert equal ($s.metadata | get -o creationTimestamp) null
      assert equal ($s.metadata.labels) {"example.io/component": "controller"}
      assert equal ($s.metadata.annotations) {"controller-gen.kubebuilder.io/version": "v0.16.0"}
      assert equal ($s.spec) $foo.spec
    }}
    {name: "sanitize applies patches", run: {
      let foo = (fixture-docs "layout-a" | where metadata.name == "foos.example.io" | get 0)
      let t = ($NO_TRANSFORM | upsert patches [
        {op: replace, path: "/spec/versions/0/served", value: false, reason: "test"}
        {op: remove, path: "/spec/names/listKind", reason: "test"}
        {op: add, path: "/metadata/labels/added", value: "yes", reason: "test"}
      ])
      let s = (sanitize crd $foo $t)
      assert equal $s.spec.versions.0.served false
      assert equal ($s.spec.names | get -o listKind) null
      assert equal $s.metadata.labels.added "yes"
    }}
    {name: "sanitize stripDocs removes schema docs, keeps fields and data", run: {
      let w = (fixture-docs "strip-docs" | get 0)
      assert equal (sanitize crd $w $NO_TRANSFORM) $w
      let s = (sanitize crd $w ($NO_TRANSFORM | upsert stripDocs true))
      let v = $s.spec.versions.0
      assert equal $v.additionalPrinterColumns.0 {name: "Ready", type: "string", jsonPath: ".status.ready"}
      assert equal $v.schema.openAPIV3Schema {
        type: "object"
        description: "Widget is a thing."
        properties: {
          spec: {
            type: "object"
            default: {description: "data, not documentation"}
            properties: {
              description: {type: "string"}
              tags: {type: "array", items: {type: "string"}}
              labels: {type: "object", additionalProperties: {type: "string"}}
              choice: {allOf: [{type: "string"}]}
              open: {type: "object", additionalProperties: true}
            }
          }
        }
      }
    }}
    {name: "dedupe merges identical, fails on conflict", run: {
      let a = (fixture-docs "layout-a")
      assert equal (dedupe crds ($a | append $a) | length) 3
      expect-error { dedupe crds (fixture-docs "conflict") } "foos.example.io"
    }}
    {name: "template escape: whole brace runs become string literals", run: {
      assert equal (template escape "a {{ x }} b") 'a {{ "{{" }} x {{ "}}" }} b'
      assert equal (template escape "x{}}y") 'x{{ "{}}" }}y'
      assert equal (template escape "{a}{}") "{a}{}"
    }}
    {name: "templatize escapes braces and injects template blocks", run: {
      let foo = (sanitize crd (fixture-docs "layout-a" | where metadata.name == "foos.example.io" | get 0) $NO_TRANSFORM)
      let t = (templatize crd $foo "x-crds")
      assert ($t | str contains '{{ "{{" }} .Values.templated {{ "}}" }}')
      assert ($t | str contains "\"labels\": {\n{{ include \"x-crds.crdLabels\" . | trimPrefix \"{\" | trimSuffix \"}\" }},\n")
      assert ($t | str contains "\"annotations\": {\n{{- with include \"x-crds.crdAnnotations\" . | trimPrefix \"{\" | trimSuffix \"}\" }}{{ . }},{{- end }}\n")
      assert (not ($t | str contains "__CRDGEN"))
      let bar = (fixture-docs "layout-a" | where metadata.name == "bars.example.io" | get 0)
      let tb = (templatize crd $bar "x-crds")
      assert ($tb | str contains "\"metadata\": {\n{{- with include \"x-crds.crdAnnotations\" . | fromJson }}\"annotations\": {{ toJson . }},{{- end }}\n")
    }}
    {name: "emit kube-version derives from CEL usage", run: {
      let docs = (fixture-docs "layout-a")
      assert equal (emit kube-version $docs) ">=1.25.0-0"
      assert equal (emit kube-version ($docs | where metadata.name != "foos.example.io")) ">=1.16.0-0"
    }}
    {name: "end to end: emitted chart renders back to sanitized input (helm)", run: {
      let manifest = (manifest defaults {
        name: "fixture-crds", description: "Fixture"
        upstream: {repo: "https://github.com/example/fixture", homepage: "https://example.io", license: "Apache-2.0"}
        version: {tagPattern: '^v(\d+\.\d+\.\d+)$', current: "v1.0.0"}
        sources: [{kind: "git-path", path: "layout-a"}]
      })
      let resolved = {tag: "v1.0.0", appVersion: "1.0.0", sha: "0000000000000000000000000000000000000000"}
      let license = {license_text: "Apache License Version 2.0", spdx: "Apache-2.0", notice_text: null}
      let f = (filter crds (fixture-docs "layout-a") $NO_TRANSFORM)
      let crds = (dedupe crds ($f.crds | each {|c| sanitize crd $c $NO_TRANSFORM }))
      let dir = (mktemp -d -t crdgen-test.XXXXXX | path join "fixture-crds")
      emit chart-files $dir $manifest $resolved $crds $f.dropped $license
      let rec = (emit chart-record $manifest $resolved $crds $license)
      emit chart-yaml $rec "1.0.0" ["Initial release"] | save -f ($dir | path join "Chart.yaml")
      let chart = (open ($dir | path join "Chart.yaml"))
      assert equal $chart.sources.0 "https://github.com/spnngl/charts"
      assert equal $chart.kubeVersion ">=1.25.0-0"
      assert ($chart.annotations."artifacthub.io/crds" | str contains "kind: Foo")
      assert (not ("artifacthub.io/signKey" in $chart.annotations))
      validate chart $dir $crds
      assert equal (validate size-budget $dir).status "ok"
      assert ((open --raw ($dir | path join ".helmignore")) | lines | any {|l| $l == "ci/" })
      let readme = (open --raw ($dir | path join "README.md"))
      assert ($readme | str contains "kubectl annotate crd bars.example.io bazs.example.io foos.example.io")
      assert ($readme | str contains "~~**v1beta1**~~")
      assert (not ($readme | str contains "HELM_DRIVER=sql"))
      assert ($readme | str contains "--certificate-oidc-issuer https://token.actions.githubusercontent.com")
      assert (not ($readme | str contains "cosign.pub"))
      let big = (emit readme $manifest $resolved $crds $f.dropped $license --oversized)
      assert ($big | str contains "helm upgrade --install fixture oci://ghcr.io/spnngl/charts/fixture-crds --version <version> --history-max=1")
      assert ($readme | str contains "copied verbatim from")
      assert (not ((emit notice $manifest $resolved $license) | str contains "schema documentation"))
      let stripped = ($manifest | upsert transform.stripDocs true)
      let sreadme = (emit readme $stripped $resolved $crds $f.dropped $license)
      assert ($sreadme | str contains "CRDs are copied from")
      assert ($sreadme | str contains "`kubectl explain` shows field")
      assert ((emit notice $stripped $resolved $license) | str contains "Field-level schema documentation (descriptions, titles, examples) was removed.")
      rm -rf ($dir | path dirname)
    }}
  ]
}

def main []: nothing -> nothing {
  $env.CRDGEN_OFFLINE = "1"
  let results = (tests | each {|t|
    let r = (try { do $t.run; {name: $t.name, ok: true, error: ""} } catch {|e| {name: $t.name, ok: false, error: $e.msg} })
    print $"(if $r.ok { 'PASS' } else { 'FAIL' })  ($r.name)"
    if not $r.ok { print $"      ($r.error)" }
    $r
  })
  let failed = ($results | where ok == false | length)
  print $"\n($results | length) tests, ($failed) failed"
  if $failed > 0 { exit 1 }
}

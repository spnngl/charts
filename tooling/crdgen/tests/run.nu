#!/usr/bin/env nu
# Unit tests for crdgen. No network (kubeconform is skipped via CRDGEN_OFFLINE).
# Needs `helm` on PATH for the templating tests.
#   nu tooling/crdgen/tests/run.nu

use std/assert
use ../manifest.nu *
use ../semver.nu *
use ../fetch.nu ["license detect"]
use ../render.nu *
use ../filter.nu *
use ../sanitize.nu *
use ../dedupe.nu *
use ../templatize.nu *
use ../emit.nu *
use ../validate.nu *

const FIXTURES = (path self | path dirname | path join "fixtures")
const NO_TRANSFORM = {include: [], exclude: [], patches: []}

def fixture-docs [layout: string]: nothing -> list<record> {
  render source {kind: "git-path", path: $layout} {} {} $FIXTURES | docs normalize
}

def expect-error [body: closure, pattern: string] {
  let failed = (try { do $body; false } catch {|e| assert ($e.msg =~ $pattern) $"error '($e.msg)' does not match /($pattern)/"; true })
  assert $failed "expected an error, got none"
}

def tests []: nothing -> list<record<name: string, run: closure>> {
  [
    {name: "semver cmp/bump/allowed", run: {
      assert equal (semver cmp "1.2.3" "1.10.0") (-1)
      assert equal (semver cmp "2.0.0" "1.99.99") 1
      assert equal (semver cmp "v1.2.3" "1.2.3") 0
      assert equal (semver bump-patch "1.6.2") "1.6.3"
      assert (semver allowed "1.6.2" "1.7.0" "minor")
      assert (not (semver allowed "1.6.2" "2.0.0" "minor"))
      assert (not (semver allowed "1.6.2" "1.7.0" "patch"))
      assert equal (["1.10.0" "1.2.0" "0.9.9"] | semver sort) ["0.9.9" "1.2.0" "1.10.0"]
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
    {name: "dedupe merges identical, fails on conflict", run: {
      let a = (fixture-docs "layout-a")
      assert equal (dedupe crds ($a | append $a) | length) 3
      expect-error { dedupe crds (fixture-docs "conflict") } "foos.example.io"
    }}
    {name: "templatize escapes braces and injects template blocks", run: {
      let foo = (sanitize crd (fixture-docs "layout-a" | where metadata.name == "foos.example.io" | get 0) $NO_TRANSFORM)
      let t = (templatize crd $foo "x-crds")
      assert ($t | str contains '{{ "{{" }} .Values.templated {{ "}}" }}')
      assert ($t | str contains '{{- include "x-crds.labels" . | nindent 4 }}')
      assert ($t | str contains '{{- with (include "x-crds.crdAnnotations" . | fromYaml) }}')
      assert (not ($t | str contains "__CRDGEN"))
      let bar = (fixture-docs "layout-a" | where metadata.name == "bars.example.io" | get 0)
      let tb = (templatize crd $bar "x-crds")
      assert ($tb | str contains "  annotations:\n    {{- toYaml . | nindent 4 }}")
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
      let license = {license_path: "LICENSE", license_text: "Apache License Version 2.0", spdx: "Apache-2.0", notice_text: null}
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

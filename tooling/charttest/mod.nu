#!/usr/bin/env nu
# Render tests for hand-written charts.
#
# A chart opts in with `charts/<name>/tests/cases/<case>.yaml`:
#   values: {...}                  # passed to `helm template`
#   expect: {error: "<substring>"} # optional: the render must fail with it
#   ruleTests: {...}               # optional: promtool unit tests, without `rule_files`
# A passing case is rendered, compared with `tests/golden/<case>.yaml`,
# schema-checked (kubeconform) and linted (kube-linter, repo config). Its
# PrometheusRules are checked with `promtool check rules`, then run against
# `ruleTests` (`promtool test rules`, job and namespace labels as rendered).
# Quote series values YAML reads as numbers: `values: "0x70"`, not hex 112.
#
#   nu tooling/charttest/mod.nu run cloudflared
#   nu tooling/charttest/mod.nu run --all --update   # rewrite golden files
#
# CHARTTEST_OFFLINE=1 skips kubeconform (it fetches schemas).
#
# Charts render with version, appVersion, image tags and digests pinned (see
# `pin-chart`), so goldens do not change when Renovate or a release bumps them.

use ../crdgen/config.nu [REPO_ROOT]
use ../crdgen/exec.nu [run-checked]

# Schemas for the CRDs the charts render (ServiceMonitor, PodMonitor, VPA).
const CRD_CATALOG = 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# Version, appVersion, image tag and image digest every chart renders with.
const PINNED_VERSION = "0.0.0"
const PINNED_DIGEST = "sha256:0000000000000000000000000000000000000000000000000000000000000000"

# Copy `chart_dir` into `tmp_dir` with version, appVersion, the tag of every
# `image: <repo>:<tag>@sha256:...` entry and every digest of Chart.yaml pinned;
# returns the copy (same basename: same release name).
def pin-chart [chart_dir: path, tmp_dir: path]: nothing -> path {
  let copy = ($tmp_dir | path join ($chart_dir | path basename))
  cp -r $chart_dir $copy
  let chart_file = ($copy | path join "Chart.yaml")
  open --raw $chart_file
  | str replace -r '(?m)^version:.*$' $"version: ($PINNED_VERSION)"
  | str replace -r '(?m)^appVersion:.*$' $"appVersion: \"($PINNED_VERSION)\""
  | str replace -a -r '(image: [^\s@]*:)[^:@\s/]+(@sha256:)' $"${1}($PINNED_VERSION)${2}"
  | str replace -a -r 'sha256:[0-9a-f]{64}' $PINNED_DIGEST
  | save -f $chart_file
  $copy
}

# Run `helm template` for `chart_dir` with `values`; never throws.
def render [chart_dir: path, values: record]: nothing -> record<exit_code: int, stdout: string, stderr: string> {
  let name = ($chart_dir | path basename)
  let tmp = (mktemp --tmpdir --suffix .json)
  try {
    # JSON, not YAML: nushell writes `Off` unquoted and Helm reads it as a boolean.
    $values | to json | save -f $tmp
    let out = (^helm template $name $chart_dir --namespace $name -f $tmp | complete)
    # Helm versions differ on blank lines between documents: drop them so goldens do not depend on the Helm version.
    $out | update stdout ($out.stdout | lines | where {|l| ($l | str trim) != "" } | str join "\n" | $in + "\n")
  } finally { rm -f $tmp }
}

# Check a failed render against the case's expected error substring.
def check-error [rendered: record, expected: string]: nothing -> nothing {
  if $rendered.exit_code == 0 { error make {msg: $"expected the render to fail with '($expected)', it succeeded"} }
  if not ($rendered.stderr | str contains $expected) {
    error make {msg: $"expected the error to contain '($expected)', got:\n($rendered.stderr | str trim)"}
  }
}

# Check a successful render against golden, kubeconform and kube-linter (or rewrite golden).
def check-render [rendered: record, golden: path, update: bool]: nothing -> nothing {
  if $rendered.exit_code != 0 { error make {msg: $"helm template failed:\n($rendered.stderr | str trim)"} }
  let out = $rendered.stdout
  if $update {
    $out | save -f $golden
  } else if not ($golden | path exists) {
    error make {msg: $"missing golden file ($golden), run with --update"}
  } else if (open --raw $golden) != $out {
    error make {msg: $"render differs from ($golden), review the diff and run with --update"}
  }
  if ($env.CHARTTEST_OFFLINE? | is-empty) {
    run-checked "kubeconform" { $out | ^kubeconform -strict -summary -ignore-missing-schemas -schema-location default -schema-location $CRD_CATALOG } | ignore
  }
  run-checked "kube-linter" { $out | ^kube-linter lint --config ($REPO_ROOT | path join ".kube-linter.yaml") - } | ignore
}

# Check the PrometheusRules of a render with promtool, then run `rule_tests`
# (a promtool test file without `rule_files`) against them.
def check-rules [out: string, rule_tests: oneof<record, nothing>]: nothing -> nothing {
  let groups = ($out | from yaml --multiple list | where {|doc| $doc.kind? == "PrometheusRule" } | each {|doc| $doc.spec.groups } | flatten)
  if ($groups | is-empty) {
    if $rule_tests != null { error make {msg: "the case has ruleTests but renders no PrometheusRule"} }
    return
  }
  let tmp = (mktemp -d --tmpdir)
  try {
    # JSON is YAML, and nushell's `to yaml` leaves some strings unquoted (see `render`).
    let rules = ($tmp | path join "rules.json")
    {groups: $groups} | to json | save -f $rules
    run-checked "promtool check rules" { ^promtool check rules $rules } | ignore
    if $rule_tests != null {
      let tests = ($tmp | path join "tests.json")
      $rule_tests | merge {rule_files: [$rules]} | to json | save -f $tests
      run-checked "promtool test rules" { ^promtool test rules $tests } | ignore
    }
  } finally { rm -rf $tmp }
}

# Run every case of one chart; returns one result per case.
def run-chart [chart_dir: path, update: bool]: nothing -> list<record<name: string, ok: bool, error: string>> {
  let tmp = (mktemp -d --tmpdir)
  try {
    let pinned = (pin-chart $chart_dir $tmp)
    glob ($chart_dir | path join "tests" "cases" "*.yaml") | sort | each {|file|
      let name = ($file | path parse | get stem)
      let case = (open $file)
      let result = (try {
        let rendered = (render $pinned $case.values)
        match ($case.expect?.error?) {
          null => {
            check-render $rendered ($chart_dir | path join "tests" "golden" $"($name).yaml") $update
            check-rules $rendered.stdout ($case.ruleTests?)
          }
          $expected => { check-error $rendered $expected }
        }
        {ok: true, error: ""}
      } catch {|e| {ok: false, error: $e.msg} })
      print $"(if $result.ok { 'PASS' } else { 'FAIL' })  ($chart_dir | path basename)/($name)"
      if not $result.ok { print $"      ($result.error | str replace -a "\n" "\n      ")" }
      {name: $name, ...$result}
    } | collect # finish every render before the finally removes the copy
  } finally { rm -rf $tmp }
}

# Render-test the cases of a hand-written chart.
def "main run" [
  chart?: string # chart directory name under charts/
  --all # test every chart that has tests/cases
  --update # rewrite golden files instead of comparing
]: nothing -> nothing {
  let dirs = if $all {
    glob ($REPO_ROOT | path join "charts" "*" "tests" "cases") | each {|d| $d | path dirname | path dirname } | sort
  } else if $chart != null {
    [($REPO_ROOT | path join "charts" $chart)]
  } else {
    error make {msg: "give a chart name or --all"}
  }
  let results = ($dirs | each {|d| run-chart $d $update } | flatten)
  let failed = ($results | where ok == false | length)
  print $"\n($results | length) cases, ($failed) failed"
  if $failed > 0 { exit 1 }
}

def main []: nothing -> nothing {
  print "usage: nu tooling/charttest/mod.nu run <chart> | run --all [--update]"
}

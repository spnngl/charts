#!/usr/bin/env nu
# Render tests for hand-written charts.
#
# A chart opts in with `charts/<name>/tests/cases/<case>.yaml`:
#   values: {...}                  # passed to `helm template`
#   expect: {error: "<substring>"} # optional: the render must fail with it
# A passing case is rendered, compared with `tests/golden/<case>.yaml`,
# schema-checked (kubeconform) and linted (kube-linter, repo config).
#
#   nu tooling/charttest/mod.nu run cloudflared
#   nu tooling/charttest/mod.nu run --all --update   # rewrite golden files
#
# CHARTTEST_OFFLINE=1 skips kubeconform (it fetches schemas).

use ../crdgen/config.nu [REPO_ROOT]
use ../crdgen/exec.nu [run-checked]

# Schemas for the CRDs the charts render (ServiceMonitor, PodMonitor, VPA).
const CRD_CATALOG = 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# Run `helm template` for `chart_dir` with `values`; never throws.
def render [chart_dir: path, values: record]: nothing -> record<exit_code: int, stdout: string, stderr: string> {
  let name = ($chart_dir | path basename)
  let tmp = (mktemp --tmpdir --suffix .json)
  try {
    # JSON, not YAML: nushell writes `Off` unquoted and Helm reads it as a boolean.
    $values | to json | save -f $tmp
    ^helm template $name $chart_dir --namespace $name -f $tmp | complete
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

# Run every case of one chart; returns one result per case.
def run-chart [chart_dir: path, update: bool]: nothing -> list<record<name: string, ok: bool, error: string>> {
  glob ($chart_dir | path join "tests" "cases" "*.yaml") | sort | each {|file|
    let name = ($file | path parse | get stem)
    let case = (open $file)
    let result = (try {
      let rendered = (render $chart_dir $case.values)
      match ($case.expect?.error?) {
        null => { check-render $rendered ($chart_dir | path join "tests" "golden" $"($name).yaml") $update }
        $expected => { check-error $rendered $expected }
      }
      {ok: true, error: ""}
    } catch {|e| {ok: false, error: $e.msg} })
    print $"(if $result.ok { 'PASS' } else { 'FAIL' })  ($chart_dir | path basename)/($name)"
    if not $result.ok { print $"      ($result.error | str replace -a "\n" "\n      ")" }
    {name: $name, ...$result}
  }
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

# Run external commands whose failure must stop the run.

# Run `cmd` and return its stdout. A non-zero exit fails with `what` plus the
# command's stdout and stderr. Keep `what` short: the sync failure issue shows
# the last 60 lines of stderr.
export def run-checked [what: string, cmd: closure]: nothing -> string {
  let out = (do $cmd | complete)
  if $out.exit_code != 0 {
    let detail = ([$out.stdout $out.stderr] | each {|s| $s | str trim } | where {|s| $s != "" } | str join "\n")
    error make {msg: $"($what) failed:\n($detail)"}
  }
  $out.stdout
}

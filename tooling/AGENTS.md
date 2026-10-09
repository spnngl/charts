# tooling/ — AGENTS.md

Rules for editing the Nushell code under `tooling/`. The root
[`AGENTS.md`](../AGENTS.md) still applies. What the code is (modules, data
flow, records, entry points, env vars): [`ARCHITECTURE.md`](./ARCHITECTURE.md);
read it before changing a module boundary, a shared record or a command's
output.

Sources: the Nushell [style guide](https://www.nushell.sh/book/style_guide.html)
and the [nushell-pro](https://github.com/hustcer/nushell-pro) review and
security checklists. The project rules below take precedence.

## Before pushing

Done when all four pass:

1. `nu --ide-check 10 <file>` for every touched file: zero diagnostics (CI
   enforces this).
2. `nu tooling/crdgen/tests/run.nu`.
3. `nu tooling/crdgen/mod.nu regen --all`, then `check --all`.
   A refactor produces **zero** chart diff. Any diff is a behaviour change:
   every changed byte bumps that chart's PATCH and ships a release. So it is
   either a bug, or an intended change in its own `fix(tooling)` /
   `feat(tooling)` commit, together with the regenerated charts.
4. `release/*.nu` have no tests, so run them by hand. `plan.nu` runs locally
   with `gh` authenticated. Run `verify.nu` against one published version.
   `artifacthub.nu` must still print the skip warning when `AH_*` are unset.

## Structure

- One pipeline step per file in `crdgen/`. `mod.nu` orchestrates and holds no
  step logic. A new step means a new file, a row in the root ARCHITECTURE
  pipeline table, and a row in the Modules table of `ARCHITECTURE.md`.
- Only `render.nu` behaves differently per source kind. Elsewhere, a kind
  only selects which field holds its path (`SOURCE_PATH_FIELD` in
  `config.nu`). Only `templatize.nu` rewrites serialized text; every other
  module works on records.
- Keep the pure modules pure (`filter`, `sanitize`, `dedupe`, `templatize`,
  `emit` except `emit chart-files`, `config`). I/O belongs in
  `exec`, `resolve`, `fetch`, `render`, `version`, `validate`, `mod`.
- Put decisions in pure commands (`version decide`, `parse-tags`,
  `resolve allowed`) and keep git and network calls in thin wrappers, so tests
  need neither.
- Repo identity and policy constants go in `config.nu`. Use `REPO_ROOT` from
  `config.nu` for repo paths, and pass `-C $REPO_ROOT` to `git` commands that
  use repo-relative paths (`REPO_ROOT` comes from `path self`;
  `git rev-parse --show-toplevel` depends on the current directory).
- Per-upstream quirks go in the manifest (`include`, `exclude`, `patches`
  with a `reason:`); `sanitize.nu` rules stay generic.
- Export only what another module or a test imports.
- Prefer a Nushell built-in over a hand-written helper (`into semver`,
  `from yaml --multiple list`, `url build-query`).

## Nushell style

- Names: kebab-case for commands and flags, snake_case for variables and
  parameters, SCREAMING_SNAKE_CASE for constants and environment variables.
  Use full words (`manifest`, not `mf`).
- A command name starts with its module name, written as a quoted
  subcommand (`"emit readme"`); modules are imported with `use x.nu *`.
  Historical exceptions: `render.nu` (`docs …`), `fetch.nu`
  (`license detect`), `sanitize.nu` (`strip-docs …`, `pointer …`,
  `patch …`), `templatize.nu` (`template escape`), `resolve.nu`
  (`parse-tags`), `exec.nu` (`run-checked`).
- Every `def` has typed parameters and an `input -> output` signature. Write
  "value or null" as `oneof<T, nothing>`. Use `any` only for truly untyped
  external data, and say so in the comment.
- At most 2 positional parameters on exported commands, and on any command
  you write or rewrite. Pass the rest as one typed record, as pipeline input,
  or as flags.
- Every exported command has a `#` comment above it saying what it returns
  or guarantees. Every parameter and flag of a `main` command has an inline
  `#` comment, because that text is the CLI help.
- Use immutable `let` and pipelines; `for` only for side effects; `match` to
  dispatch on one value. No `mut`.
- External data (upstream CRDs, API responses): use optional access (`?` /
  `get -o`) and validate. Manifests are already defaulted: read their fields
  directly.
- Type checks: `($v | describe -d).type == record`, not string surgery on
  `describe`.
- Strings: raw strings (`r#'…'#`) for regexes and static multi-line content.
  `$"…"` with `\(` when you need a literal parenthesis: a literal `(` inside
  `$'…'` silently interpolates.
- Large static file bodies live in `crdgen/static/`, not in code. Editing
  them changes every chart.

## External commands, errors, output

- Call `^cmd` with each argument as a separate value. Never build command
  strings, and never use `sh -c`, `nu -c`, `source $var` or `run-external`
  on computed names.
- When failure matters: `run-checked "<what>" { ^cmd … }` (`crdgen/exec.nu`).
  It returns stdout and fails with `<what>` plus the command's output. Keep
  `<what>` short and name the chart, manifest or path. When failure is an
  expected answer (does this ref exist?): `| complete`, check `exit_code` only.
- `error make {msg}`: name the chart, manifest or path, and tell the reader
  what to do.
- Human progress goes to stdout (`ok` / `DRIFT` lines), machine output
  through `--json`, GitHub annotations to stderr (`print -e $"::warning::…"`).

## Files, temp dirs, paths

- Create temp files and dirs with the built-in `mktemp` (`-d` for dirs).
  Remove them in `try { … } finally { rm -rf … }`, or hand ownership to the
  caller explicitly.
- `rm -rf` only paths built from validated names under a known root:
  `charts/<name>`, the clone cache, your own temp dirs.
- Files read from an upstream checkout or archive must resolve inside it.
  Check with `path expand` plus `path relative-to`, not `str starts-with`.
- Upstream content is untrusted and `sync.yml` handles it while holding
  credentials: `kustomize build` runs without `--enable-exec` or
  `--enable-alpha-plugins`, `helm template` without `--post-renderer`.

## Secrets

- Only `release/artifacthub.nu` reads secrets (`AH_*`), and only into
  in-process HTTP headers: never in argv, printed, or written to disk.
- `crdgen/` and the PR path stay secret-free.

## Tests

- Add a fixture and a test when you add a renderer, a sanitizer rule or a
  filter rule, and a test for every fix that changes what the generator
  accepts or emits (for example the CEL detection and the path-escape check).
- Tests stay offline and remove their temp dirs in `try { … } finally { … }`.
- Test layout and fixtures: `ARCHITECTURE.md` (Tests).

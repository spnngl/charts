# tooling/ — AGENTS.md

Rules for editing the Nushell code under `tooling/`. The root
[`AGENTS.md`](../AGENTS.md) still applies. Read
[`ARCHITECTURE.md`](./ARCHITECTURE.md) first.

Sources: the Nushell [style guide](https://www.nushell.sh/book/style_guide.html)
and the [nushell-pro](https://github.com/hustcer/nushell-pro) review and
security checklists. The project rules below take precedence.

## Before pushing

1. `nu --ide-check 10 <file>` for every touched file: zero diagnostics (CI
   enforces this).
2. `nu tooling/crdgen/tests/run.nu`.
3. `nu tooling/crdgen/mod.nu regen --all`, then `check --all`.
   A refactor must produce **zero** chart diff. Any diff is a behaviour change:
   either a bug, or an intended change that goes in its own commit together
   with the regenerated charts (the generator bumps each affected chart's
   PATCH).
4. `release/*.nu` have no tests, so run them by hand. `plan.nu` runs locally
   with `gh` authenticated. Run `verify.nu` against one published version.
   `artifacthub.nu` must still print the skip warning when `AH_*` are unset.

## Structure

- One pipeline step per file in `crdgen/`. `mod.nu` orchestrates and holds no
  step logic. A new step means a new file, a row in the root ARCHITECTURE
  pipeline table, and a row in the Modules table of `ARCHITECTURE.md`.
- Only `render.nu` behaves differently per source kind. Elsewhere, a kind
  only selects which field holds its path (`SOURCE_PATH_FIELD` in `config.nu`). Only `templatize.nu` rewrites
  serialized text.
- Keep the pure modules pure (`filter`, `sanitize`, `dedupe`, `templatize`,
  `emit` except `emit chart-files`, `config`). I/O belongs in
  `exec`, `resolve`, `fetch`, `render`, `version`, `validate`, `mod`.
- Repo identity and policy constants go in `config.nu`. Tool versions go in
  `versions.toml` only.
- Per-upstream quirks go in the manifest, not in code.
- Export only what another module or a test imports.
- Prefer deleting code. Prefer a Nushell built-in over a hand-written helper.

## Nushell style

- Names: kebab-case for commands and flags, snake_case for variables and
  parameters, SCREAMING_SNAKE_CASE for constants and environment variables.
  Use full words (`manifest`, not `mf`).
- Every `def` has typed parameters and an `input -> output` signature. Write
  "value or null" as `oneof<T, nothing>`. Use `any` only for truly untyped
  external data, and say so in the comment.
- At most 2 positional parameters on exported commands, and on any command
  you write or rewrite. Pass the rest as one typed record, as pipeline input,
  or as flags.
- Every exported command has a `#` comment above it (mandatory) saying what
  it returns or guarantees. Every parameter and flag of a `main` command has
  an inline `#` comment, because that text is the CLI help.
- Use immutable `let` and pipelines. `for` is only for side effects. No
  `mut`. Use `match` to dispatch on one value.
- External data (upstream CRDs, API responses): use optional access (`?` /
  `get -o`) and validate. Manifests are already defaulted, so do not
  re-default their fields.
- Type checks: `($v | describe -d).type == record`, not string surgery on
  `describe`.
- Strings: use raw strings (`r#'…'#`) for regexes and static multi-line
  content. Use `$"…"` with `\(` when you need a literal parenthesis. Never put
  a literal `(` inside `$'…'`: it silently interpolates.
- Do not embed large static file bodies in code as lists of quoted lines.

## External commands and errors

- Call `^cmd` with each argument as a separate value. Never build command
  strings, and never use `sh -c`, `nu -c`, `source $var` or `run-external`
  on computed names.
- When failure matters: `run-checked "<what>" { ^cmd … }` (`crdgen/exec.nu`).
  It returns stdout and fails with `<what>` plus the command's output. Keep
  `<what>` short and name the chart, manifest or path. When failure is an
  expected answer (does this ref exist?): `| complete`, check `exit_code` only.
- Error messages name the chart, manifest or path, and tell the reader what
  to do.
- CI annotations: `print -e $"::warning::…"`.

## Files, temp dirs, paths

- Create temp files and dirs with the built-in `mktemp` (`-d` for dirs).
  Remove them in `try { … } finally { rm -rf … }`, or hand ownership to the
  caller explicitly.
- Only `rm -rf` paths built from validated names under a known root:
  `charts/<name>`, the clone cache, your own temp dirs.
- Files read from an upstream checkout or archive must resolve inside it.
  Check with `path expand` plus `path relative-to`, never `str starts-with`.
- Never add `--enable-exec` or `--enable-alpha-plugins` to
  `kustomize build`, and never add `--post-renderer` to `helm template`.
  Upstream content is untrusted, and `sync.yml` handles it while holding
  credentials.

## Secrets

- Only `release/artifacthub.nu` reads secrets (`AH_*`). It passes them in
  in-process HTTP headers: never in argv, never printed, never written to
  disk.
- `crdgen/` and the PR path stay secret-free.

## Tests

- Add a fixture and a test when you add a renderer, a sanitizer rule or a
  filter rule.
- Tests stay offline. `run.nu` sets `CRDGEN_OFFLINE=1`.
- A test is a `{name, run}` entry in `tests`. Use `std/assert` and
  `expect-error`.

## Generated output

- Any byte change in a generated chart bumps that chart's PATCH and ships a
  release. Never change output as a side effect of a refactor.
- Output changes get their own `fix(tooling)` / `feat(tooling)` commit,
  together with the regenerated charts.

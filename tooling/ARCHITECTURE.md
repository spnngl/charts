# tooling/ — ARCHITECTURE

Code-level view of the Nushell tooling. The product behaviour lives in the root
[`ARCHITECTURE.md`](../ARCHITECTURE.md) and is not repeated here: the manifest
schema, what each pipeline step does and when it fails, the chart version rule,
the release-size budget, the workflows and the trust model.

## Layout

```
versions.toml            pinned tool versions; read by .github/actions/setup-tools
                         with bash, so keep it flat: `name = "x.y.z"` under [tools]
crdgen/mod.nu            CLI (`main regen|check|sync|notice|list`); orchestration only
crdgen/config.nu         repo identity + policy constants + `REPO_ROOT` (the one repo root); no logic
crdgen/exec.nu           `run-checked`: run an external command, fail with its output
crdgen/<step>.nu         one pipeline step per file (see Modules)
crdgen/tests/run.nu      unit + end-to-end tests; fixtures/ holds one directory per case
release/plan.nu          which charts still need publishing (release.yml)
release/artifacthub.nu   Artifact Hub registration + metadata push (release.yml)
release/verify.nu        post-publish smoke test, runs the documented verify commands (release.yml)
```

## Entry points

| Command | Called by | Writes |
|---------|-----------|--------|
| `crdgen/mod.nu regen <name>…\|--all [--skip-validate] [--json]` | humans | `charts/<name>/` (replaced as a whole), `NOTICE` |
| `crdgen/mod.nu check <name>…\|--all` | `pr.yml` | nothing; fails on drift or a naming-invariant violation |
| `crdgen/mod.nu sync <name>…\|--all [--dry-run] [--json]` | `sync.yml` | the `current:` line of `sources/<name>.yaml` (layout kept), `charts/<name>/`, `NOTICE` |
| `crdgen/mod.nu notice` | `regen`, `sync` | `NOTICE` |
| `crdgen/mod.nu list [--json]` | humans | nothing |
| `crdgen/tests/run.nu` | `pr.yml` | temp dirs only |
| `release/plan.nu [--all]` | `release.yml` | JSON matrix on stdout, log on stderr |
| `release/artifacthub.nu <chart>…\|--all` | `release.yml` | Artifact Hub API, `oras push <chart>:artifacthub.io` |
| `release/verify.nu <chart> <version>` | `release.yml` | nothing |

Workflows parse these outputs. Change them only together with the workflow:

| Output | Consumer | Fields read |
|--------|----------|-------------|
| `sync --json` rows | `sync.yml` | `name`, `to`, `from`, `version` |
| `sync` stderr | `sync.yml` failure issue | last 60 lines, as written |
| README `## Not included` section, `- ` items | `sync.yml` PR body | the item lines |
| `release/plan.nu` stdout | `release.yml` matrix | `name`, `version`, `dir` |

`regen --json` and `list --json` are for humans.

## Data flow (`generate` in `mod.nu`)

```
sources/<name>.yaml
  └ manifest load            validated record, optional fields defaulted
resolve current              resolved {tag, appVersion, sha}
fetch repo                   repo_dir: cached shallow clone, HEAD checked against sha
fetch license                license {license_text, spdx, notice_text}
render source  (per source)  list<any>   ─┐
docs normalize                list<record> ┘ flat documents
filter crds                  {crds, dropped}
sanitize crd   (per CRD)     list<record>
dedupe crds                  list<record>, sorted by metadata.name
emit chart-files             <tmp>/<name>/  everything except Chart.yaml
emit chart-record            Chart.yaml record without version/changes
validate size-budget         {bytes, status}; README re-emitted with --oversized if needed
version compute              {version, trigger, changes} against the base ref
emit chart-yaml              Chart.yaml
validate chart               lint, round-trip, schema, values, structure, kubeconform
```

After `generate`, `regen` and `sync` move the temp dir to `charts/<name>/`.
`check` instead compares git blob hashes against the committed directory.

Ordering constraint: the README depends on the size estimate, and
`version compute` hashes the directory. So the README must be final before
`version compute` runs, and the size is estimated with a provisional
Chart.yaml. The comment in `generate` explains this.

## Modules

| Module | Exports (callers) | Uses | External tools | Pure |
|--------|-------------------|------|----------------|------|
| `config.nu` | constants | — | — | yes |
| `exec.nu` | `run-checked` (all modules that run a command that must succeed, and the release scripts) | — | — | no (runs the given closure) |
| `manifest.nu` | `manifest validate/defaults/load/list/gh-slug` | config | — | reads files |
| `resolve.nu` | `resolve tags/current/allowed/latest`, `parse-tags` | — | `git ls-remote` | no |
| `fetch.nu` | `fetch repo/release-asset/license`, `license detect` | manifest | `git clone/rev-parse`, `gh release download` | no |
| `render.nu` | `render source`, `docs normalize` | fetch | `kustomize`, `helm`, `tar`, `unzip` | no |
| `filter.nu` | `filter crds` | — | — | yes |
| `sanitize.nu` | `sanitize crd/strip-injected` | config | — | yes |
| `dedupe.nu` | `dedupe crds` | — | — | yes |
| `templatize.nu` | `templatize crd/helpers`, `template escape` | — | — | yes |
| `emit.nu` | `emit *` | config, templatize | — | yes, except `emit chart-files` (writes the chart dir) |
| `version.nu` | `version base-ref/previous/tree-hashes/dir-hashes/decide/compute` | config | `git` | no |
| `validate.nu` | `validate chart/size-budget` | config, exec, render, sanitize | `helm`, `kubeconform`, `gzip`, `tar`, `git` | no |

The release scripts use only `crdgen/config.nu` and `crdgen/exec.nu`. Tests import the step
modules directly. They never import `mod.nu`.

## Shared records

These records cross module boundaries. Treat their shapes as interfaces.

- **manifest**: the schema from the root ARCHITECTURE.md. After
  `manifest defaults`, the optional fields always exist (`upstream.icon` may be
  null, `version.allow`, `conflictsWith`, and `transform.{include, exclude,
  patches, stripDocs}`). Downstream code reads them directly and never
  re-defaults them.
- **resolved**: `{tag, appVersion, sha}`. `appVersion` is capture group 1 of
  `tagPattern`. `sha` is the peeled commit.
- **license**: `{license_text, spdx, notice_text}`.
  `notice_text` may be null.
- **crd**: a plain `CustomResourceDefinition` record. Fields that came from
  upstream are external data, so read their optional fields with `get -o` /
  `?`.

## Conventions

- **Naming:** a command name starts with its module name, written as a quoted
  subcommand (`"emit readme"`), and modules are imported with `use x.nu *`.
  Historical exceptions: `render.nu` (`docs …`), `fetch.nu`
  (`license detect`), `sanitize.nu` (`strip-docs …`, `pointer …`,
  `patch …`), `templatize.nu` (`template escape`), `resolve.nu`
  (`parse-tags`), `exec.nu` (`run-checked`).
- **Text:** only `templatize.nu` rewrites serialized text (sentinels,
  `{{`/`}}` escaping). `emit.nu` assembles README and NOTICE from line lists.
  Every other module works on records.
- **Errors:** `error make {msg}` with enough context to act on: chart,
  manifest, path, and the external command's output. When an external
  failure matters: `run-checked` (`exec.nu`). When failure is an expected
  answer (probing whether a ref or tag exists): `| complete`, then check only
  `exit_code`.
- **Output:** human progress goes to stdout (`ok` / `DRIFT` lines). Machine
  output goes through `--json`. GitHub annotations (`::warning::…`) go to
  stderr.

## Environment variables

| Variable | Read by | Effect |
|----------|---------|--------|
| `CRDGEN_CACHE` | `fetch.nu` | clone cache dir (default `$nu.cache-dir/crdgen`) |
| `CRDGEN_BASE_REF` | `version.nu` | base ref for versioning (default `origin/main`, then `main`) |
| `CRDGEN_OFFLINE` | `validate.nu` | non-empty: skip kubeconform (`tests/run.nu` sets it) |
| `CRDGEN_SCHEMA_LOCATION` | `validate.nu` | kubeconform schema-location template (e.g. local clone) |
| `CRDGEN_K8S_SCHEMA_VERSION` | `validate.nu` | override `k8s-json-schema` from `versions.toml` |
| `AH_API_KEY_ID`, `AH_API_KEY_SECRET` | `artifacthub.nu` | API auth; if unset, the script warns and skips |

By default, kubeconform reads schemas from the `master` branch of
`yannh/kubernetes-json-schema`, from the directory named after the
`k8s-json-schema` version in `versions.toml`. This is deliberate: the
Kubernetes version is the pin, and the repository is not pinned to a commit.
Use `CRDGEN_SCHEMA_LOCATION` for a fixed local copy.

## Filesystem

- Writes: `charts/<name>/`, `NOTICE`, `sources/<name>.yaml` (sync only).
- Cache: `$CRDGEN_CACHE/<host>__<owner>__<repo>@<tag>`. The HEAD is
  re-checked on every use. Delete the cache entry if upstream moved a tag.
- Temp: built-in `mktemp`, prefixes `crdgen-*`, `verify.*`, `ah.*`.

## Trust boundaries

- **Manifests and tooling code**: trusted. They are reviewed in PRs, and
  `pr.yml` runs PR code without secrets anyway.
- **Upstream content** (git checkout, release assets, `helm template` /
  `kustomize build` output): untrusted data. It is parsed into records and
  never executed. `kustomize build` runs without exec functions or plugins,
  and `helm template` without a post-renderer. `sync.yml` handles this content
  while holding GitHub App credentials.
- **Secrets**: only `artifacthub.nu` reads them (`AH_*`). They go into
  in-process HTTP headers. They are never in argv, never printed, never
  written to disk.

## Tests

- `tests/run.nu` holds a list of `{name, run}` closures and uses
  `std/assert` plus a local `expect-error`. It needs no network (it sets
  `CRDGEN_OFFLINE=1`) and needs `helm` on PATH.
- Fixtures:
  - `layout-a`: multi-doc files, comment-only docs, directory recursion.
  - `layout-c`: non-CRD kinds.
  - `conflict`: dedupe conflict.
  - `strip-docs`: schema documentation stripping.
- The end-to-end test emits a chart from fixtures and runs `validate chart`
  on it.
- The regression test for the whole generator is
  `crdgen/mod.nu check --all`: regeneration must be byte-identical to the
  committed charts.

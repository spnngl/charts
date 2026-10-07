# Contributing

## Ground rules

- `charts/*-crds/` is **generated**. Never edit it by hand; CI rejects drift.
  Edit `sources/<name>-crds.yaml` or `tooling/crdgen/`, then regenerate.
- Hand-written charts live in `charts/<name>/` without the `-crds` suffix.
- Conventional commits, CI-enforced on every PR commit. Types: `feat`, `fix`,
  `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`,
  `revert` (write reverts as `revert: <subject>`, not git'"'"'s default
  `Revert "..."`). Examples: `feat(<chart>): ...`, `fix(tooling): ...`.
- One concern per pull request.

## Prerequisites

Versions are pinned in `tooling/versions.toml`. Locally you need at least:
`nu` (nushell), `helm`, `kustomize`, `kubeconform`, `git`, `gzip`; for the full
CI experience also `ct` (chart-testing, with `yamllint` and `yamale`), `kind`,
`kube-linter`, `helm-docs`, `helm-schema`. Offline? `CRDGEN_OFFLINE=1` skips the kubeconform
step; `CRDGEN_SCHEMA_LOCATION` can point at a local clone of
yannh/kubernetes-json-schema.

## Adding a CRD chart

1. Find where the upstream keeps its CRDs at a release tag (a directory of
   files, a bundle, a kustomize base, a Helm chart, or a release asset).
2. Create `sources/<upstream>-crds.yaml` from an existing one. Field reference
   in `ARCHITECTURE.md`. `upstream.license` must be one of the allowlisted
   permissive licenses and must match the upstream `LICENSE`.
3. Generate and validate:

   ```sh
   nu tooling/crdgen/mod.nu regen <upstream>-crds
   ct lint --config ct.yaml --charts charts/<upstream>-crds
   ```

4. Read `charts/<upstream>-crds/README.md`: CRD count, versions, and the
   "Not included" list must make sense.
5. Optional but recommended: install it into a kind cluster
   (`kind create cluster && ct install --config ct.yaml --charts charts/<upstream>-crds`).
6. Commit the manifest **and** the generated chart together.

## Changing the generator

```sh
nu tooling/crdgen/tests/run.nu          # unit tests, no network
nu tooling/crdgen/mod.nu regen --all    # regenerate everything
nu tooling/crdgen/mod.nu check --all    # what CI runs: drift + invariants
```

Any output change bumps the affected charts' patch version automatically.
Commit tooling and regenerated charts in the same PR. Keep sanitizer rules
generic; per-upstream quirks belong in the manifest (`include`, `exclude`,
`patches` with a `reason`).

## Adding a hand-written chart

- `values.schema.json` is mandatory (`additionalProperties: false` recommended). Write
  `# @schema` blocks in `values.yaml` and generate it, never edit it by hand:
  `helm-schema -k title,default,required -c charts/<name>` (the Helm plugin
  `helm schema` takes the same flags). CI fails on drift.
- Provide `README.md.gotmpl` and run `helm-docs`; CI checks the README is current.
- Add `ci/*-values.yaml` scenarios for `ct install`; add `templates/tests/` for `helm test`.
- Add render tests when the chart has logic: `tests/cases/<case>.yaml` (values, optional
  expected error) and golden output, run by `nu tooling/charttest/mod.nu run <name>`
  (`--update` rewrites golden files; `CHARTTEST_OFFLINE=1` skips kubeconform).
- Bump `version` in `Chart.yaml` on every change (`ct lint` enforces it).
- Set `sources[0]` to `https://github.com/spnngl/charts` so GHCR links the package to this repo.

## Release

Merging to `main` publishes every chart whose `version` is not yet in GHCR.
Nothing to do by hand.

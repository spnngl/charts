# AGENTS.md

Helm charts published to `oci://ghcr.io/spnngl/charts`, in two kinds:
generated CRD charts (`charts/<x>-crds/`, built from `sources/<x>-crds.yaml`
by `tooling/crdgen`) and hand-written charts (`charts/<name>/`).

Read on demand:

- `ARCHITECTURE.md`: before changing a manifest field, generator output, a
  workflow, the release or signing.
- `tooling/AGENTS.md`: before editing anything under `tooling/`.
- Skills `add-crd-chart` (a `*-crds` chart) and `add-chart` (a hand-written
  chart, new or changed).

## Guardrails

- Generated charts change only through regeneration: edit
  `sources/<x>-crds.yaml` or `tooling/crdgen/`, then
  `nu tooling/crdgen/mod.nu regen --all`. CI fails on any drift.
- `charts/<x>-crds/` exists exactly when `sources/<x>-crds.yaml` does; the
  `-crds` suffix is reserved for generated charts.
- CRD charts ship `CustomResourceDefinition` objects only, with the same
  values interface everywhere: `annotations`, `labels`, `keepOnUninstall`.
- `version.current` in `sources/*.yaml` belongs to `sync.yml`; change it only
  when asked.
- Published chart versions are immutable: fix forward with a new version.
- Tool versions live only in `tooling/versions.toml`.
- GitHub Actions are pinned by commit SHA with a version comment.
- `PLAN*.md` and `*.key` stay local (git-ignored).
- English everywhere: code, comments, commits, docs.

## Before pushing

- `nu tooling/crdgen/mod.nu check --all`: manifests, naming invariant, drift.
- `nu tooling/charttest/mod.nu run --all`: render tests of hand-written charts.

## Commits and PRs

- Conventional commits, scope = chart name, `tooling`, `ci`, `docs` or
  `renovate`: `chore(external-dns-crds): sync CRDs to v0.23.0`,
  `fix(tooling): escape `}}` in descriptions`.
- One concern per PR. `sync/*` branches belong to the sync bot.
- Merge through branch protection, never around it.

## Security

- Repo secrets `APP_*` (sync GitHub App) and `AH_*` (Artifact Hub) stay in
  GitHub: out of logs, files and argv. Ask for a new secret only with the
  reason.
- Signing is cosign keyless (GitHub Actions OIDC): no signing key secret.
- `pr.yml` runs on fork PRs and stays secret-free.
- Suspected key or secret compromise: report it at once, follow
  `SECURITY.md`.

## When unsure

Delete code rather than add it. Prefer a manifest field over a code branch.
Ask before adding a tool, a workflow or a chart value.

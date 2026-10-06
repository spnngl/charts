# ARCHITECTURE

Helm charts repository. Two chart kinds, one release pipeline.

| Kind | Location | Source of truth | Versioning |
|------|----------|-----------------|------------|
| CRD charts | `charts/*-crds/` (generated) | `sources/*-crds.yaml` | automatic, tracks upstream |
| Hand-written charts | `charts/<name>/` | the chart itself | manual bump, CI-enforced |

Output for both: OCI chart at `oci://ghcr.io/spnngl/charts/<name>`, cosign
keyless signature, SBOM + SLSA provenance attestations, Artifact Hub listing.

## Layout

```
sources/<name>-crds.yaml   per-CRD-chart manifest (hand-written)
charts/<name>-crds/        generated chart; drift-checked in CI
charts/<name>/             hand-written chart; ci/*-values.yaml for ct; README.md.gotmpl for helm-docs
tooling/crdgen/            nushell generator, one file per pipeline step; `mod.nu` is the CLI
tooling/crdgen/tests/      fixtures + `run.nu` unit tests (no network)
tooling/release/           plan.nu (what to publish), artifacthub.nu, verify.nu (smoke test)
tooling/versions.toml      pinned tool versions, read by CI (.github/actions/setup-tools) and local runs
tooling/ARCHITECTURE.md    code-level view: modules, data flow, contracts, env vars (tooling/AGENTS.md: coding rules)
.github/workflows/pr.yml       validate, regen, drift-check, ct lint, ct install
.github/workflows/release.yml  package, push, sign, attest, Artifact Hub, smoke test
.github/workflows/sync.yml     scheduled upstream tracking, opens automerging PRs
.github/actions/setup-tools/   installs the pinned tool versions on runners
ct.yaml                    chart-testing config (lint + install)
renovate.json              our own dependency updates (tool pins, Actions SHAs, kind images)
.kube-linter.yaml          hand-written charts only
artifacthub-repo.yml       Artifact Hub metadata template; repositoryID injected at release
cosign.pub                 retired signing key, kept to verify versions signed before keyless
NOTICE                     generated: redistributed upstreams + licenses (no versions)
LICENSE, README.md, CONTRIBUTING.md, SECURITY.md, AGENTS.md
```

## CRD chart manifest (`sources/<name>-crds.yaml`)

```yaml
name: <name>-crds                       # == filename
description: <one line>
upstream:
  repo: https://github.com/<owner>/<repo>
  homepage: <url>
  icon: <url>                           # optional
  license: Apache-2.0                   # SPDX; allowlist: Apache-2.0, MIT, BSD-2-Clause, BSD-3-Clause
version:
  tagPattern: '^v(\d+\.\d+\.\d+)$'      # group 1 = appVersion
  allow: all | minor | patch            # which bumps sync may propose
  current: vX.Y.Z                       # edited by sync.yml only
sources:                                # >= 1; merged, deduped by metadata.name
  - kind: git-path       path: <file-or-dir>
  - kind: kustomize      path: <dir with kustomization.yaml>
  - kind: helm-template  chartPath: <dir>  values: {...}
  - kind: release-asset  asset: <name-or-regex>  archivePath: <optional>
conflictsWith: [<other-chart>]          # optional; README warning only
transform:
  include: []  exclude: []              # regex on metadata.name
  patches: []                           # JSON6902 + mandatory reason:
  stripDocs: false                      # optional; drop schema docs (see release-size budget)
```

## Generator pipeline (`tooling/crdgen`, nushell)

```
resolve → fetch → render → split → filter → sanitize → dedupe → templatize → emit → validate
```

| Step | Does | Fails when |
|------|------|-----------|
| resolve | tag → commit SHA | tag missing / not matching `tagPattern` |
| fetch | shallow clone at tag or `gh release download`; reads upstream LICENSE/NOTICE | license ≠ manifest |
| render | layout-specific: read files / `kustomize build` / `helm template` / extract asset → `list<record>` | renderer error |
| split | one record per YAML document | — |
| filter | keep `apiextensions.k8s.io/v1` `CustomResourceDefinition` only; apply include/exclude; log dropped kinds | zero CRDs |
| sanitize | drop `status`, `creationTimestamp`, server-side metadata, Helm labels/annotations; with `stripDocs`, drop schema `description`/`title`/`example`/`externalDocs` (all but each version's top-level description; never field names or `default`/`enum` data) and printer-column descriptions; apply patches; keep everything else | — |
| dedupe | same `metadata.name` from several sources must be identical | content differs |
| templatize | `to json --indent 0` (JSON is YAML; see release-size budget); escape `{{`/`}}`; inject labels/annotations template via sentinel lines | — |
| emit | `Chart.yaml` (derived `kubeVersion`, Artifact Hub annotations, `charts.spnngl.io/upstream-{repo,tag,commit}`, `sources[0]` = this repo), `values.yaml`, `values.schema.json`, `ci/ci-values.yaml`, `templates/*.yaml`, `_helpers.tpl`, `LICENSE`, `NOTICE`, `README.md`, `.helmignore` (excludes `ci/` and itself from the package); release-size estimate (README SQL-driver note when oversized) | — |
| validate | `helm lint --strict`; `helm template` round-trips to sanitized records; injected labels/keep annotation present; schema negative test; values behaviour; structural CRD check (one storage version, name = plural.group, schemas present); kubeconform against the pinned Kubernetes JSON schemas | any check |

Only `render` is polymorphic. Only `templatize` touches text; everything
else is structured records. Module-level detail: `tooling/ARCHITECTURE.md`.

Release-size budget: Helm stores the release (chart files base64-encoded
inside JSON + rendered manifest) gzipped and base64-encoded in one Secret,
capped at 1 MiB (Helm 3 and Helm 4 alike). The estimator mirrors that
encoding on the packaged chart, so `.helmignore` applies (within 1 % of a real
release): warning > 800 kB; > 1 000 kB the chart is *oversized*: it still
ships, its README replaces `helm install` with the SQL storage driver
(`HELM_DRIVER=sql`, PostgreSQL, no size cap) and `--history-max=1`.
Templates are emitted as unindented JSON, one token per line: base64 inside
the release defeats gzip on YAML indentation, so this saves ~25 % over YAML
while keeping line diffs (`.gitattributes` collapses them on GitHub). Helm
cannot decompress anything at render time, so short of dropping content
(`stripDocs`, below) this is the floor. At v1.6.2:
`gateway-api-crds` ≈ 485 kB, `gateway-api-exp-crds` ≈ 601 kB — one chart
holding both channels would exceed the cap, hence two charts. Prefer such a
split when it is natural. Otherwise `transform.stripDocs` removes schema
documentation (72–92 % smaller; validation unchanged, `kubectl explain` loses
field docs; README and NOTICE say so): `kyverno-crds` (≈ 1.7 MB) drops to
≈ 190 kB. Enable it only where needed; docs are worth their bytes.

Schema validation: kubeconform's default schema location
(`<version>-standalone-strict`) has no `CustomResourceDefinition` schema, but
the plain per-version directory of yannh/kubernetes-json-schema does. The
generator validates rendered CRDs against it for the Kubernetes version pinned
as `k8s-json-schema` in `tooling/versions.toml` (`CRDGEN_SCHEMA_LOCATION`
points it at a local clone; `CRDGEN_OFFLINE=1` skips). `ct install` against
kind remains the real API-server validation.

Chart `version` rule: `appVersion` = upstream version. `version` =
`appVersion` if it is greater than the previously published version, else
previous PATCH+1 (compared against `origin/main`, override with
`CRDGEN_BASE_REF`; a new chart starts at `appVersion`). Tooling-only change → PATCH+1. Monotonic, usually equal to
upstream.

Chart values interface (all CRD charts, nothing else):
`annotations: {}`, `labels: {}`, `keepOnUninstall: true`.
`values.schema.json` has `additionalProperties: false`.

CRDs live in `templates/`, not `crds/`, so `helm upgrade` updates them.

## Workflows

### `pr.yml` (no secrets; runs on fork PRs)

nu lint/format → manifest validation + naming invariant (`charts/*-crds` ⇔
`sources/*.yaml`) → generator tests → `regen --all` + drift-check →
`ct lint` (Chart.yaml schema, yamllint, `helm lint --strict`, version
increment) → `values.schema.json` present (+ kubeconform, kube-linter,
helm-docs drift for hand-written charts) → `ct install --upgrade` in kind,
matrix {oldest upstream-supported k8s, latest} × {Helm 3, Helm 4 (server-side
apply)}, releases stored in a PostgreSQL service container (`HELM_DRIVER=sql`,
so oversized charts install too; `HELM_MAX_HISTORY=1`). Each CRD chart ships
`ci/ci-values.yaml` with `keepOnUninstall: false` so ct can clean up between
charts.

### `release.yml` (push to `main`, runs serialised)

`tooling/release/plan.nu` lists charts whose GitHub Release `<name>-<version>`
does not exist yet (the Release is the last step, hence the completion
marker), then per chart (matrix, in parallel: legs share no state, each owns
its package, tag and Release; the `release` concurrency group serialises whole
runs so `plan.nu` never races itself):
`helm package` → `helm push` (digest) → `cosign sign` (keyless) by digest →
`syft` SBOM → `cosign attest --type spdxjson` (keyless) → `actions/attest` twice
(SLSA provenance, then SBOM; push-to-registry) → GitHub Release `<name>-<version>`
with `.tgz` + SBOM → package visibility check (warning if not public).

Then two jobs: `tooling/release/artifacthub.nu --all` for **every** published
chart (search the AH repository by OCI URL, create it as `spnngl-<chart>` if
missing, `oras push` `artifacthub-repo.yml` with the `repositoryID` to
`<chart>:artifacthub.io`; idempotent, skipped with a warning without AH
secrets, so it also catches charts published before the secrets existed), and
`tooling/release/verify.nu` running the documented verify commands from a job
without repo secrets (matrix, in parallel). `workflow_dispatch` with nothing to publish still runs
the Artifact Hub job.

Published versions are immutable: if the registry tag already exists (a
previous run failed after `helm push`), the job resolves its digest and
resumes signing/attesting/releasing instead of pushing again. Logins: `helm
registry login` for helm, `docker login` for cosign and the attestation
actions (they read `~/.docker/config.json`). GHCR package is linked to this repo via
`Chart.yaml` `sources[0]` → `org.opencontainers.image.source`, which also
makes it public automatically.

### `sync.yml` (daily + manual)

Per manifest: list upstream tags → newest matching `tagPattern` and `allow`
above `current` → rewrite `current` → run generator → branch
`sync/<name>/<tag>` → PR (one per chart, updated in place) with CRD diff
summary → `gh pr merge --auto --rebase`. Runs as a GitHub App
(`APP_CLIENT_ID`, `APP_PRIVATE_KEY`) so the PR triggers `pr.yml`. Failures
(path moved, zero CRDs, dedupe conflict) open/update issue
`sync failure: <name>`.

Sync PRs touch only `sources/<name>.yaml`, `charts/<name>/` and the root
`NOTICE`, which carries no per-version data, so concurrent PRs do not
conflict.

## Trust

- Signing: cosign keyless. `release.yml` (`id-token: write`) gets a GitHub
  Actions OIDC token, Fulcio issues a short-lived certificate whose identity
  is `https://github.com/spnngl/charts/.github/workflows/release.yml@<ref>`
  (issuer `https://token.actions.githubusercontent.com`), and the signature
  goes to Rekor. Identity and issuer live in `tooling/crdgen/config.nu`
  (`COSIGN_IDENTITY_REGEXP`, `COSIGN_OIDC_ISSUER`) and feed the chart READMEs
  and `verify.nu`. Any ref is accepted: the workflow identity, not the
  branch, is the trust anchor.
- Signature: `cosign verify --certificate-identity-regexp <regexp> --certificate-oidc-issuer <issuer> <ref>`
- SBOM: `cosign verify-attestation --type spdxjson --certificate-identity-regexp <regexp> --certificate-oidc-issuer <issuer> <ref>`
- Provenance: `gh attestation verify oci://<ref>@<digest> --owner spnngl`
- Artifact Hub detects the cosign signature in the registry on its own; no
  `artifacthub.io/signKey` annotation (it requires a public key URL).
- Secrets: `APP_CLIENT_ID`, `APP_PRIVATE_KEY`, `AH_API_KEY_ID`,
  `AH_API_KEY_SECRET`. `pr.yml` uses none.

## Licensing

Repo: Apache-2.0. Each CRD chart ships the upstream `LICENSE` verbatim, a
`NOTICE` with upstream notice + our modification statement + pinned
tag/commit, and README attribution. Root `NOTICE` lists upstreams and
licenses (no versions). Manifest `upstream.license` must be in the allowlist
and match the upstream `LICENSE`.

## Non-goals

Classic `index.yaml`/GitHub Pages repository; non-CRD resources in CRD
charts; `apiextensions.k8s.io/v1beta1`; mirroring upstream app charts.

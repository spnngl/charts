# ARCHITECTURE

Helm charts repository. Two chart kinds, one release pipeline.

| Kind | Location | Source of truth | Versioning |
|------|----------|-----------------|------------|
| CRD charts | `charts/*-crds/` (generated) | `sources/*-crds.yaml` | automatic, tracks upstream |
| Hand-written charts | `charts/<name>/` | the chart itself | manual bump, CI-enforced |

Output for both: OCI chart at `oci://ghcr.io/spnngl/charts/<name>`, cosign
key signature, SBOM + SLSA provenance attestations, Artifact Hub listing.

## Layout

```
sources/<name>-crds.yaml   per-CRD-chart manifest (hand-written)
charts/<name>-crds/        generated chart; drift-checked in CI
charts/<name>/             hand-written chart; ci/*-values.yaml for ct; README.md.gotmpl for helm-docs
tooling/crdgen/            nushell generator, one file per pipeline step; `mod.nu` is the CLI
tooling/crdgen/tests/      fixtures + `run.nu` unit tests (no network)
tooling/release/           plan.nu (what to publish), artifacthub.nu, verify.nu (smoke test)
tooling/versions.toml      pinned tool versions, read by CI (.github/actions/setup-tools) and local runs
.github/workflows/pr.yml       validate, regen, drift-check, ct lint, ct install
.github/workflows/release.yml  package, push, sign, attest, Artifact Hub, smoke test
.github/workflows/sync.yml     scheduled upstream tracking, opens automerging PRs
.github/actions/setup-tools/   installs the pinned tool versions on runners
ct.yaml                    chart-testing config (lint + install)
renovate.json              our own dependency updates (tool pins, Actions SHAs, kind images)
.kube-linter.yaml          hand-written charts only
artifacthub-repo.yml       Artifact Hub metadata template; repositoryID injected at release
cosign.pub                 public signing key (private key: repo secret, never committed)
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
| sanitize | drop `status`, `creationTimestamp`, server-side metadata, Helm labels/annotations; apply patches; keep everything else | — |
| dedupe | same `metadata.name` from several sources must be identical | content differs |
| templatize | `to yaml`; escape `{{`/`}}`; inject labels/annotations template via sentinel lines | — |
| emit | `Chart.yaml` (derived `kubeVersion`, Artifact Hub annotations, `charts.spnngl.io/upstream-{repo,tag,commit}`, `sources[0]` = this repo), `values.yaml`, `values.schema.json`, `ci/ci-values.yaml`, `templates/*.yaml`, `_helpers.tpl`, `LICENSE`, `NOTICE`, `README.md` | — |
| validate | `helm lint --strict`; `helm template` round-trips to sanitized records; injected labels/keep annotation present; schema negative test; values behaviour; structural CRD check (one storage version, name = plural.group, schemas present); kubeconform against the pinned Kubernetes JSON schemas; release-size budget | any check |

Only `render` is polymorphic. Only `templatize` touches text; everything
else is structured records.

Release-size budget: Helm stores the release (chart files base64-encoded
inside JSON + rendered manifest) gzipped and base64-encoded in one Secret,
capped at 1 MiB. The estimator mirrors that encoding (within 1 % of a real
release): warn > 800 kB, fail > 1 000 kB. At v1.6.2: `gateway-api-crds`
≈ 649 kB, `gateway-api-exp-crds` ≈ 788 kB — one chart holding both channels
would already exceed the cap, hence two charts.

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
matrix {oldest upstream-supported k8s, latest}. Each CRD chart ships
`ci/ci-values.yaml` with `keepOnUninstall: false` so ct can clean up between
charts.

### `release.yml` (push to `main`, serialised)

`tooling/release/plan.nu` lists charts whose `version` is absent from GHCR
(`helm show chart`), then per chart (matrix, serialised):
`helm package` → `helm push` (digest) → `cosign sign --key` by digest →
`syft` SBOM → `cosign attest --type spdxjson` → `actions/attest-build-provenance`
+ `actions/attest-sbom` (push-to-registry) → `tooling/release/artifacthub.nu`
(search AH repository by OCI URL, create if missing, `oras push`
`artifacthub-repo.yml` with the `repositoryID`; skipped with a warning if AH
secrets are absent) → GitHub Release `<name>-<version>` with `.tgz` + SBOM →
package visibility check (warning if not public) → `tooling/release/verify.nu`
runs the documented verify commands from a job without repo secrets.

Published versions are immutable. GHCR package is linked to this repo via
`Chart.yaml` `sources[0]` → `org.opencontainers.image.source`.

### `sync.yml` (daily + manual)

Per manifest: list upstream tags → newest matching `tagPattern` and `allow`
above `current` → rewrite `current` → run generator → branch
`sync/<name>/<tag>` → PR (one per chart, updated in place) with CRD diff
summary → `gh pr merge --auto --squash`. Runs as a GitHub App
(`APP_CLIENT_ID`, `APP_PRIVATE_KEY`) so the PR triggers `pr.yml`. Failures
(path moved, zero CRDs, dedupe conflict) open/update issue
`sync failure: <name>`.

Sync PRs touch only `sources/<name>.yaml`, `charts/<name>/` and the root
`NOTICE`, which carries no per-version data, so concurrent PRs do not
conflict.

## Trust

- Signature: `cosign verify --key cosign.pub ghcr.io/spnngl/charts/<name>:<version>`
- SBOM: `cosign verify-attestation --key cosign.pub --type spdxjson <ref>@<digest>`
- Provenance: `gh attestation verify oci://<ref>@<digest> --owner spnngl`
- Secrets: `COSIGN_PRIVATE_KEY`, `APP_CLIENT_ID`,
  `APP_PRIVATE_KEY`, `AH_API_KEY_ID`, `AH_API_KEY_SECRET`. `pr.yml` uses none.

## Licensing

Repo: Apache-2.0. Each CRD chart ships the upstream `LICENSE` verbatim, a
`NOTICE` with upstream notice + our modification statement + pinned
tag/commit, and README attribution. Root `NOTICE` lists upstreams and
licenses (no versions). Manifest `upstream.license` must be in the allowlist
and match the upstream `LICENSE`.

## Non-goals

Classic `index.yaml`/GitHub Pages repository; non-CRD resources in CRD
charts; `apiextensions.k8s.io/v1beta1`; mirroring upstream app charts.

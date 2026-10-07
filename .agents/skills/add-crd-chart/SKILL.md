---
name: add-crd-chart
description: Add a new CRD-only Helm chart for an upstream project (sources/<name>-crds.yaml + generated chart). Use when asked to "add <project> CRDs".
---

Add a generated CRD chart for an upstream project. Input: an upstream GitHub
repo URL, optionally a version to pin. Output: `sources/<name>-crds.yaml`,
`charts/<name>-crds/` (generated), README table row, one commit.

Never hand-edit `charts/`. Everything there comes from the generator.

## Steps

1. **Pick the chart name**: `<upstream-short-name>-crds` (lowercase, dashes).
   Must not collide with an existing `sources/*.yaml`.

2. **Probe the upstream** (no clone needed):

   ```sh
   gh api repos/<owner>/<repo> --jq '{license: .license.spdx_id, homepage}'
   gh api 'repos/<owner>/<repo>/tags?per_page=100' --jq '.[].name' | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head
   gh api 'repos/<owner>/<repo>/git/trees/<tag>?recursive=1' --jq '.tree[].path' | grep -i crd | grep -E '\.ya?ml$|kustomization'
   ```

   Decide the source kind from what you see:

   | You see | `kind` | `path` |
   |---------|--------|--------|
   | a directory of one-CRD-per-file YAML (`config/crd/bases`, `config/crd/standard`, …) | `git-path` | that directory |
   | a single bundled YAML (`deploy/crds/bundle.yaml`) | `git-path` | that file |
   | `kustomization.yaml` listing CRDs with patches/channels | `kustomize` | directory holding the kustomization |
   | CRDs inside a Helm chart's `templates/` **with** `{{ }}` templating | `helm-template` | `chartPath:` + `values:` enabling CRDs |
   | CRDs inside a Helm chart's `templates/` or `crds/` as plain YAML | `git-path` | that directory |
   | CRDs only in a GitHub release asset | `release-asset` | `asset:` name/regex (+ `archivePath:`) |

   Prefer the generator output (controller-gen `bases`) over copies in charts
   or bundles: copies lag. If the same CRDs exist in two places, pick one.
   Non-CRD resources (RBAC, webhooks, ValidatingAdmissionPolicy) are dropped
   automatically and listed in the chart README.

   The license must be one of `Apache-2.0`, `MIT`, `BSD-2-Clause`,
   `BSD-3-Clause`. Anything else: stop and ask.

   Check the tag families: if the repo also tags charts or sub-projects
   (`<name>-chart-v1.2.3`, `api/v0.1.0`), make sure `tagPattern` only matches
   the project releases. Pre-releases must not match.

3. **Write the manifest** `sources/<name>-crds.yaml`:

   ```yaml
   name: <name>-crds
   description: CustomResourceDefinitions for <Project> (<what the CRDs are>)
   upstream:
     repo: https://github.com/<owner>/<repo>
     homepage: <project homepage or repo URL>
     icon: <raw URL to an svg/png logo in the repo>   # optional, drop if none
     license: <SPDX>
   version:
     tagPattern: '^v(\d+\.\d+\.\d+)$'   # group 1 = appVersion; adjust if tags have no "v"
     allow: all
     current: <tag>                      # latest release unless told otherwise
   sources:
     - kind: <kind>
       path: <path>
   transform:
     include: []
     exclude: []
     patches: []
   ```

   Add a short comment on the source explaining why that path (future you
   will thank you when upstream moves it). Use `conflictsWith:` only when two
   of our charts define the same CRD names (e.g. channels).

4. **Generate and validate**:

   ```sh
   nu tooling/crdgen/mod.nu regen <name>-crds
   ct lint --config ct.yaml --charts charts/<name>-crds
   ```

   `regen` already runs helm lint, render round-trip, schema negative tests,
   structural checks, kubeconform and the release-Secret size budget. A
   `::warning::` about the size budget means the chart is above 800 kB of
   Helm's 1 MiB cap: mention it in the commit body. A warning above 1 MB
   means the chart is oversized: Helm's default Secret storage cannot hold
   it and the README tells users to use `HELM_DRIVER=sql`. Stop and ask
   whether to ship it like that, split it (`include`/`exclude` across two
   manifests) or set `transform.stripDocs: true` (drops schema descriptions,
   usually 70–90 % smaller; `kubectl explain` loses field docs).

5. **Review the output**: `charts/<name>-crds/README.md` — CRD count and
   names match upstream, versions/storage look right, the "Not included"
   list contains only things that should be excluded.

6. **README table**: add a row to the "Charts" table in `README.md`
   (alphabetical order).

7. **Confirm no drift and commit** (manifest + generated chart + README +
   root `NOTICE`, which `regen` rewrites):

   ```sh
   nu tooling/crdgen/mod.nu check <name>-crds
   git add sources/<name>-crds.yaml charts/<name>-crds NOTICE README.md
   git commit -m "feat(charts): add <name> CRD chart" -m "<source path, CRD count, pin, anything notable (size, dropped kinds, path moves)>"
   ```

   Do not push. Merging to `main` publishes the chart automatically; the
   scheduled sync keeps it current.

## Optional: real-cluster check

```sh
kind create cluster --name crdgen-test
ct install --config ct.yaml --charts charts/<name>-crds
kind delete cluster --name crdgen-test
```

CI does this on every PR; run it locally only if the CRDs use unusual
features (conversion webhooks, CEL rules on old Kubernetes).

---
name: add-chart
description: Add a hand-written (application) Helm chart under charts/<name> for an upstream project: research, plan, values + schema, templates, render tests, docs, Renovate, kind smoke test, commits. Use whenever asked to "add a chart for <project>", "package <app> with Helm", "create charts/<name>", or to implement a PLAN.md for a non-CRD chart, even for a single part (values, schema, templates, tests). Not for `*-crds` charts: use add-crd-chart.
---

Reference implementation: `charts/cloudflared/`. Copy its structure, adapt
its content. Read on demand:

- `references/conventions.md` before step 4 (layout, patterns, defaults).
- `references/gotchas.md` before step 5 and on every failing check.

Commands below run in any shell (no `&&`, no line continuations).

## Steps

1. **Research upstream from source** at the release tag (`git_clone`):
   - Dockerfile: base, `USER`, `ENTRYPOINT`/`CMD`.
   - Config loading: flags, env, config file; can secrets come from a file?
     (prefer file over env).
   - Health/metrics endpoints, port, meaning of "ready".
   - Signals, grace period.
   - Capabilities, sockets, disk writes (decides `drop: [ALL]`,
     `readOnlyRootFilesystem`).
   - Upstream docs: sizing, hard limits (replica caps), network needs.
   - Existing official/community charts: value names users expect.
   - Image signing: `cosign tree <image>`, `oras discover <image>`.
2. **Write `charts/<name>/PLAN.md`** (git-ignored, never commit): decisions
   + rationale, upstream facts with source paths, values draft, templates,
   guards, test cases, CI/Renovate changes, smoke test, commits.
3. **Ask, then stop.** Concise list of open questions: workload kind,
   Secret handling, replicas, resources, opt-in objects (HPA, VPA, PDB,
   NetworkPolicy, ServiceMonitor/PodMonitor), `hostUsers`, extra values.
   Repo rule: ask before adding a chart value, tool or workflow. Update the
   plan; implement only when told.
4. **Scaffold** from `charts/cloudflared/`: `Chart.yaml`, `.helmignore`,
   `values.yaml`, `templates/` (`_helpers.tpl`, workload, `NOTES.txt`,
   `tests/`), `ci/*-values.yaml`, `tests/cases/`, `README.md.gotmpl`.
5. **Values + schema.** `# @schema` block, then `# --` doc, then key.
   Generate, then read the schema for closed maps:
   ```
   helm schema -k title,default,required -r -c charts/<name>
   ```
   CI checks with `helm-schema -k title,default,required -C -c charts/<name>`.
   Never hand-edit `values.schema.json`.
6. **Templates**, then lint the default render (what `pr.yml` checks):
   ```
   helm lint --strict charts/<name>
   helm template <name> charts/<name> --namespace <name> | kubeconform -strict -summary -ignore-missing-schemas -schema-location default
   helm template <name> charts/<name> --namespace <name> | kube-linter lint --config .kube-linter.yaml -
   ```
7. **Render tests**: one case per toggle, one `error-*` case per guard and
   schema rule. Review goldens like code.
   ```
   nu tooling/charttest/mod.nu run <name> --update
   nu tooling/charttest/mod.nu run <name>
   ```
8. **Docs**: `README.md.gotmpl` (install per mode, Secret, security and
   opt-outs, availability, autoscaling, resources, network, compatibility,
   values table), `helm-docs --chart-search-root charts/<name>`, row in root
   `README.md` "Charts" table (alphabetical).
9. **Renovate** (`renovate.json5`): the shared custom manager already reads
   `charts/*/Chart.yaml`. Add a `packageRules` entry: `matchDepNames`,
   automerge, `minimumReleaseAge`, `bumpVersions` patch on
   `charts/<name>/Chart.yaml` (else `ct` rejects the unbumped `version`).
   Override `versioning` if upstream tags are not `X.Y.Z`. Validate:
   ```
   npx --yes --package renovate -- renovate-config-validator --strict
   ```
10. **Verify** with Helm 3 (CI version in `tooling/versions.toml`) and Helm 4:
    ```
    ct lint --config ct.yaml --charts charts/<name> --target-branch main
    helm schema -k title,default,required -C -c charts/<name>
    helm-docs --chart-search-root charts/<name>
    git diff --exit-code charts/<name>/README.md
    nu tooling/charttest/mod.nu run --all
    helm package charts/<name> -d /tmp
    tar -tzf /tmp/<name>-0.1.0.tgz
    ```
    The package must not contain `tests/`, `PLAN.md`, `README.md.gotmpl`.
11. **Smoke test on kind** (CI's `ct install` rarely starts the app). Use
    the kind image pinned in `.github/workflows/pr.yml`:
    ```
    kind create cluster --name <name> --image <kindest/node pinned in pr.yml>
    ct install --config ct.yaml --charts charts/<name> --target-branch main
    ```
    Then install with 1 replica and a fake credential; check security
    context in effect (`docker exec <name>-control-plane grep -E 'Uid|CapEff|NoNewPrivs|Seccomp' /proc/<pid>/status`),
    probes, logs (no filesystem/permission errors), NetworkPolicy, metrics,
    in-place resize. `kind delete cluster --name <name>`. Report what stays
    untested.
12. **Commit** (read the git-commit skill first), one concern each, each
    passing CI: tooling (if any), CI (if any), `feat(<name>): add chart`
    (chart + root README row), Renovate rule. Do not push. On CI failure:
    `gh run view <run-id> --repo spnngl/charts --log-failed`, fix forward
    with a new commit.

## Done when

- All step 10 checks pass with Helm 3 and 4.
- Defaults are secure and HA with no override; every default that can fail
  on some clusters is documented with its symptom and opt-out.
- The report lists what was verified on a cluster and what was not.

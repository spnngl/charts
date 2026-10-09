---
name: add-chart
description: Add or change a hand-written (non-CRD) Helm chart under charts/<name>: research, PLAN.md, values + schema, templates, render tests, docs, Renovate, kind smoke test, commits. Use when asked to add a chart for a project, implement a chart PLAN.md, or change any part of an existing hand-written chart (values, schema, templates, tests, README). `*-crds` charts: use add-crd-chart.
---

Reference implementations: `charts/cloudflared/` (Deployment) and
`charts/cs-firewall-bouncer/` (DaemonSet, host network). Copy the structure
of the closer one, adapt its content. Read on demand:

- `references/conventions.md` before step 4 (layout, patterns, defaults).
- `references/gotchas.md` before step 5 and on every failing check.

Commands below run in any shell (no `&&`, no line continuations).

**Changing an existing chart:** run steps 5–10 for the parts you touch,
bump `version` in `Chart.yaml` (PATCH for fixes, MINOR for new values or
behaviour), and commit as `feat(<name>): …` / `fix(<name>): …`.

## Steps

1. **Research upstream from source** at the release tag (`git_clone`):
   - Dockerfile: base, `USER`, `ENTRYPOINT`/`CMD`.
   - Config loading: flags, env, config file; can secrets come from a file?
     (prefer file over env).
   - Health/metrics endpoints, port, meaning of "ready".
   - Signals, grace period, what the app leaves behind on SIGTERM and on
     SIGKILL.
   - Capabilities, sockets, disk writes (decides `drop: [ALL]`,
     `readOnlyRootFilesystem`).
   - Upstream docs: sizing, hard limits (replica caps), network needs,
     minimum versions of the services it talks to.
   - Existing official/community charts: value names users expect.
   - Image signing: `cosign tree <image>`, `oras discover <image>`.
2. **Write `charts/<name>/PLAN.md`** (git-ignored): decisions + rationale,
   upstream facts with source paths, values draft, templates, guards, test
   cases, CI/Renovate changes, smoke test, commits.
3. **Ask, then stop.** Concise list of open questions: workload kind,
   Secret handling, replicas, resources, opt-in objects (HPA, VPA, PDB,
   NetworkPolicy, ServiceMonitor/PodMonitor, PrometheusRule), `hostUsers`,
   Renovate automerge and release age, extra values. Repo rule: ask before
   adding a chart value, tool or workflow. Update the plan; implement only
   when told.
4. **Scaffold** from the reference chart: `Chart.yaml`, `.helmignore`,
   `values.yaml`, `templates/` (`_helpers.tpl`, workload, `NOTES.txt`),
   `ci/*-values.yaml`, `tests/cases/`, `README.md.gotmpl`.
5. **Values + schema.** `# @schema` block, then `# --` doc, then key.
   Generate, then read the schema for closed maps:
   ```
   helm schema -k title,default,required -r -c charts/<name>
   ```
   `values.schema.json` changes only through this command; CI checks it with
   `-C`.
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
   `README.md` "Charts" table (hand-written section, alphabetical).
9. **Renovate** (`renovate.json5`): the shared custom manager already reads
   `charts/*/Chart.yaml`. Add a `packageRules` entry: `matchDepNames`,
   `matchUpdateTypes`, automerge, `minimumReleaseAge` (as answered in step
   3), `bumpVersions` patch on `charts/<name>/Chart.yaml` (else `ct` rejects
   the unbumped `version`), and a `description` with the why. Override
   `versioning` if upstream tags are not `X.Y.Z`. Validate with the Renovate
   image pinned in `.github/workflows/renovate.yml`:
   ```
   docker run --rm -v "$PWD:/usr/src/app:ro" -w /usr/src/app ghcr.io/renovatebot/renovate:<tag> renovate-config-validator --strict
   ```
10. **Verify** with Helm 3 (CI version in `tooling/versions.toml`) and Helm 4:
    ```
    ct lint --config ct.yaml --charts charts/<name>
    helm schema -k title,default,required -C -c charts/<name>
    helm-docs --chart-search-root charts/<name>
    git diff --exit-code charts/<name>/README.md
    nu tooling/charttest/mod.nu run --all
    helm package charts/<name> -d /tmp
    tar -tzf /tmp/<name>-<version>.tgz
    ```
    Done when all pass and the package holds no `tests/`, `PLAN.md` or
    `README.md.gotmpl`.
11. **Smoke test on kind** (CI's `ct install` rarely starts the app). Use
    the kind image pinned in `.github/workflows/pr.yml`:
    ```
    kind create cluster --name <name> --image <kindest/node pinned in pr.yml>
    ct install --config ct.yaml --charts charts/<name>
    ```
    Then install with values that start the app. Run the services it needs
    (an API, a database) as docker containers on the `kind` network. Check:
    security context in effect
    (`docker exec <name>-control-plane grep -E 'Uid|CapEff|NoNewPrivs|Seccomp' /proc/<pid>/status`),
    probes, logs (no filesystem/permission errors), the app's actual effect,
    metrics, memory under realistic load (sets the default limit), restart
    and uninstall behaviour. `kind delete cluster --name <name>` and remove
    the containers. Report what stays untested.
12. **Commit** (read the git-commit skill first), one concern each, each
    passing CI: tooling (if any), CI (if any), `feat(<name>): add chart`
    (chart + root README row), `chore(renovate): track <name> image`. Leave
    pushing to the user. On CI failure:
    `gh run view <run-id> --repo spnngl/charts --log-failed`, fix forward
    with a new commit.

## Done when

- All step 10 checks pass with Helm 3 and 4.
- Defaults are secure and HA with no override; every default that can fail
  on some clusters is documented with its symptom and opt-out.
- The report lists what was verified on a cluster and what was not.

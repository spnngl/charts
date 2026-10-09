# Gotchas

Symptom -> cause -> fix. All hit on `charts/cloudflared` or
`charts/cs-firewall-bouncer`.

## helm-schema (0.23.5)

- **Users cannot set a nested field** (`seccompProfile.localhostProfile`,
  `dnsConfig.nameservers`) -> every inferred map, `{}` included, gets
  `additionalProperties: false` -> annotate open maps:
  ```yaml
  # @schema
  # type: object
  # additionalProperties: true
  # @schema
  ```
  Label/annotation maps: `additionalProperties: {type: string}`. Arrays of
  Kubernetes objects: `type: array`, `items: {type: object,
  additionalProperties: true}`.
- **Type missing in schema** -> an annotated key loses inference -> always
  write `type:`; int-or-string: `anyOf` integer/string.
- **Schema text in the README table** -> `# @schema` below `# --` -> put it
  above. `# @schema.root` goes right before the first key.
- **CI drift on an unchanged values.yaml** -> different flags -> always
  `-k title,default,required`; never `-p`.
- No remote `$ref` (offline/air-gapped `helm lint` breaks).
- Errors read `at '/config': 'not' failed`: match that in `error-*` cases,
  explain the rule in the `# --` doc.
- `global` is auto-added: keep it.
- **Schema rejects `limits.memory: 300000000`** -> a quantity default like
  `256Mi` makes the inferred type `string` -> quote byte counts in values
  and docs (`"300000000"`).

## kube-linter

Repo excludes: `unset-*-requirements`, `default-service-account`,
`required-label-owner`, `required-annotation-email`, `priority-class-name`.
Ignore per object with `ignore-check.kube-linter.io/<check>: "<reason>"` on
the workload `metadata.annotations` (not the pod template):

- `sorted-keys` checks raw YAML text. Hand-built list items
  (`- {{ toYaml $x | nindent 6 }}`, `- {{- with }}from:` before `ports:`)
  break it: build the dict, emit `{{ toYaml (list $x) | nindent 4 }}`.
- `no-node-affinity` ignores `nodeSelector`: ignore with that reason.
- `unsafe-sysctls` list predates kubelet safe sysctls
  (`ip_local_port_range`, `ping_group_range`): ignore, cite kubelet.
- `minimum-three-replicas` fires when `replicas` is omitted for the HPA:
  ignore only when autoscaling is on.
- `no-rolling-update-strategy`: ignore only when the user chose Recreate.
- `pdb-unhealthy-pod-eviction-policy`: set `AlwaysAllow`.
- Test pod: ignore `no-liveness-probe`, `no-readiness-probe`,
  `non-isolated-pod`, `restart-policy`.
- `pr.yml` lints defaults only; charttest lints every passing case.

## Helm templates

- `merge` keeps the first dict's values: `merge $chartOwned (deepCopy
  .Values.x)`. Always `deepCopy` values before merging.
- Optional nested values: `dig "limits" "memory" "" .Values.resources`.
- File modes: decimal (`288` = 0440); YAML octal parsing varies.
- `ternary` evaluates both branches: a failing `include` or `fail` in the
  unused branch still fires. Use `if`/`else`.
- Guard helper renders nothing: include it from an always-rendered
  template (`{{- include "<name>.validate" . }}` in the ConfigMap).
- **`helm test` pod missing** (`could not find template
  templates/tests/...`) -> `.helmignore` `tests/` unanchored -> `/tests/`.
- `helm template` without `--namespace` -> `namespace: default`.

## charttest

- Files Helm reads (`values.yaml`, `ci/*.yaml`): quote `"Off"`, `"On"`,
  `"yes"`, `"no"` (YAML 1.1 booleans). Case files are safe: the runner
  passes values to Helm as JSON.
- Blank lines are dropped from renders (Helm 3.22 vs 3.20/4 differ there).
- `--update` rewrites goldens: review `git diff`.
- kubeconform fetches CRD schemas; `CHARTTEST_OFFLINE=1` skips it.

## CI (ct, kind, Helm)

- **Install job times out / `connection refused` in `helm test`** -> `ct
  install` runs `helm test` with `replicaCount: 0` -> render the test pod
  only when a replica runs.
- `Error: could not find ct-previous-revision…` + "Skipping upgrade test" on
  a new chart: harmless.
- **`FailedCreatePodSandBox … error mounting "sysfs" … operation not
  permitted`** -> `hostUsers: false` on kind inside GitHub runners (works on
  Docker Desktop kind) -> never start such a pod in CI, or set
  `hostUsers: true` in `ci/*-values.yaml`.
- `ct lint` needs a `version` bump vs `main` (`ct.yaml` sets the target
  branch).
- Matrix: kind × Helm 3/4 (`pr.yml`), `HELM_DRIVER=sql`; Helm 3 and 4
  renders must be byte-identical.
- **Local kind cluster with the newest `kindest/node` never gets ready on
  Docker Desktop arm64** (seen with v1.37.0) -> not investigated -> smoke
  test on the older image of the `pr.yml` matrix.
- **`no matches for kind "PodMonitor"`** on kind -> no Prometheus Operator
  CRDs -> install them before enabling a monitor or rule; CI values keep
  them off.
- **`hostUsers: Forbidden`** with `hostNetwork: true` -> user namespaces
  require pod-level namespaces -> host-network charts have no `hostUsers`
  value.

## Renovate

- **`bumpVersions` reported as invalid** -> `npx renovate-config-validator`
  resolves an old Renovate -> validate with the image pinned in
  `.github/workflows/renovate.yml` (SKILL step 9), without a file argument
  (a file argument is validated as global config).

## Upstream and cluster

- Verify every upstream claim in source at the shipped tag; docs drift.
- Unsigned image: digest pin only, state it in the README.
- Startup probe on "ready" restarts pods that never connect: document
  `startupProbe.failureThreshold`.
- Fake credentials on kind verify: security context, probes, logs, egress
  policy, metrics, resize. Not: real traffic, `helm test` success, Secret
  rotation. Report those as untested. A real backend in a docker container
  on the `kind` network (cs-firewall-bouncer: CrowdSec LAPI) verifies the
  app's effect too.

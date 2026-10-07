# Conventions

As implemented in `charts/cloudflared/`. Deviate only with a reason in the
plan.

## Chart.yaml

- `apiVersion: v2`, `version: 0.1.0`, quoted `appVersion`, `kubeVersion`
  = oldest minor whose features are used (`>=1.33.0-0`).
- `sources[0]: https://github.com/spnngl/charts`, then upstream repo.
- `maintainers`, `home`, `keywords`, `icon` (URL must return 200).
- Annotations: `artifacthub.io/license`; `artifacthub.io/links` (upstream
  project, upstream repo, chart source, "Verify signature and attestations"
  -> `https://github.com/spnngl/charts#verifying-what-you-install`);
  `artifacthub.io/images` with `repo:tag@sha256:<index digest>`
  (`oras manifest fetch --descriptor <repo>:<tag>`).
- `# renovate: datasource=docker depName=<repo>` on the line above
  `appVersion`.
- Default image = annotation digest, parsed by the image helper when
  `image.tag` is empty and `image.repository` matches. `image.digest`
  without `image.tag` fails the render.

## .helmignore

Standard list plus `/tests/` (anchored), `README.md.gotmpl`, `PLAN*.md`.

## values.yaml

- Line 1: `# yaml-language-server: $schema=values.schema.json`.
- `# @schema.root` (title, cross-field `allOf`) right before the first key.
- Per key: `# @schema` block (optional), `# --` doc (say why), key.
- Order: naming, image, app settings (mode, Secret ref, `config`), workload,
  optional objects, extras (`extraVolumes`, `extraVolumeMounts`).
- Security contexts and resources written in full in values (users see and
  override them; maps deep-merge, lists replace).
- Secrets: existing Secret only (`existingSecret.name` defaulting to
  fullname, `key`), mounted as a file, `defaultMode: 288` (0440),
  `fsGroup` = image gid.
- App config: free-form `config` map -> ConfigMap, chart-owned keys win;
  schema rejects them: `propertyNames: {not: {enum: [...]}}`.
- Upstream hard limits -> schema `maximum` + template guard for derived
  values (replicas + maxSurge <= cap).

## Templates

- Helpers: `name`, `fullname`, `chart`, `selectorLabels` (instance + name,
  frozen after release), `labels` (sorted), `serviceAccountName`, `image`,
  `validate`.
- `metadata.namespace: {{ .Release.Namespace }}` on every object.
- Keys sorted at every level; computed lists/maps via `toYaml`.
- `checksum/config` pod annotation from the ConfigMap. Secrets are not
  checksummed: document `kubectl rollout restart` / Reloader.
- Omit `replicas` when the HPA is enabled.
- `terminationGracePeriodSeconds` = app grace + margin;
  `terminationMessagePolicy: FallbackToLogsOnError`.
- Go app with memory limit: env `GOMEMLIMIT` from `resourceFieldRef:
  limits.memory` + `resizePolicy` memory `RestartContainer`.
- `validate` helper: `fail` messages state what to change.

## Security defaults (PSS restricted, no override needed)

- Pod: `runAsNonRoot`, `runAsUser`/`runAsGroup`/`fsGroup` = image `USER`,
  `seccompProfile: RuntimeDefault`, safe sysctls only if useful.
- Container: `allowPrivilegeEscalation: false`, `privileged: false`,
  `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true`, same uid/gid,
  `seccompProfile: RuntimeDefault`.
- `automountServiceAccountToken: false` (unless the app calls the API),
  `enableServiceLinks: false`.
- Ask before defaulting `hostUsers: false`, `appArmorProfile`,
  `supplementalGroupsPolicy: Strict`: each fails on some nodes.

## Availability defaults

- `replicaCount: 3`; HPA `minReplicas: 3`.
- Preferred pod anti-affinity (hostname) + zone `topologySpreadConstraints`
  `ScheduleAnyway`; a user value replaces each.
- `nodeSelector: {kubernetes.io/os: linux}`.
- `minReadySeconds`, `revisionHistoryLimit`, RollingUpdate
  `maxUnavailable: 0`.
- `dnsConfig.options: [{name: ndots, value: "2"}]`.
- Probes: startup + readiness on "ready", liveness on a cheap "alive"
  endpoint (upstream outage must not restart pods).
- Resources: requests floor + memory limit, no CPU limit for
  latency-sensitive apps; measure on kind.

## Optional objects (each with a render case)

- HPA `autoscaling/v2`, slow scale-down. Guard: Resource metric needs the
  matching request.
- VPA `autoscaling.k8s.io/v1`, `Off` by default. Guard: not on an HPA
  resource unless `Off`.
- PDB: `maxUnavailable: 1`, `unhealthyPodEvictionPolicy: AlwaysAllow`.
- NetworkPolicy **on by default**: ingress metrics port only (`from`
  configurable); egress opt-in, DNS and upstream peers configurable.
- ServiceMonitor xor PodMonitor (schema); metrics Service only when needed;
  no debug endpoints exposed by default.

## helm test

- Labels must not match the selector: `app.kubernetes.io/name: <name>-test`,
  `app.kubernetes.io/component: test`.
- Render only when a replica can answer (not with `replicaCount: 0`).
- Same image and security contexts, `restartPolicy: Never`.

## Tests and ct values

- `tests/cases/<case>.yaml`: `values: {...}`, optional
  `expect: {error: "<stderr substring>"}`; failing cases `error-*.yaml`.
- Minimum cases: defaults, each mode, `full` (all optional objects), each
  rendering toggle, each guard, each schema rule, unknown top-level key.
- `ci/<mode>-values.yaml` per mode, commented; `replicaCount: 0` when the
  app needs a real backend.

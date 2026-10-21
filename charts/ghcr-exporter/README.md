# ghcr-exporter

Prometheus exporter for GitHub Container Registry package metrics (ghcr-exporter) running as a hardened Deployment

Runs [ghcr-exporter](https://github.com/d0ugal/ghcr-exporter) as a single
Deployment. It polls the GitHub API (and the package pages on github.com, for
download counts) with a token and exports the metrics of the container packages
you list. Each replica would poll GitHub on its own and export duplicate
series, so the schema caps `replicaCount` at 1.

## Install

The exporter needs a GitHub token (a classic personal access token with
`read:packages`) and the packages to watch.

With an existing Secret (preferred: the token stays out of Helm values, release
history and Git):

```sh
kubectl create namespace ghcr-exporter
kubectl -n ghcr-exporter create secret generic ghcr-exporter --from-literal=token=<token>
helm install ghcr-exporter oci://ghcr.io/spnngl/charts/ghcr-exporter --version <version> -n ghcr-exporter \
  --set 'packages[0].owner=spnngl' --set 'packages[0].repo=charts'
```

The Secret is named after the release (`github.existingSecret.name` to
override, `key` defaults to `token`). Or let the chart create it with
`--set github.token=<token>` (Secret `<fullname>`, key `github.existingSecret.key`):
the token then lives in the Helm release and in every values file or GitOps
repo that sets it.

Without a token or a Secret the pod stays in `CreateContainerConfigError`
(`secret "ghcr-exporter" not found`) until the Secret exists.

`packages` is a list of `{owner, repo}`: `owner` is a user or an organization;
an empty `repo` watches every container package of the owner. An empty list
makes the exporter run and export nothing.

The token is visible in the container environment (upstream reads it from the
config file or the environment only) and is read at startup: after rotating
it, restart the pod,

```sh
kubectl -n ghcr-exporter rollout restart deployment/ghcr-exporter
```

or let [Reloader](https://github.com/stakater/Reloader) do it with
`podAnnotations: {reloader.stakater.com/auto: "true"}`. Changing `github.token`
or `packages` through Helm rolls the pod by itself.

## Image

The default image is `appVersion` pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates both
together, weekly). Setting `image.tag` drops that digest; add `image.digest` to
pin the tag again (`image.digest` without `image.tag` is an error).

The upstream image is not signed (no cosign signature, no attestations,
checked on v2.13.66). The digest pin only guarantees that the same bytes are
pulled every time, not who built them.

## Configuration

- `collectionIntervalSeconds` (default 60) is the interval of every
  collection. Each package costs 2 to 4 GitHub API calls per collection
  (more with owner-wide discovery): at 60s that is 120 to 240 requests per
  hour, and a token allows 5000. Raise the interval beyond 20 to 40 packages.
  The package pages on github.com are scraped without authentication and may
  answer HTTP 429.
- Upstream ignores the `server`, `logging`, `metrics`, `tracing` and
  `profiling` keys of its config file (an upstream bug: the embedded base
  config is not inlined), which is why the chart renders only `packages` there
  and passes the rest as environment variables. Tracing and profiling are
  reachable through `extraEnv` (`TRACING_*`, `PROFILING_*`); names the chart
  owns and `GHCR_EXPORTER_PACKAGES_*` are rejected.
- The exporter logs every HTTP request at `info`, probes included: the probes
  run every 30s to keep the logs quiet; `logLevel: warn` silences them.
- `/health` answers 200 once the server listens, whatever GitHub does: a
  GitHub outage or a bad token never restarts or unreadies the pod. Watch
  `ghcr_collection_failed_total` (or the alerts below) instead.

## Resources

Requests `10m` CPU / `32Mi` memory and a `128Mi` memory limit, no CPU limit.
These are estimates, not measurements under a real collection: tune them for
your package count. With a memory limit set, `GOMEMLIMIT` follows it, and a
memory resize restarts the container so the value never goes stale.

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 1001,
read-only root filesystem, all capabilities dropped, no privilege escalation,
`RuntimeDefault` seccomp, no ServiceAccount token, no Service environment
variables. The exporter writes nothing to disk.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 1001 in the
pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support (containerd
2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+; see the Kubernetes
documentation on user namespaces. On other nodes the pod sandbox cannot be
created (`FailedCreatePodSandBox` event): set `hostUsers: true`.

## Network

- **Warning**: the metrics port also serves the `/` dashboard, which shows the
  exporter configuration (token redacted). The NetworkPolicy
  (`networkPolicy.enabled`, on by default) restricts ingress to port 8080, but
  with `networkPolicy.metrics.from: []` any in-cluster source is allowed: set
  it to your Prometheus namespace / pods.
- `networkPolicy.egress.enabled` (off by default) allows DNS, HTTPS to GitHub
  (`api.github.com` and `github.com`) and `networkPolicy.egress.extraEgress`
  (for example a tracing endpoint). GitHub has no stable address, so
  `egress.github.to` defaults to any address. Narrow it to GitHub's published
  ranges (API calls hit `api.github.com`, download counts hit `github.com`;
  regional `/32`s serve clusters outside the US and EU):

  ```sh
  curl -s https://api.github.com/meta | jq '[.api[], .web[]] | unique'
  ```

  The list changes over time: refresh it. Override `dns.to` for NodeLocal DNSCache
  or a non-default DNS namespace.
- `metrics.serviceMonitor` or `metrics.podMonitor` (not both) integrate with
  the Prometheus Operator; a PodMonitor needs no Service. A ClusterIP Service
  on port 8080 is always created.
- `metrics.prometheusRule` adds alerts and needs one of the monitors (the
  rules select the `job` label it sets; do not rewrite `job` in
  `relabelings`): `GhcrExporterDown` (critical, also fires with
  `replicaCount: 0` or a Pending pod), `GhcrExporterCollectionFailing`,
  `GhcrExporterCollectionStale` and `GhcrExporterDownloadsUnknown` (warning).
  The last one fires when a download count stays unreadable for an hour: the
  count is scraped from the package page on github.com, and a failed scrape
  sets `ghcr_package_downloads` to `-1` without failing the collection.
  Silence some with `metrics.prometheusRule.disabled`.
- `helm test` calls `/health` through the Service. It works with a fake token
  because `/health` does not depend on GitHub, so it checks the wiring, not
  the token. It exists only when `replicaCount` > 0.

## Compatibility

The values schema is strict: unknown keys fail the install. A breaking change
to values bumps the chart MAJOR version; deprecations are announced one MINOR
version ahead. Requires Kubernetes 1.33 or later.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| spnngl |  | <https://github.com/spnngl> |

## Source Code

* <https://github.com/spnngl/charts>
* <https://github.com/d0ugal/ghcr-exporter>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| collectionIntervalSeconds | int | `60` | Seconds between collections. Each package costs 2-4 GitHub API calls per collection (more with owner-wide discovery, `repo` empty): at 60s that is 120-240 requests per hour, and a token allows 5000. Raise the interval when you watch more than 20-40 packages. The package pages on github.com, scraped for download counts, are unauthenticated and may answer HTTP 429. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for `api.github.com`). |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list), for settings the config file ignores upstream: tracing (`TRACING_*`) and profiling (`PROFILING_*`). Names the chart owns, and `GHCR_EXPORTER_PACKAGES_*` (use `packages`), are rejected. Rendered after `GOMEMLIMIT`. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the exporter container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| github.existingSecret.key | string | `"token"` | Key of the token in the Secret. |
| github.existingSecret.name | string | `""` | Name of an existing Secret holding the token. Empty: `<fullname>`, the Secret created from `token`. Exclusive with `token`. |
| github.token | string | `""` | GitHub token (classic personal access token with `read:packages`). Set: the chart creates the Secret `<fullname>` (key `token`) and restarts the pod when it changes, but the token then lives in the Helm release and in your values files. Empty: the token is read from `existingSecret`. Exclusive with `existingSecret.name`. |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 1001 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/d0ugal/ghcr-exporter"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: `appVersion` pinned by the digest recorded in `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/health","port":"http-metrics"},"periodSeconds":30}` | Liveness probe, `/health`. It answers 200 once the HTTP server listens, whatever GitHub does: a GitHub outage never restarts the pod. |
| logFormat | string | `"json"` | Log format. |
| logLevel | string | `"info"` | Log level. The exporter logs every HTTP request at `info`, probes included. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor (no Service needed). Exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.prometheusRule.disabled | list | `[]` | Alerts to leave out (at most three: disable `prometheusRule` instead). `GhcrExporterDown` also fires when no target exists (pod Pending) and with `replicaCount: 0`. |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alerts `GhcrExporterDown`, `GhcrExporterCollectionFailing`, `GhcrExporterCollectionStale`, `GhcrExporterDownloadsUnknown`). Needs `serviceMonitor` or `podMonitor`: the rules select the `job` label it sets. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.prometheusRule.staleIntervals | int | `3` | `GhcrExporterCollectionStale` threshold: collection intervals without a successful collection. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. Exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| minReadySeconds | int | `10` | Seconds a new pod must be Ready before the old one is retired. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, GitHub, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s (for example a tracing endpoint). |
| networkPolicy.egress.github.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0"}},{"ipBlock":{"cidr":"::/0"}}]` | GitHub peers (port 443): `api.github.com` for the API and `github.com` for download counts. See the README to narrow the default to GitHub's published ranges. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: port 8080 only). |
| networkPolicy.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to reach port 8080. Empty: any source. The port also serves the `/` dashboard (configuration, token redacted): restrict it to your Prometheus. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. Merged with (and cannot drop) the default `kubernetes.io/os: linux`. |
| packages | list | `[]` | Packages to watch, rendered into the exporter config file. `owner` is a user or organization; an empty `repo` watches every container package of the owner. Empty list: the exporter runs and exports nothing. |
| podAnnotations | object | `{}` | Pod annotations (for example `reloader.stakater.com/auto: "true"` to restart on Secret rotation). |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":1001,"runAsGroup":1001,"runAsNonRoot":true,"runAsUser":1001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":1,"httpGet":{"path":"/health","port":"http-metrics"},"periodSeconds":30}` | Readiness probe, `/health`. The exporter logs every request at `info`: a long period keeps the logs quiet. |
| replicaCount | int | `1` | Number of exporters. More than one would poll GitHub several times with the same token and export duplicate series, so `1` is the maximum. `0` stops the exporter. |
| resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. Estimates, not measurements under real collection: tune them for your package count. No CPU limit on purpose. With a memory limit, `GOMEMLIMIT` follows it. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":1001,"runAsNonRoot":true,"runAsUser":1001,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. The ClusterIP Service on port 8080 is always created. |
| service.labels | object | `{}` | Extra Service labels. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"httpGet":{"path":"/health","port":"http-metrics"},"periodSeconds":2}` | Startup probe, `/health`. Restarts a pod that does not listen within `periodSeconds` x `failureThreshold` (60s). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |

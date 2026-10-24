# artifacthub-exporter

Prometheus exporter for Artifact Hub package and repository metrics (stars, versions, views, vulnerabilities, tracking status) running as a hardened Deployment

Runs [artifacthub-exporter](https://github.com/spnngl/artifacthub-exporter)
as a single Deployment. It polls the [Artifact Hub API](https://artifacthub.io/docs/api/)
in the background and serves the last collection on every scrape: stars,
versions, views, vulnerabilities and tracking status of the packages and
repositories you list, and optionally the totals of the hub. Scrapes never
call Artifact Hub. Each replica would poll Artifact Hub on its own, against
the same rate limit, and export duplicate series, so keep `replicaCount` at 1.

## Install

```sh
helm install artifacthub-exporter oci://ghcr.io/spnngl/charts/artifacthub-exporter --version <version> \
  -n artifacthub-exporter --create-namespace \
  --set 'artifacthub.orgs[0]=<organization>'
```

Targets, at least one (the exporter exits at startup without one, and the
chart refuses to render):

- `artifacthub.orgs`, `artifacthub.users` (by alias): their packages and
  repositories.
- `artifacthub.repositories`: a repository and its packages.
- `artifacthub.packages`: `kind/repository/name`, for example
  `helm/bitnami/redis`. The kind is an Artifact Hub slug (`helm`,
  `container`, `olm`, ...); an unknown kind makes the exporter exit at
  startup.
- `artifacthub.hubStats`: the totals of the hub (one request per
  collection). Empty by default: collected only when no other target is set,
  so the default install starts. Set `true` or `false` to choose.

A package or repository found by several targets is exported once.

### API key

The public API needs no key. To use one, create a Secret with the key id and
secret, then point the chart at it:

```sh
kubectl -n artifacthub-exporter create secret generic artifacthub-api-key \
  --from-literal=id=<key id> --from-literal=secret=<key secret>
helm upgrade --install artifacthub-exporter oci://ghcr.io/spnngl/charts/artifacthub-exporter --version <version> \
  -n artifacthub-exporter --set artifacthub.apiKey.existingSecret.name=artifacthub-api-key ...
```

The chart never creates the Secret: the key stays out of Helm values,
release history and Git. Upstream reads the key from its environment only (no
file option), so it is visible in the container environment. It is read at
startup: after rotating it, restart the pod,

```sh
kubectl -n artifacthub-exporter rollout restart deployment/artifacthub-exporter
```

or let [Reloader](https://github.com/stakater/Reloader) do it with
`podAnnotations: {reloader.stakater.com/auto: "true"}`.

## Image

Upstream ships a deb and an rpm, no image. The image is built in
[spnngl/images](https://github.com/spnngl/images/tree/main/containers/artifacthub-exporter)
from the upstream release commit: one static binary on `scratch` with the CA
bundle, uid/gid 65532, no shell. It is rebuilt when its Go toolchain or
Debian snapshot moves: the tag is the exporter version, the digest moves.

The default image is `appVersion` pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates both
together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (`image.digest` without `image.tag` is an error).

The image is signed with a key, not keyless like the charts, and carries a
SLSA provenance:

```sh
cosign verify --insecure-ignore-tlog=true --new-bundle-format=false \
  --key https://raw.githubusercontent.com/spnngl/images/main/bootc/fedora/sysroot/common/usr/share/pki/containers/spnngl-images.pub \
  ghcr.io/spnngl/images/artifacthub-exporter@<digest>
docker buildx imagetools inspect ghcr.io/spnngl/images/artifacthub-exporter@<digest> --format '{{ json .Provenance }}'
```

The signature is not uploaded to the Rekor transparency log
(`--insecure-ignore-tlog`) and uses the legacy signature format
(`--new-bundle-format=false`).

## Configuration

- Every upstream setting is a value; the chart owns the environment variables
  (`ARTIFACTHUB_*`, `COLLECT_INTERVAL`, `WEB_ADDR`, `WEB_PATH`) and `extraEnv`
  rejects them. Use `extraEnv` for the rest, for example `HTTPS_PROXY`.
- Target entries are joined with commas: they cannot contain commas, quotes
  or whitespace.
- **Rate limit.** Artifact Hub answers 429 past roughly 100 requests a minute
  (undocumented). The exporter sends one request a second and retries a 429
  (after 30 s, then 60 s) or a 5xx a few times. A collection costs about 2
  requests per package and 1 per 60 packages listed, so about 2 seconds per
  package: an organization of 500 packages takes about 17 minutes, longer than
  the default interval. Prefer repositories or packages for large
  organizations. The limit applies per source address: other clients behind
  the same NAT share it.
- `artifacthub.collectInterval` is in minutes and hours (`15m`, `1h30m`),
  at least `5m`: the API caches its answers for 5 minutes, and the exporter
  exits at startup below it. The schema rejects shorter intervals.
- A target that fails keeps its previous metrics; a package never collected
  is left out until a later collection succeeds. Each failure counts in
  `artifacthub_collection_errors_total` and holds back
  `artifacthub_collection_last_success_timestamp_seconds`. Alert on those,
  not on the pod status: the probes call `/`, a static page that answers 200
  whatever Artifact Hub does (upstream has no health endpoint), so an outage
  never restarts or unreadies the pod.
- The exporter logs to stderr with no level or format option.

## Resources

Requests `10m` CPU / `32Mi` memory and a `128Mi` memory limit, no CPU limit.
Measured on kind: about 10Mi of memory and 0.2 s of CPU time for a collection
of a 47-package repository, one package and the hub totals. Memory grows with
the number of packages: tune for large organizations. With a memory limit set,
`GOMEMLIMIT` follows it, and a memory resize restarts the container so the
value never goes stale.

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid
65532 (the image's), read-only root filesystem, all capabilities dropped, no
privilege escalation, `RuntimeDefault` seccomp, no ServiceAccount token, no
Service environment variables. The exporter writes nothing to disk.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support (containerd
2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+; see the Kubernetes
documentation on user namespaces. On other nodes the pod sandbox cannot be
created (`FailedCreatePodSandBox` event): set `hostUsers: true`.

## Network

- The NetworkPolicy (`networkPolicy.enabled`, on by default) restricts ingress
  to port 8080, but with `networkPolicy.metrics.from: []` any in-cluster source
  is allowed: set it to your Prometheus namespace / pods.
- `networkPolicy.egress.enabled` (off by default) allows DNS, HTTPS (port 443)
  to Artifact Hub and `networkPolicy.egress.extraEgress`. `artifacthub.io` is
  served by CloudFront, which has no stable address, so
  `egress.artifacthub.to` defaults to any address. An `artifacthub.url` on
  another port, or a proxy, needs `extraEgress`. Override `dns.to` for
  NodeLocal DNSCache or a non-default DNS namespace.
- `metrics.serviceMonitor` or `metrics.podMonitor` (not both) integrate with
  the Prometheus Operator; a PodMonitor needs no Service. The ClusterIP
  Service `<fullname>-metrics` on port 8080 is rendered with a ServiceMonitor,
  or with `metrics.service.enabled`.
- `metrics.prometheusRule` adds alerts and needs one of the monitors (the
  rules select the `job` label it sets; do not rewrite `job` in
  `relabelings`):
  - `ArtifactHubExporterDown` (critical): no exporter up for `downFor`; also
    fires with `replicaCount: 0` or a Pending pod.
  - `ArtifactHubCollectionStale` (warning): a target not collected for
    `collectionStaleSeconds`. Keep it above the interval plus a collection's
    duration.
  - `ArtifactHubCollectionErrors` (warning): a target failing in every
    `collectionErrorsFor` window, for that long; it also covers targets never
    collected, which have no timestamp.

  Silence some with `metrics.prometheusRule.disabled`. Alerts on the
  packages themselves (vulnerabilities, repository tracking errors) are yours
  to write: see the upstream README for examples.
- No `helm test`: the image has no shell or HTTP client to run one.

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
* <https://github.com/spnngl/artifacthub-exporter>
* <https://github.com/spnngl/images/tree/main/containers/artifacthub-exporter>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. Empty on purpose: a single replica has nothing to spread. |
| artifacthub.apiKey.existingSecret.idKey | string | `"id"` | Key of the API key id in the Secret. |
| artifacthub.apiKey.existingSecret.name | string | `""` | Name of an existing Secret holding an Artifact Hub API key. Empty: no key (the public API needs none). The chart never creates it: upstream reads the key from its environment only (no file option), so the chart passes it with a `secretKeyRef`. |
| artifacthub.apiKey.existingSecret.secretKey | string | `"secret"` | Key of the API key secret in the Secret. |
| artifacthub.collectInterval | string | `"15m"` | Time between two collections, in minutes and hours (`15m`, `1h`, `1h30m`). At least `5m`: the API caches its answers for 5 minutes, and the exporter exits at startup below it. A collection longer than the interval delays the next one. |
| artifacthub.hubStats | string | `nil` | Collect the totals of the hub (`artifacthub_hub_packages`, `artifacthub_hub_releases`): one request per collection. Empty: only when no other target is set, so the default install collects something (the exporter exits at startup without a target). |
| artifacthub.orgs | list | `[]` | Organizations to collect (by name): their packages and repositories. An organization costs about 2 seconds per package per collection (see the README): prefer `repositories` or `packages` for large ones. |
| artifacthub.packages | list | `[]` | Packages to collect, `kind/repository/name` (`helm/bitnami/redis`). The kind is an Artifact Hub slug (`helm`, `container`, `olm`, ...): the exporter exits at startup on a kind it does not know. |
| artifacthub.repositories | list | `[]` | Repositories to collect (by name), with their packages. |
| artifacthub.url | string | `"https://artifacthub.io"` | Artifact Hub address. |
| artifacthub.users | list | `[]` | Users to collect (by alias): their packages and repositories. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for `artifacthub.io`). |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list), for example `HTTPS_PROXY`. Every upstream setting has a value: names the chart owns are rejected. Rendered after `WEB_PATH`. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the exporter container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/artifacthub-exporter"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: `appVersion` pinned by the digest recorded in `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/","port":"http-metrics"},"periodSeconds":10}` | Liveness probe, `/`. An Artifact Hub outage never restarts the pod. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor (no Service needed). Exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.prometheusRule.collectionErrorsFor | string | `"1h"` | `ArtifactHubCollectionErrors` window and duration: fires when every window of this length holds a failed collection of a target, for this long: repeated failures, not a single one. Covers targets never collected, which `ArtifactHubCollectionStale` cannot see. Keep it above `artifacthub.collectInterval` plus the duration of a collection, or a target failing every collection never fires it. |
| metrics.prometheusRule.collectionStaleSeconds | int | `3600` | `ArtifactHubCollectionStale` threshold, in seconds since a target's last successful collection. Keep it above `artifacthub.collectInterval` plus the duration of a collection (`artifacthub_collection_duration_seconds`), or it fires between two collections. |
| metrics.prometheusRule.disabled | list | `[]` | Alerts to leave out (at most two: disable `prometheusRule` instead). `ArtifactHubExporterDown` also fires when no target exists (pod Pending) and with `replicaCount: 0`. |
| metrics.prometheusRule.downFor | string | `"5m"` | `ArtifactHubExporterDown` duration. |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alerts `ArtifactHubExporterDown`, `ArtifactHubCollectionStale`, `ArtifactHubCollectionErrors`). Needs `serviceMonitor` or `podMonitor`: the rules select the `job` label it sets. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.service.annotations | object | `{}` | Service annotations. |
| metrics.service.enabled | bool | `false` | Render the metrics Service (also rendered when `serviceMonitor.enabled`). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. Exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| minReadySeconds | int | `10` | Seconds a new pod must be Ready before the old one is retired. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.artifacthub.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0"}},{"ipBlock":{"cidr":"::/0"}}]` | Artifact Hub peers (port 443). `artifacthub.io` is served by CloudFront, which has no stable address: any address by default. An `artifacthub.url` on another port needs `extraEgress`. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, Artifact Hub, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s (for example a proxy, or a self-hosted Artifact Hub). |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: port 8080 only). |
| networkPolicy.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to reach port 8080. Empty: any source. Restrict it to your Prometheus. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. Merged with (and cannot drop) the default `kubernetes.io/os: linux`. |
| podAnnotations | object | `{}` | Pod annotations (for example `reloader.stakater.com/auto: "true"` to restart on Secret rotation). |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":1,"httpGet":{"path":"/","port":"http-metrics"},"periodSeconds":10}` | Readiness probe, `/`. It answers 200 once the server listens, whatever Artifact Hub does: `/metrics` serves the last collection. |
| replicaCount | int | `1` | Number of exporters. Keep `1`: every replica polls Artifact Hub on its own (N replicas send N times the requests against the same rate limit, which answers 429 past roughly 100 a minute) and exports the same series (`sum()` counts them twice). An exporter outage only leaves a gap in the graphs. `0` stops the exporter. |
| resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. Measured on kind: about 10Mi of memory and 0.2s of CPU time for a collection of a repository of 47 packages, the hub totals and one package. Memory grows with the number of packages collected: tune for large organizations. No CPU limit on purpose. With a memory limit, `GOMEMLIMIT` follows it. |
| revisionHistoryLimit | int | `10` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"httpGet":{"path":"/","port":"http-metrics"},"periodSeconds":2}` | Startup probe, `/` (upstream has no health endpoint; `/` is a static page). Restarts a pod that does not listen within `periodSeconds` x `failureThreshold` (60s). |
| strategy.rollingUpdate | object | `{"maxSurge":1,"maxUnavailable":0}` | Used with `RollingUpdate` only. |
| strategy.type | string | `"RollingUpdate"` | Update strategy. `Recreate` stops the old exporter first (a gap in the graphs) instead of overlapping two for `minReadySeconds`. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty on purpose: a single replica has nothing to spread. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. Recommendations only by default. |

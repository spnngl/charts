# cloudflared

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 2026.10.0](https://img.shields.io/badge/AppVersion-2026.10.0-informational?style=flat-square)

Cloudflare Tunnel connector (cloudflared) running as a hardened, highly available Deployment

Runs [cloudflared](https://github.com/cloudflare/cloudflared) as a Deployment of
tunnel connectors. Every replica is one more connector of the same tunnel
(4 connections to Cloudflare each), so replicas give availability and capacity.
A DaemonSet is deliberately not offered: Cloudflare caps a tunnel at 25
replicas / 100 connections, and connectors do not need to run next to the
origins.

## Install

The chart never creates the tunnel Secret: credentials must not live in Helm
values, release history or Git. Create it first, then install.

### Token mode (default)

For a tunnel managed in the Cloudflare dashboard (remotely managed: ingress
rules live in Cloudflare, not in this chart).

```sh
kubectl create namespace cloudflared
kubectl -n cloudflared create secret generic cloudflared --from-file=token=./tunnel-token.txt
helm install cloudflared oci://ghcr.io/spnngl/charts/cloudflared --version <version> -n cloudflared
```

The Secret is named after the release (`tunnel.token.existingSecret.name` to
override, `key` defaults to `token`). Local `config.originRequest` and
`warp-routing` are ignored by cloudflared in this mode and rejected by the
schema.

### Credentials mode

For a tunnel created with `cloudflared tunnel create` (locally managed:
ingress rules are `tunnel.credentials.ingress` in this chart).

```sh
kubectl -n cloudflared create secret generic cloudflared --from-file=credentials.json=./<tunnel-uuid>.json
helm install cloudflared oci://ghcr.io/spnngl/charts/cloudflared --version <version> -n cloudflared \
  --set tunnel.mode=credentials --set tunnel.credentials.tunnel=<tunnel-uuid> \
  --values ingress.yaml   # tunnel.credentials.ingress: [..., {service: http_status:404}]
```

`tunnel.credentials.tunnel` must be the tunnel **UUID**: resolving a tunnel
name needs the account `cert.pem`, which the chart does not mount.

Other cloudflared options go in `config` (cloudflared `config.yaml` keys).
Keys the chart owns (`metrics`, `token-file`, `credentials-file`, `tunnel`,
`ingress`, `grace-period`, ...) are rejected there.

### Secret rotation

cloudflared reads the token / credentials once at startup. After rotating the
Secret, restart the pods:

```sh
kubectl -n cloudflared rollout restart deployment/cloudflared
```

or let [Reloader](https://github.com/stakater/Reloader) do it with
`podAnnotations: {reloader.stakater.com/auto: "true"}`.

## Image

The default image is `appVersion` pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates both
together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (`image.digest` without `image.tag` is an error).

Cloudflare does not sign the image (no cosign signature, no attestations,
checked on 2026.10.0). The digest pin only guarantees that the same bytes are
pulled every time, not who built them.

## Availability and scheduling

- 3 replicas, `RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1`, and a
  `terminationGracePeriodSeconds` of `gracePeriodSeconds + 15`: cloudflared
  drains connections on SIGTERM.
- Default spread: preferred pod anti-affinity on the hostname, preferred
  topology spread over zones. `affinity` / `topologySpreadConstraints`
  replace these defaults.
- Replicas (or `autoscaling.maxReplicas`) plus the rollout surge must stay
  at or below 25, the Cloudflare cap per tunnel. The chart fails otherwise.
- `podDisruptionBudget.enabled` is off by default.
- Origins: cloudflared resolves origin hostnames itself. Use fully qualified
  names with a trailing dot (`app.default.svc.cluster.local.`): with the
  cluster default `ndots`, a name with exactly two dots is otherwise tried
  against every search domain first. The chart sets `ndots: 2`.

## Autoscaling

- `autoscaling` (HPA) scales on CPU utilization by default. CPU
  `Utilization` is a percentage of `resources.requests.cpu`: with the 50m
  floor, the default 75% target fires at about 38m. Size the requests first
  (VPA in `Off` mode gives recommendations), or scale on a connection metric
  such as `cloudflared_tunnel_concurrent_requests_per_tunnel` through
  prometheus-adapter or KEDA: CPU is a weak signal for a network-bound proxy.
- Each pod removed drops four edge connections, hence the slow scale-down
  default (`stabilizationWindowSeconds: 300`).
- Enabling the HPA after install drops the Deployment `replicas` field: the
  first apply scales to 1 until the HPA acts (Kubernetes behaviour).
- `verticalPodAutoscaler` supports `Off`, `Initial`, `Recreate` and
  `InPlaceOrRecreate` (VPA 1.8+, in-place resize needs Kubernetes 1.33+).
  HPA and VPA must not act on the same resource: with the HPA on, keep the VPA
  in `Off` or drop that resource from `controlledResources`.

## Resources

The defaults are scheduling floors, not a sizing: requests `50m` CPU /
`64Mi` memory, a `256Mi` memory limit and no CPU limit (throttling adds
latency to a proxy). Cloudflare sizes whole hosts (4 CPU / 4 GiB for about
4000 WARP users), and throughput is bounded by ports, not CPU: the chart sets
`net.ipv4.ip_local_port_range` to `11000 60999` and cloudflared wants a
file-descriptor limit of at least 70000 (Go raises the soft limit to the
runtime's hard limit). Measure, then tune.

With a memory limit set, `GOMEMLIMIT` follows it, and a memory resize restarts
the container so the value never goes stale.

QUIC (UDP) benefits from larger socket buffers: raise `net.core.rmem_max` /
`net.core.wmem_max` on the nodes if cloudflared logs a buffer size warning.

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid
65532, read-only root filesystem, all capabilities dropped, no privilege
escalation, `RuntimeDefault` seccomp, no ServiceAccount token, no Service
environment variables. cloudflared needs no capability: ICMP proxying uses
unprivileged ICMP sockets, enabled by the `net.ipv4.ping_group_range` sysctl
(a safe sysctl).

Not defaulted, because each makes the kubelet refuse the pod on some nodes:
`appArmorProfile` (hosts without AppArmor) and `supplementalGroupsPolicy:
Strict` (runtimes without support). Set them in `podSecurityContext` /
`securityContext` if your nodes support them.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support
(containerd 2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+
(idmapped mounts on tmpfs for Secret and ConfigMap volumes); see the
Kubernetes documentation on user namespaces. On other nodes the pod sandbox
cannot be created (event on the pod, for example `error mounting "sysfs" to rootfs
... operation not permitted` on kind inside a CI runner): set `hostUsers: true`.

### Writable paths

The root filesystem is read-only and cloudflared writes nothing by default.
`logfile`, `log-directory`, `pidfile` and `trace-output` need a writable path:
add an `emptyDir` with `extraVolumes` / `extraVolumeMounts`.

## Network

- **Warning**: the metrics port also serves `/debug/pprof`, `/config` (remote
  ingress rules, origin URLs) and `/diag/*`. The NetworkPolicy
  (`networkPolicy.enabled`, on by default) restricts ingress to that port, but
  with `networkPolicy.metrics.from: []` any in-cluster source is allowed: set
  it to your Prometheus namespace / pods, and expose the port only through
  `metrics.service` / the monitors when needed.
- `networkPolicy.egress.enabled` (off by default) allows DNS and the Cloudflare
  edge (`7844`, TCP and UDP) only. Origins are not covered: add them in
  `networkPolicy.egress.extraEgress`. Override `dns.to` for NodeLocal DNSCache
  or a non-default DNS namespace, `edge.to` to restrict the edge ranges.
  Port 443 is not needed: cloudflared's start-up "Cloudflare API" precheck logs a
  failure without it, but it is informational (`hard_fail=false`) and the tunnel
  connects over 7844 (checked on kind with the policy enforced).
- `metrics.serviceMonitor` or `metrics.podMonitor` (not both) integrate with
  the Prometheus Operator; a PodMonitor needs no Service.
- `metrics.prometheusRule` adds alerts and needs one of the monitors (the
  rules select the `job` label it sets; do not rewrite `job` in
  `relabelings`). `CloudflaredTunnelDown` (critical) fires when no replica is
  ready while some are desired, from kube-state-metrics: `cloudflared_tunnel_ha_connections` cannot
  tell, it counts connections still retrying (an invalid token keeps it at 1
  while `/ready` returns 503). `CloudflaredRegistrationFailing` and
  `CloudflaredOriginErrors` (warning) read cloudflared's own metrics.
- `helm test` runs `cloudflared tunnel ready` against the metrics Service and
  succeeds once at least one connection is up (the Service only routes to ready
  pods, so it fails while no connector is registered). It exists only when the
  metrics Service is rendered (`metrics.service.enabled` or a ServiceMonitor) and
  there is at least one connector (`replicaCount` > 0 or autoscaling).

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
* <https://github.com/cloudflare/cloudflared>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. Empty: preferred podAntiAffinity on hostname. A non-empty value replaces that default wholesale. |
| autoscaling.behavior | object | `{"scaleDown":{"stabilizationWindowSeconds":300}}` | HPA behavior. Slow scale-down: each removed pod drops four edge connections. |
| autoscaling.enabled | bool | `false` | Create a HorizontalPodAutoscaler. Enabling it drops `replicas` from the Deployment: it falls to 1 until the HPA reacts. |
| autoscaling.maxReplicas | int | `10` | HPA maximum replicas (the rollout surge counts toward the 25 per tunnel cap). |
| autoscaling.metrics | list | `[{"resource":{"name":"cpu","target":{"averageUtilization":75,"type":"Utilization"}},"type":"Resource"}]` | Raw `autoscaling/v2` MetricSpec list. CPU `Utilization` is a percentage of `resources.requests.cpu`: with the 50m floor, 75% fires at ~38m, so size requests first. |
| autoscaling.minReplicas | int | `3` | HPA minimum replicas. |
| config | object | `{}` | Free-form cloudflared configuration (`config.yaml`), any flag works (loglevel, protocol, edge-ip-version, warp-routing, originRequest, ...). Chart-owned keys are rejected; `originRequest` and `warp-routing` are also rejected in `token` mode (remote configuration owns them). |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for origin FQDNs). |
| extraArgs | list | `[]` | Extra `cloudflared tunnel` options, placed after `--config` and before `run` (for example `--output=json`). `run`-only options do not parse there: set them in `config`. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the cloudflared container, for flags `config.yaml` does not read (for example `TUNNEL_LOG_OUTPUT: json`). Rendered after `GOMEMLIMIT`. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the cloudflared container. |
| extraVolumes | list | `[]` | Extra volumes (for example an origin CA bundle for `originRequest.caPool`, or an emptyDir for `logfile`/`pidfile`: the root filesystem is read-only). |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| gracePeriodSeconds | int | `30` | Drain time after SIGTERM (`grace-period`); `terminationGracePeriodSeconds` is this + 15. |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: container root/uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"docker.io/cloudflare/cloudflared"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: `appVersion` pinned by the digest recorded in `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/healthcheck","port":"metrics"},"periodSeconds":10}` | Liveness probe, `/healthcheck` (process alive only). Not `/ready`: an edge outage must not restart every pod, cloudflared reconnects by itself. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor (no Service needed). Exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.prometheusRule.disabled | list | `[]` | Alerts to leave out (at most two: disable `prometheusRule` instead). `CloudflaredTunnelDown` reads kube-state-metrics (`kube_deployment_status_replicas_available`, `kube_deployment_spec_replicas`): without it, it never fires. |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alerts `CloudflaredTunnelDown`, `CloudflaredRegistrationFailing`, `CloudflaredOriginErrors`). Needs `serviceMonitor` or `podMonitor`: the rules select the `job` label it sets. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.prometheusRule.originErrorRatio | float | `0.05` | `CloudflaredOriginErrors` threshold: share of proxied requests that failed to reach the origin (`request_errors / total_requests`, 5m rate). |
| metrics.service.annotations | object | `{}` | Service annotations. |
| metrics.service.enabled | bool | `false` | Render the metrics Service (also rendered when `serviceMonitor.enabled`; adds the `helm test` pod). |
| metrics.service.port | int | `2000` | Metrics port (cloudflared `metrics` listen port and Service port). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. Exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| minReadySeconds | int | `10` | Seconds a new connector must be Ready before an old one is retired (`/ready` is 200 after the first of four edge connections). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.edge.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0"}},{"ipBlock":{"cidr":"::/0"}}]` | Cloudflare edge peers (port 7844 TCP/UDP). |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, Cloudflare edge, `extraEgress`). Origins must be allowed through `extraEgress`. |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s (origins). |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: metrics port only). |
| networkPolicy.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to reach the metrics port. Empty: any source. The port also serves `/debug/pprof`, `/config` and `/diag/*`: restrict it to your Prometheus. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. Merged with (and cannot drop) the default `kubernetes.io/os: linux`. |
| podAnnotations | object | `{}` | Pod annotations (for example `reloader.stakater.com/auto: "true"` to restart on Secret rotation). |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget (`unhealthyPodEvictionPolicy: AlwaysAllow`). |
| podDisruptionBudget.maxUnavailable | int | `1` | Connectors that may be evicted at once. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"},"sysctls":[{"name":"net.ipv4.ip_local_port_range","value":"11000 60999"},{"name":"net.ipv4.ping_group_range","value":"65532 65532"}]}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":1,"httpGet":{"path":"/ready","port":"metrics"},"periodSeconds":10}` | Readiness probe, `/ready` (at least one active edge connection). |
| replicaCount | int | `3` | Number of connectors. Cloudflare allows 25 replicas per tunnel (the rollout surge counts). Ignored when `autoscaling.enabled`. |
| resources | object | `{"limits":{"memory":"256Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}` | Resources. A scheduling floor, not a sizing: measure, then tune (VPA in `Off` mode gives recommendations). No CPU limit on purpose. With a memory limit, `GOMEMLIMIT` follows it. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/ready","port":"metrics"},"periodSeconds":2}` | Startup probe, `/ready` (waits for the first edge connection). |
| strategy.rollingUpdate.maxSurge | int | `1` | Extra connectors during a rollout (count toward the 25 per tunnel cap). |
| strategy.rollingUpdate.maxUnavailable | int | `0` | Connectors that may be unavailable during a rollout. |
| strategy.type | string | `"RollingUpdate"` | Deployment strategy type. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty: spread over `topology.kubernetes.io/zone` (`ScheduleAnyway`). A non-empty value replaces that default. |
| tunnel.credentials.existingSecret.key | string | `"credentials.json"` | Key of the credentials file in the Secret. |
| tunnel.credentials.existingSecret.name | string | `""` | Name of the Secret holding `credentials.json`. Empty: `<fullname>`. The chart never creates it. |
| tunnel.credentials.ingress | list | `[]` | Ingress rules, last one must be a catch-all (validated by cloudflared). Required in `credentials` mode. |
| tunnel.credentials.tunnel | string | `""` | Tunnel UUID (required in `credentials` mode; a name lookup would need `cert.pem`). |
| tunnel.mode | string | `"token"` | `token`: remotely-managed tunnel (ingress rules live in the Cloudflare dashboard/API). `credentials`: locally-managed tunnel (ingress rules in `tunnel.credentials.ingress`). |
| tunnel.token.existingSecret.key | string | `"token"` | Key of the token in the Secret. |
| tunnel.token.existingSecret.name | string | `""` | Name of the Secret holding the tunnel token. Empty: `<fullname>`. The chart never creates it. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. Not combinable with an HPA acting on the same resource. |

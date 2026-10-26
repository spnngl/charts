# numa-dns

Numa DNS resolver (ad blocking, local zones, DoT and DoH behind an ingress) running as a hardened, highly available Deployment

Runs [numa](https://github.com/razvandimescu/numa), a recursive-capable DNS
forwarder with caching and ad blocking, as a stateless Deployment. The chart
is a cluster DNS service: in-cluster clients use the Service on port 53, and
remote clients (a laptop) reach it through an ingress controller over DoT
(DNS over TLS) or DoH (DNS over HTTPS).

## Install

```sh
helm install numa-dns oci://ghcr.io/spnngl/charts/numa-dns --version <version> -n numa-dns --create-namespace
```

In-cluster clients query `numa-dns.numa-dns.svc` on port 53 (UDP and TCP).
Cluster names (`*.cluster.local`) are forwarded to the cluster DNS numa finds
in the pod's `resolv.conf`, so they keep resolving; `dnsPolicy: Default` turns
that off. IPv4 only.

## Configuration

`config` is numa's own `numa.toml` as YAML: every numa key works (`zones`,
`blocking`, `cache`, `upstream`, ...), see the
[numa documentation](https://github.com/razvandimescu/numa). The defaults are
the image's configuration. numa reads it once at start, so a change rolls the
pods (`checksum/config`).

- The chart owns the listeners: `server.bind_addr`, `server.api_bind_addr`,
  `dot.enabled`, `lan.enabled`, `mobile.enabled`, `proxy.bind_addr`,
  `proxy.enabled`, `proxy.port` and `proxy.tls_port` are rejected by the
  schema.
- `config.server.allow_from` is required and cannot be empty: an empty list
  disables numa's ACL and answers every client. It must contain the source
  address of every client, the ingress controller included.
- An invalid `allow_from` entry stops numa at start (`CrashLoopBackOff`), and
  `0.0.0.0/0` is accepted (numa only warns): the schema checks neither.
- Keys the schema leaves open but the chart relies on:
  - `server.api_port` (default 5380) is the port the dashboard commands below
    forward.
  - `server.data_dir` must stay on a writable volume; the default `emptyDir`
    holds `/var/lib/numa`.
  - `server.api_token` lands in the ConfigMap in plaintext. Set `NUMA_API_TOKEN`
    from a Secret instead (`extraEnv` with a `secretKeyRef`); it takes
    precedence over the config and the generated token.
  - `server.proxy_protocol.from` drops every TCP DNS peer outside it,
    in-cluster clients included; use it on `proxy` only (see
    [Client addresses](#client-addresses)).
  - `proxy.cert_path`, `proxy.key_path` and `proxy.tld` need volumes or
    host handling the chart does not provide (`proxy.tld` is the trap above).
- A misspelt key does not fail: numa logs ``unknown key `<key>` is ignored``
  and carries on. Check the logs after a change.
- `proxy.tld` stays `numa`: numa answers DNS for that name and its
  subdomains itself, so a public host name there would hide the real one.

## Remote access

The Service is ClusterIP only: exposure is the ingress controller's job, and
UDP 53 never leaves the cluster (no amplification surface). TLS ends at the
controller, so the chart holds no certificate and numa's own DoT listener is
off. Certificates come from the Ingress `tls` section (cert-manager, a default
certificate, ...).

- **DoH**: `ingress` routes `https://<host>/dns-query` to the `doh` Service
  port. numa serves DoH on its TLS listener only, with a certificate of its own
  CA and for a `Host` of `localhost`: the controller must use TLS to the
  backend without verifying it, and rewrite `Host` to `localhost`. The `doh`
  Service port carries `appProtocol: https` for controllers that read it.
- **DoT**: `extraIngresses` item with `port: dns-tcp`, for controllers that
  route TCP from an Ingress. The controller offloads TLS on port 853 and
  forwards plain DNS over TCP to the Service.

Example for [haproxy-ingress](https://haproxy-ingress.github.io), with
DoH and DoT on `dns.example.com`:

```yaml
config:
  server:
    allow_from:
      - 10.0.0.0/8   # the pod network, where haproxy-ingress reaches numa from
ingress:
  enabled: true
  className: haproxy
  annotations:
    haproxy-ingress.github.io/backend-protocol: h1-ssl
    haproxy-ingress.github.io/config-backend: |
      http-request set-header Host localhost
  hosts:
    - dns.example.com
  tls:
    - hosts:
        - dns.example.com
extraIngresses:
  - nameSuffix: dot
    className: haproxy
    port: dns-tcp
    annotations:
      haproxy-ingress.github.io/tcp-service-port: "853"
    hosts:
      - dns.example.com
    tls:
      - hosts:
          - dns.example.com
```

Port 853/tcp must be reachable on the controller (node firewall, load
balancer). Other controllers: route TCP 853 with TLS offload to `dns-tcp`, and
HTTPS `/dns-query` to `doh` over TLS with `Host` rewritten to `localhost`.
`labels` and `annotations` carry controller specifics, such as the labels an
external-dns instance filters on. A CDN or HTTP proxy in front must pass TCP
853 through, or serve DoH only.

### Open resolver

Anyone who can reach the host name can query it from the Internet. numa
sees every remote query as coming from the ingress controller, whose address
is in `config.server.allow_from` (it has to be, or nothing would work), so
`allow_from` cannot tell remote clients apart. Restrict who reaches the
controller instead (firewall, controller allowlist), and prefer a VPN
(Tailscale, WireGuard) for private use. There is no rate limiting.

### Clients

- systemd-resolved: `DNS=<ip>#dns.example.com` and `DNSOverTLS=yes` in
  `resolved.conf`.
- macOS: a configuration profile with a `DNSSettings` payload (`DNSProtocol`
  `TLS` with `ServerName`, or `HTTPS` with `ServerURL`
  `https://dns.example.com/dns-query`).
- Browsers: set the DoH URL to `https://dns.example.com/dns-query`.
- Check: `kdig +tls @dns.example.com example.com` and
  `kdig +https @dns.example.com example.com`.

### Client addresses

numa sees the controller's pod-network address for remote queries, so the
query log shows that address. For real client addresses on DoH, enable PROXY
protocol v2 on the DoH listener only, with the controller's source range:

```yaml
config:
  proxy:
    proxy_protocol:
      from: [10.0.0.0/8]
ingress:
  annotations:
    haproxy-ingress.github.io/proxy-protocol: v2
```

Do not enable it on `config.server`: a non-empty `from` drops every peer
outside it, in-cluster DNS clients included. Real addresses on DoT need
numa's own DoT listener, which the chart does not enable.

## Dashboard

The web UI and REST API listen on loopback in each pod and give full admin
access to anything that reaches them, without a token. Reach one pod with:

```sh
kubectl -n numa-dns port-forward deploy/numa-dns 5380:5380
```

It reads statistics, the last 1000 queries (client address and name), the
cache and blocklist state; it writes overrides (any name to any address), cache
flushes, blocking on/off and allow/blocklist entries. Writes land in that one
pod and its `emptyDir`: other replicas never see them and a restart loses
them. Use `config` for anything durable.

numa also logs every query (client address, name, outcome) at INFO on stdout,
and the API token at start: whoever reads the pod logs reads both. Set
`extraEnv: [{name: RUST_LOG, value: warn}]` to stop both (numa uses
`env_logger`; `numa::ctx` logs queries, `numa::serve` the token).
At start numa warns `bootstrap_resolver: skipping non-IP fallback` for the
default `upstream.fallback` (a DoH URL). The entry still serves as a fallback
upstream; numa only leaves it out of its own bootstrap resolver (Quad9 and
Cloudflare over plain DNS), because that one takes IP literals only. The
warning is harmless; set `upstream.fallback` to IP addresses to silence it.

## Image

The default image is `appVersion` pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates both
together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (`image.digest` without `image.tag` is an error).

The image is built and signed by [spnngl/images](https://github.com/spnngl/images)
(cosign key signature and GitHub build attestation).

## Availability and scheduling

- 3 replicas, `RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1`.
  numa exits at once on SIGTERM, so a `preStop` sleep of 5 s lets the endpoint
  removal propagate first; in-flight queries are otherwise dropped.
- Default spread: preferred pod anti-affinity on the hostname, preferred
  topology spread over zones. `affinity` / `topologySpreadConstraints`
  replace these defaults.
- `podDisruptionBudget.enabled` is off by default.
- Probes: startup on the DoH listener (numa only warns when it cannot bind or
  has no certificate, so the probe turns that into a failed start), readiness
  and liveness on DNS over TCP. numa's `/health` always answers 200 and tells
  nothing more than the socket.
- Each pod has its own cache, blocklists and `emptyDir`; nothing is shared or
  persisted.

## Autoscaling

- `autoscaling` (HPA) scales on CPU utilization by default. CPU
  `Utilization` is a percentage of `resources.requests.cpu`: with the 50m
  floor, the default 75% target fires at about 38m. Size the requests first
  (VPA in `Off` mode gives recommendations).
- A removed pod drops its cache, hence the slow scale-down default
  (`stabilizationWindowSeconds: 300`).
- Enabling the HPA after install drops the Deployment `replicas` field: the
  first apply scales to 1 until the HPA acts (Kubernetes behaviour).
- `verticalPodAutoscaler` supports `Off`, `Initial`, `Recreate` and
  `InPlaceOrRecreate` (VPA 1.8+, in-place resize needs Kubernetes 1.33+). HPA
  and VPA must not act on the same resource: with the HPA on, keep the VPA in
  `Off` or drop that resource from `controlledResources`.

## Resources

The defaults are scheduling floors, not a sizing: requests `50m` CPU /
`64Mi` memory, a `256Mi` memory limit and no CPU limit (throttling adds
latency to DNS). Measured on kind with the default blocklist: about 26 MiB
after start, about 140 MiB (peak 143 MiB) once the cache holds its default
100000 entries (`config.cache.max_entries`, about 1 KiB per entry), so the
limit leaves about 80% headroom. Raise `resources.requests.memory` if your
cache runs full; lower `max_entries` to cap memory. Measure, then tune. The `/var/lib/numa`
`emptyDir` (numa's CA, API token, blocklist cache) is capped by
`dataSizeLimit`.

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid
65532, read-only root filesystem, all capabilities dropped, no privilege
escalation, `RuntimeDefault` seccomp, no ServiceAccount token, no Service
environment variables. numa listens on unprivileged ports (8053, 8443) and
the Service maps them to 53 and 443.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support
(containerd 2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+
(idmapped mounts on tmpfs for Secret and ConfigMap volumes). On other nodes the
pod sandbox cannot be created: set `hostUsers: true`.

## Network

- The NetworkPolicy (`networkPolicy.enabled`, on by default) allows the DNS
  port (8053) and the DoH port (8443); the plain proxy port (8080) is never
  allowed. With `networkPolicy.ingress.from: []` any source is allowed,
  because an ingress controller on the host network cannot be selected by a
  `podSelector`; `config.server.allow_from` still filters by address.
- `networkPolicy.egress.enabled` (off by default) allows cluster DNS, and
  53, 443 and 853 to `egress.upstreams.to` (default: anywhere). Narrow
  `upstreams.to` to the resolvers in `config.upstream` and the hosts of
  `config.blocking`; override `dns.to` for NodeLocal DNSCache or a
  non-default DNS namespace. Upstreams on other ports (a custom
  `config.upstream` port, ODoH) are blocked by the default ports.
- numa exposes no Prometheus metrics, so there is no ServiceMonitor, and the
  image has no DNS client, so there is no `helm test`.

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
* <https://github.com/razvandimescu/numa>
* <https://github.com/spnngl/images/tree/main/containers/numa-dns>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. Empty: preferred podAntiAffinity on hostname. A non-empty value replaces that default wholesale. |
| autoscaling.behavior | object | `{"scaleDown":{"stabilizationWindowSeconds":300}}` | HPA behavior. Slow scale-down: a removed pod drops its cache and its in-flight queries. |
| autoscaling.enabled | bool | `false` | Create a HorizontalPodAutoscaler. Enabling it drops `replicas` from the Deployment: it falls to 1 until the HPA reacts. |
| autoscaling.maxReplicas | int | `10` | HPA maximum replicas. |
| autoscaling.metrics | list | `[{"resource":{"name":"cpu","target":{"averageUtilization":75,"type":"Utilization"}},"type":"Resource"}]` | Raw `autoscaling/v2` MetricSpec list. CPU `Utilization` is a percentage of `resources.requests.cpu`: with the 50m floor, 75% fires at ~38m, so size requests first. |
| autoscaling.minReplicas | int | `3` | HPA minimum replicas. |
| config | object | `{"server":{"allow_from":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","fc00::/7","fe80::/10"]},"upstream":{"address":["tls://1.1.1.1#cloudflare-dns.com","tls://1.0.0.1#cloudflare-dns.com","tls://8.8.8.8#dns.google","tls://8.8.4.4#dns.google"],"fallback":"https://1.1.1.1/dns-query","mode":"forward"}}` | Free-form numa configuration, rendered to `numa.toml` (every key of numa's own `numa.toml` works: `[[zones]]` as `zones`, `blocking`, `cache`, ...). The default is the image's configuration. Chart-owned keys are rejected: `server.bind_addr`, `server.api_bind_addr`, `dot.enabled`, `lan.enabled`, `mobile.enabled`, `proxy.bind_addr`, `proxy.enabled`, `proxy.port`, `proxy.tls_port`. Read once at start; a change rolls the pods. numa logs an unknown key and carries on. |
| config.server.allow_from | list | `["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","fc00::/7","fe80::/10"]` | Client addresses numa answers, loopback always. An empty list would answer the whole Internet: at least one entry. Must contain the source address of every client, the ingress controller included. |
| dataSizeLimit | string | `"64Mi"` | Size limit of the `emptyDir` on `/var/lib/numa` (CA, API token, blocklist cache). |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for numa's own name lookups, such as blocklist hosts). |
| dnsPolicy | string | `"ClusterFirst"` | Pod DNS policy. `ClusterFirst`: numa forwards `cluster.local` names to the cluster DNS it finds in `resolv.conf`. `Default` turns that off. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the numa container. numa logs through `env_logger` at `info`, so every query (client address, name) and the API token reach stdout: `RUST_LOG=warn` stops both (`numa::ctx` logs queries, `numa::serve` the token). |
| extraIngresses | list | `[]` | More Ingresses, for example DoT next to a DoH `ingress`. Each item takes the `ingress` keys (`port` defaults to `doh`) plus a required, unique `nameSuffix`: the object is named `<fullname>-<nameSuffix>`. `hosts` is required. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the numa container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: container uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/numa-dns"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: `appVersion` pinned by the digest recorded in `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations (controller specifics, for example `haproxy-ingress.github.io/tcp-service-port`). |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress. Read [Remote access](#remote-access) first. |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels. |
| ingress.port | string | `"doh"` | Service port the Ingress routes to. `doh`: path `/dns-query` (Exact) to the DNS-over-HTTPS port, TLS to the pod. `dns-tcp`: path `/` to DNS over TCP, for controllers that route TCP from an Ingress (DoT). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"tcpSocket":{"port":"dns-tcp"}}` | Liveness probe: the DNS-over-TCP listener (8053). numa has no "alive" endpoint beyond the socket; an upstream outage does not close it. |
| minReadySeconds | int | `5` | Seconds a new pod must be Ready before an old one is retired. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | Cluster DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (cluster DNS, upstreams). |
| networkPolicy.egress.upstreams.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0"}}]` | Upstream and blocklist peers (53 TCP/UDP, 443 and 853 TCP). Narrow it to the resolvers in `config.upstream` and the hosts of `config.blocking`. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: DNS on 8053, DoH on 8443; the plain proxy port 8080 is never allowed). |
| networkPolicy.ingress.from | list | `[]` | NetworkPolicyPeer list allowed to reach 8053 and 8443. Empty: any source, because an ingress controller on the host network cannot be selected by a `podSelector`. `config.server.allow_from` still filters by client address. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. Merged with (and cannot drop) the default `kubernetes.io/os: linux`. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget (`unhealthyPodEvictionPolicy: AlwaysAllow`). |
| podDisruptionBudget.maxUnavailable | int | `1` | Pods that may be evicted at once. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":2,"periodSeconds":5,"tcpSocket":{"port":"dns-tcp"}}` | Readiness probe: the DNS-over-TCP listener (8053). |
| replicaCount | int | `3` | Number of replicas. Ignored when `autoscaling.enabled`. |
| resources | object | `{"limits":{"memory":"256Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}` | Resources. A scheduling floor, not a sizing: measure, then tune (VPA in `Off` mode gives recommendations). No CPU limit on purpose: throttling adds latency to DNS. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. The Service is ClusterIP only: exposure is the ingress controller's job. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":2,"tcpSocket":{"port":"doh"}}` | Startup probe: the DoH listener (8443). numa only warns when it fails to bind or has no certificate, so this turns that into a failed start. |
| strategy.rollingUpdate.maxSurge | int | `1` | Extra pods during a rollout. |
| strategy.rollingUpdate.maxUnavailable | int | `0` | Pods that may be unavailable during a rollout. |
| strategy.type | string | `"RollingUpdate"` | Deployment strategy type. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty: spread over `topology.kubernetes.io/zone` (`ScheduleAnyway`). A non-empty value replaces that default. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. Not combinable with an HPA acting on the same resource. |

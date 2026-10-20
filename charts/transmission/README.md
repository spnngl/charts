# transmission

Transmission BitTorrent daemon and web UI as a hardened single-replica StatefulSet, with an optional Prometheus exporter sidecar

Runs [Transmission](https://github.com/transmission/transmission)
(`transmission-daemon` and its web UI) as a single-replica StatefulSet, with an
optional [transmission-exporter](https://github.com/spnngl/transmission-exporter)
sidecar for Prometheus. Both images are built from
[spnngl/images](https://github.com/spnngl/images): distroless, non-root, no shell.

One replica only: the daemon is the sole writer of its state and owns one peer
identity. Every upgrade or reschedule is a short downtime (the daemon gets 30
seconds to save its resume data on SIGTERM).

## Install

The chart never creates the login Secret: credentials must not live in Helm
values, release history or Git. Create it first, then install.

```sh
kubectl create namespace transmission
kubectl -n transmission create secret generic transmission \
  --from-literal=username=<user> --from-literal=password=<password>
helm install transmission oci://ghcr.io/spnngl/charts/transmission --version <version> -n transmission
```

The Secret is named after the release (`auth.existingSecret.name`, `usernameKey`
and `passwordKey` to override). The daemon reads the login once at startup (it
is passed as `--username` / `--password`, so the Secret is not written into
`settings.json`): restart the pod after changing it.

```sh
kubectl -n transmission rollout restart statefulset/transmission
```

`auth.enabled: false` runs with `--no-auth`. The web UI is then open to anything
that can reach the Service: keep the NetworkPolicy, or put an authenticating proxy in front.

### Settings

Other Transmission options go in `config` (`settings.json` keys, snake_case).
The chart renders them into a ConfigMap mounted read-only on
`/config/settings.json`, so changes made in the web UI last until the pod
restarts: set them in `config` to keep them. Transmission also tries to rewrite
`settings.json` at start and stop; the read-only mount makes that rename fail
(`Couldn't save '/config/settings.json': Device or resource busy` in the log,
harmless) and leaves a `settings.json.tmp.*` file in `/config` each time:
delete them now and then. Keys the chart owns (the RPC
settings, the login, `peer_port`, `watch_dir`) are rejected there; `peer_port`
is `peer.port`, `watch_dir` comes from `persistence.watch.enabled`.
Command-line options go in `extraArgs`; the ones the chart sets (`--auth`,
`--username`, `--password`, `--port`, `--peerport`, `--config-dir`,
`--watch-dir`, ...) are rejected.

`rpc_host_whitelist_enabled` is on by default in Transmission, but only applies
without a login (`auth.enabled: false`): a request whose `Host` header is a DNS
name is then answered `421 Misdirected Request` unless the name is in
`rpc_host_whitelist`. Add the Ingress / HTTPRoute host name and the Service name
(`<service>.<namespace>.svc`, used by `helm test`) to it.

## Web UI

Open `/transmission/web/`:

```sh
kubectl -n transmission port-forward service/transmission 9091:9091
```

then <http://127.0.0.1:9091/transmission/web/>. `ingress` (Ingress) and
`httpRoute` (Gateway API HTTPRoute) expose it publicly; both need explicit
hosts (and `parentRefs` for the route). Terminate TLS in front: the daemon
serves plain HTTP.

## Storage

`/config` and `/downloads` (and `/watch` when `persistence.watch.enabled`)
each take one of four types:

- `volumeClaimTemplate` (default): a PVC per pod from the StatefulSet,
  `1Gi` for `/config`, `10Gi` for `/downloads` (sizes are a starting point:
  set them). The StatefulSet keeps its PVCs when it is deleted or scaled down
  (`persistentVolumeClaimRetentionPolicy: Retain`), so `helm uninstall` leaves
  your data; delete the PVCs by hand to remove it.
- `existingClaim`: an existing PVC (and optional `subPath`). Use it to share
  the downloads with other applications (a media server) through a
  `ReadWriteMany` volume.
- `hostPath`: a directory on the node, owned by uid/gid 65532 (the chart sets
  `fsGroup`, but Kubernetes does not apply it to `hostPath`). Pin the pod with
  `nodeSelector`. `type: DirectoryOrCreate` makes a root-owned directory the
  daemon cannot write.
- `emptyDir`: scratch space, lost with the pod.

A `volumeClaimTemplate` cannot be edited on an existing StatefulSet, so changing
`size` in values makes the upgrade fail. To grow a volume, expand the PVCs
(`kubectl patch pvc ...`, the StorageClass must allow expansion), then
recreate the StatefulSet without touching pods or PVCs:

```sh
kubectl -n transmission delete statefulset transmission --cascade=orphan
helm upgrade transmission ... -n transmission
```

On NFS or SMB, inotify does not see changes made by other clients: add
`watch_dir_force_generic: true` to `config` so the watch directory is polled.
NFS also needs `hostUsers: true` (idmapped mounts are not available there).

## Peers

Transmission uses one port number, `peer.port` (51413), on **TCP and UDP**
(UDP carries µTP peers, DHT and UDP tracker replies). Outgoing connections need
nothing. To be **connectable**, i.e. accept incoming peers, the same port must
reach the pod from the internet. Without it the daemon still downloads and
seeds to peers it dials itself, only slower. The chart does not use `hostNetwork`,
and turns UPnP / NAT-PMP (`port_forwarding_enabled`) and LPD off: they would
map the pod IP, not a reachable address.

Transmission announces `peer.port` to trackers, so every hop must use the same
number end to end (hostPort, NodePort, Gateway listener, router forward). Pick one:

- `peer.hostPort: true`: publishes the port on the node IP, TCP and UDP.
  Forward the port on your router to that node, and pin the pod with
  `nodeSelector` (a pod that moves to another node loses the forward). The
  namespace must be labelled `pod-security.kubernetes.io/enforce: privileged`
  (Pod Security `baseline` rejects any `hostPort`), and the CNI must support
  `hostPort` (`portmap`: kindnet, Flannel and Calico do; Cilium needs
  `hostPort.enabled`).
- `peer.service` with `type: LoadBalancer` (or `NodePort`; the node port is
  `peer.port`, so it must be within 30000-32767).
- `peer.tcpRoute` and `peer.udpRoute`: Gateway API `TCPRoute` / `UDPRoute`
  (`v1`, standard channel) to the peer Service, on a Gateway with a TCP and a
  UDP listener on `peer.port`.

The chart refuses combinations that would publish the port twice (hostPort with
a NodePort Service, a route with a LoadBalancer or NodePort Service).

## Image

The default images are `appVersion` (Transmission) and the exporter version,
each pinned by the digest recorded in the `artifacthub.io/images` annotation of
`Chart.yaml` (Renovate updates tag and digest together). Setting `image.tag`
(or `metrics.image.tag`) drops that digest; add `image.digest` to pin the tag
again (a digest without a tag is an error).

The images are signed with the `spnngl/images` key. Verify a digest with:

```sh
curl -fsSLO https://raw.githubusercontent.com/spnngl/images/main/cosign.pub
cosign verify --key cosign.pub --new-bundle-format=false --insecure-ignore-tlog=true \
  ghcr.io/spnngl/images/transmission@sha256:<digest>
```

## Security

Defaults satisfy the `restricted` Pod Security Standard (while `peer.hostPort`
is off): non-root uid/gid 65532, read-only root filesystem, all capabilities
dropped, no privilege escalation, `RuntimeDefault` seccomp, no ServiceAccount
token, no Service environment variables. The daemon writes only to
`/config`, `/downloads` and `/watch`.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support
(containerd 2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+
(idmapped mounts on tmpfs for Secret and ConfigMap volumes). On other nodes the
pod sandbox cannot be created: set `hostUsers: true`. Volumes without idmapped
mounts (NFS, SMB) and `hostPath` ownership need it too.

## Network

- The NetworkPolicy (`networkPolicy.enabled`, on by default) allows the RPC
  port, the peer port (TCP and UDP, from anywhere) and the metrics port. Restrict
  the RPC and metrics sources with `networkPolicy.rpc.from` and
  `networkPolicy.metrics.from` (your ingress controller, Prometheus); empty
  means any source. The `helm test` pod needs RPC access.
- `networkPolicy.egress.enabled` (off by default) allows DNS, `peers.to` (the
  internet except private, CGNAT and link-local ranges, so a compromised P2P
  process cannot move sideways) and `extraEgress`. A tracker or peer on your LAN
  needs an `except` entry removed, or an `extraEgress` rule.
- `metrics.enabled` adds the exporter sidecar. `metrics.serviceMonitor` or
  `metrics.podMonitor` (not both) integrate with the Prometheus Operator;
  a PodMonitor needs no Service.
- `metrics.prometheusRule` adds `TransmissionDown` (critical) and
  `TransmissionFreeSpaceLow` (warning, below `freeSpaceBytes`) and needs one of
  the monitors (the rules select the `job` label it sets). The exporter reports
  `-1` free space while `download_dir` does not exist yet (before the first
  completed torrent): the alert ignores it.
- `helm test` runs `transmission-remote --session-info` against the RPC Service
  (`<service>.<namespace>.svc`).

## Autoscaling and resources

There is no HPA (one replica). `verticalPodAutoscaler` supports `Off`,
`Initial`, `Recreate` and `InPlaceOrRecreate` (in-place resize needs
Kubernetes 1.33+). The default requests (`50m` CPU, `64Mi` memory) are
scheduling floors, not a sizing: memory grows with the number of active
torrents and peers, so measure then tune. With a memory limit on the exporter,
`GOMEMLIMIT` follows it.

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
* <https://github.com/transmission/transmission>
* <https://github.com/spnngl/images>
* <https://github.com/spnngl/transmission-exporter>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| auth.enabled | bool | `true` | Require a login for the RPC and web UI. `false` runs with `--no-auth`: then restrict access with the NetworkPolicy and set `config.rpc_host_whitelist` (host names reaching the daemon through an Ingress or HTTPRoute are refused by the host check otherwise). |
| auth.existingSecret.name | string | `""` | Name of the Secret holding the login. Empty: `<fullname>`. The chart never creates it. |
| auth.existingSecret.passwordKey | string | `"password"` | Key of the password in the Secret. |
| auth.existingSecret.usernameKey | string | `"username"` | Key of the user name in the Secret. |
| config | object | `{"download_dir":"/downloads/complete","incomplete_dir":"/downloads/incomplete","incomplete_dir_enabled":true,"lpd_enabled":false,"port_forwarding_enabled":false,"rpc_whitelist_enabled":false,"umask":"002"}` | Transmission settings (`settings.json`, snake_case keys), rendered into a ConfigMap and mounted read-only: web UI changes last until the pod restarts. Chart-owned keys (RPC, login, peer port, watch directory) are rejected. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for tracker host names). |
| extraArgs | list | `[]` | Extra `transmission-daemon` options, after the chart's own. They override `config` (arguments win). Options for chart-owned settings and options that exit are rejected. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the Transmission container. Chart-owned names are rejected. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Transmission container. |
| extraVolumes | list | `[]` | Extra volumes (for example a script directory for `script_torrent_done_filename`: the image has no shell). |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+) and idmapped mounts on every volume's file system (not NFS/SMB, not `hostPath` on some file systems); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute for the web UI (path prefix `/transmission`). |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/transmission"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress for the web UI (path `/transmission`). |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Liveness probe (TCP on the RPC port). |
| metrics.enabled | bool | `false` | Run the Prometheus exporter as a sidecar (`/metrics` on `metrics.port`). Per-torrent series grow with the torrent count. |
| metrics.image.digest | string | `""` | Exporter image digest, only valid together with `metrics.image.tag`. |
| metrics.image.pullPolicy | string | `"IfNotPresent"` | Exporter image pull policy. |
| metrics.image.repository | string | `"ghcr.io/spnngl/images/transmission-exporter"` | Exporter image repository. |
| metrics.image.tag | string | `""` | Exporter image tag. Empty: the tag and digest recorded for `metrics.image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor (no Service needed). Exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.port | int | `19091` | Exporter listen port. |
| metrics.prometheusRule.disabled | list | `[]` | Alerts to leave out (at most one: disable `prometheusRule` instead). |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alerts `TransmissionDown`, `TransmissionFreeSpaceLow`). Needs `serviceMonitor` or `podMonitor`: the rules select the `job` label it sets. |
| metrics.prometheusRule.freeSpaceBytes | string | `"10000000000"` | `TransmissionFreeSpaceLow` threshold in bytes (a string: Helm would render a large number in scientific notation). |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}` | Exporter resources. With a memory limit, `GOMEMLIMIT` follows it. |
| metrics.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Exporter container security context. Overrides are merged onto these defaults. |
| metrics.service.annotations | object | `{}` | Service annotations. |
| metrics.service.enabled | bool | `false` | Render the metrics Service (also rendered when `serviceMonitor.enabled`). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. Exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, internet peers and trackers, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s. |
| networkPolicy.egress.peers.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["fc00::/7","fe80::/10"]}}]` | Peers and trackers (any port). Default: the internet, not the private, CGNAT and link-local ranges, so a compromised P2P process cannot move sideways. Remove an `except` entry to reach a peer there. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: RPC port, peer port, and the metrics port when `metrics.enabled`). |
| networkPolicy.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to reach the metrics port. Empty: any source. |
| networkPolicy.rpc.from | list | `[]` | NetworkPolicyPeer list allowed to reach the RPC and web UI port. Empty: any source (the `helm test` pod needs it too). |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. With `peer.hostPort` or a `hostPath`, pin the pod to the node. |
| peer.hostPort | bool | `false` | Publish the peer port on the node (`hostPort`, TCP and UDP): inbound peers reach the pod through the node IP. Needs a `privileged` namespace (Pod Security `baseline` rejects it) and a CNI with `portmap`. |
| peer.port | int | `51413` | Peer port (`peer_port`), TCP and UDP (µTP, DHT and UDP trackers share it). Transmission announces it to trackers, so every hop in front of the pod (hostPort, NodePort, Gateway listener, router forward) must use this same number. |
| peer.service.annotations | object | `{}` | Peer Service annotations. |
| peer.service.enabled | bool | `false` | Render a peer Service (`<fullname>-peer`). Also rendered when a peer route is enabled. A ClusterIP one gives inbound peers nothing: use `LoadBalancer` or `NodePort` for that. |
| peer.service.externalTrafficPolicy | string | `""` | `externalTrafficPolicy` (`LoadBalancer` / `NodePort`). `Local` keeps the peer source address. Empty: Kubernetes default. |
| peer.service.loadBalancerClass | string | `""` | `loadBalancerClass` (`LoadBalancer`). Empty: cloud provider default. |
| peer.service.type | string | `"ClusterIP"` | Peer Service type. `NodePort` uses `peer.port` as the node port (30000-32767). |
| peer.tcpRoute.annotations | object | `{}` | TCPRoute annotations. |
| peer.tcpRoute.enabled | bool | `false` | Create a Gateway API TCPRoute (`gateway.networking.k8s.io/v1`) to the peer Service. Needs a Gateway with a TCP listener on `peer.port`. |
| peer.tcpRoute.labels | object | `{}` | Extra TCPRoute labels. |
| peer.tcpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`, set `sectionName` to the TCP listener). Required when enabled. |
| peer.udpRoute.annotations | object | `{}` | UDPRoute annotations. |
| peer.udpRoute.enabled | bool | `false` | Create a Gateway API UDPRoute (`gateway.networking.k8s.io/v1`) to the peer Service. Needs a Gateway with a UDP listener on `peer.port`. |
| peer.udpRoute.labels | object | `{}` | Extra UDPRoute labels. |
| peer.udpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`, set `sectionName` to the UDP listener). Required when enabled. |
| persistence.config.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`, state is lost with the pod). Empty: none. |
| persistence.config.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.config.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.config.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), owned by uid/gid 65532. Pin the pod to the node. |
| persistence.config.hostPath.type | string | `"Directory"` | `hostPath` type. `DirectoryOrCreate` makes a root-owned directory the daemon cannot write. |
| persistence.config.type | string | `"volumeClaimTemplate"` | Where `/config` (torrents, resume data, stats) lives. `volumeClaimTemplate` creates a PVC per pod and keeps it on uninstall; the other types use the matching sub-section. |
| persistence.config.volumeClaimTemplate.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.config.volumeClaimTemplate.annotations | object | `{}` | PVC annotations. |
| persistence.config.volumeClaimTemplate.labels | object | `{}` | PVC labels. |
| persistence.config.volumeClaimTemplate.size | string | `"1Gi"` | Requested size. The template is immutable once installed: resize the PVC, see the README. |
| persistence.config.volumeClaimTemplate.storageClassName | string | `""` | StorageClass (empty: cluster default). |
| persistence.downloads.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`). Empty: none. |
| persistence.downloads.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.downloads.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.downloads.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), owned by uid/gid 65532. Pin the pod to the node. |
| persistence.downloads.hostPath.type | string | `"Directory"` | `hostPath` type. |
| persistence.downloads.type | string | `"volumeClaimTemplate"` | Where `/downloads` lives. See `persistence.config.type`. |
| persistence.downloads.volumeClaimTemplate.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.downloads.volumeClaimTemplate.annotations | object | `{}` | PVC annotations. |
| persistence.downloads.volumeClaimTemplate.labels | object | `{}` | PVC labels. |
| persistence.downloads.volumeClaimTemplate.size | string | `"10Gi"` | Requested size. |
| persistence.downloads.volumeClaimTemplate.storageClassName | string | `""` | StorageClass (empty: cluster default). |
| persistence.watch.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`). Empty: none. |
| persistence.watch.enabled | bool | `false` | Mount `/watch` and turn on `watch_dir`: `.torrent` files dropped there are added and renamed `.added`. |
| persistence.watch.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.watch.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.watch.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), owned by uid/gid 65532. Pin the pod to the node. |
| persistence.watch.hostPath.type | string | `"Directory"` | `hostPath` type. |
| persistence.watch.type | string | `"volumeClaimTemplate"` | Where `/watch` lives. See `persistence.config.type`. |
| persistence.watch.volumeClaimTemplate.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.watch.volumeClaimTemplate.annotations | object | `{}` | PVC annotations. |
| persistence.watch.volumeClaimTemplate.labels | object | `{}` | PVC labels. |
| persistence.watch.volumeClaimTemplate.size | string | `"100Mi"` | Requested size. |
| persistence.watch.volumeClaimTemplate.storageClassName | string | `""` | StorageClass (empty: cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. `fsGroup` does not apply to NFS/SMB volumes or `hostPath`. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Readiness probe (TCP on the RPC port). |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"64Mi"}}` | Resources of the Transmission container. A scheduling floor, not a sizing: memory grows with the torrent count and the cache (measure, then tune; VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ControllerRevisions to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context of the Transmission container. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `9091` | RPC and web UI Service port (the container listens on 9091). |
| service.type | string | `"ClusterIP"` | RPC and web UI Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":60,"periodSeconds":5}` | Startup probe (TCP on the RPC port; an HTTP probe would get 401 with a login, and failed logins trip the anti brute force lock). Generous: many torrents take a while to load. |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

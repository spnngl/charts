# tuwunel

Tuwunel Matrix homeserver as a hardened single-replica StatefulSet, with an optional Cinny web client and LiveKit for calls

Runs [tuwunel](https://tuwunel.chat) ([source](https://github.com/matrix-construct/tuwunel)),
a Matrix homeserver, as a single-replica StatefulSet. The image is built from
[spnngl/images](https://github.com/spnngl/images): distroless, non-root, no shell.

One replica only: tuwunel is the single writer of its embedded database. Every
upgrade or reschedule is a short downtime. The pod gets 30 minutes to stop, and
as long to start: the first start after an upgrade can run a one-way database
migration, and a kill during it corrupts the database.

## Install

Set `serverName` yourself. It is the domain of your user IDs (`@alice:example.com`)
and **permanent**: changing it later orphans the database. The default,
`example.com`, is a placeholder that only lets the chart render without values: a
release left on it serves `@user:example.com`, and an empty value is rejected.

```sh
helm install tuwunel oci://ghcr.io/spnngl/charts/tuwunel --version <version> -n matrix --create-namespace \
  --set serverName=example.com
```

### First administrator

The first user to register becomes the administrator, and registration is closed
by default. Create a Secret holding a registration token, mount it, and open
registration with that token:

```sh
kubectl -n matrix create secret generic tuwunel-secrets --from-literal=registration_token=<token>
```

```yaml
serverName: example.com
existingSecret:
  name: tuwunel-secrets
config:
  allow_registration: true
  registration_token_file: /etc/tuwunel/secrets/registration_token
```

Register the administrator with a Matrix client, using the token. Then close
registration again (`allow_registration: false`), or keep the token so only
people who hold it can register.

### Settings

Everything else goes in `config`: the `[global]` table of `tuwunel.toml`
(see [`tuwunel-example.toml`](https://github.com/matrix-construct/tuwunel/blob/main/tuwunel-example.toml)).
The chart renders it into a ConfigMap and points `TUWUNEL_CONFIG` at it. A map
becomes a `[global.<key>]` table (`well_known`, `ldap`, `tls`).
`TUWUNEL_<KEY>` environment variables (`extraEnv`) win over the file.

Keys the chart owns (`server_name`, `database_path`, `address`, `port`,
`unix_socket_path`) are rejected, as are `extraEnv` names for them and
`extraArgs` that select another config file or mode (`--config`, `--option`,
`--health-check`, ...).

Keep secrets out of `config`: it lands in a ConfigMap, Helm release history and
Git. The `*_file` options read a file instead, and `existingSecret.name` mounts a
Secret of yours at `/etc/tuwunel/secrets`, one file per key:
`registration_token_file`, `registration_shared_secret_file`,
`turn_secret_file`, `ldap.bind_password_file` and
`identity_provider[].client_secret_file`. The chart never creates the Secret.

On nodes with many cores the database thread pool can exceed the pod's PID
limit and tuwunel fails to start with `EAGAIN`. Set `config.db_pool_max_workers`
(for example `512`) or raise the node's `podPidsLimit`
([upstream notes](https://github.com/matrix-construct/tuwunel/blob/main/docs/deploying/container-security.md)).

## Exposing it

`ingress` (Ingress) and `httpRoute` (Gateway API HTTPRoute) expose the
homeserver on `/`; both need explicit hosts (and `parentRefs` for the route).
Terminate TLS in front: tuwunel serves plain HTTP on 8008.

### Delegation

Often `serverName` (`example.com`) differs from the host serving the homeserver
(`matrix.example.com`). Matrix clients and servers then look for
`https://example.com/.well-known/matrix/{client,server}`. `ingress.wellKnown` or
`httpRoute.wellKnown` adds that rule on host `serverName` (path prefix
`/.well-known/matrix` only, the rest of the host stays yours) and defaults
`well_known.client` to `https://<first host>` and `well_known.server` to
`<first host>:443`. Your own `config.well_known` values win.

```yaml
serverName: example.com
ingress:
  enabled: true
  wellKnown: true
  hosts: [matrix.example.com]
  tls:
    - secretName: matrix-tls
      hosts: [matrix.example.com, example.com]
```

With `httpRoute.wellKnown`, the chart creates a second HTTPRoute
(`<fullname>-well-known`) on host name `serverName`, because a route holds one set of
host names; the Gateway needs a listener that accepts `serverName`. If
`serverName` already is one of the hosts, no extra rule is added.

## Cinny

`cinny.enabled: true` adds [Cinny](https://github.com/cinnyapp/cinny), a Matrix
web client: a stateless static server, in a Deployment of its own (two replicas,
spread over nodes and zones, rolling updates that never drop below the replica
count). It is separate from the homeserver so a Cinny update never restarts the
database.

Cinny runs in the browser and talks to the homeserver from there: the homeserver
must be reachable at `https://<serverName>` or through delegation (see
[Delegation](#delegation)), and Cinny needs a host of its own.

```yaml
serverName: example.com
ingress:
  enabled: true
  wellKnown: true
  hosts: [matrix.example.com]
cinny:
  enabled: true
  ingress:
    enabled: true
    hosts: [chat.example.com]
```

`cinny.config` is Cinny's `config.json`, merged over the chart defaults
(`homeserverList: [<serverName>]`, `defaultHomeserver: 0`,
`allowCustomHomeservers: false`). The browser downloads it: no secrets in it.
`cinny.ingress`, `cinny.httpRoute`, `cinny.podDisruptionBudget` and
`cinny.verticalPodAutoscaler` work like their homeserver counterparts; Cinny's
Ingress and HTTPRoute serve `/`, so give them a host of their own.

The image sends no security headers on purpose: Cinny frames Element Call from
its own origin. Add them at your ingress or gateway if you want them.

## Calls

`livekit.enabled: true` adds the MatrixRTC stack behind Element Call and Element
X calls: [LiveKit](https://github.com/livekit/livekit), the media server (SFU),
and [lk-jwt-service](https://github.com/element-hq/lk-jwt-service), which checks a
Matrix user and hands out a LiveKit token. Each runs in a Deployment of its own,
apart from the homeserver. LiveKit runs one replica (without Redis two pods split
the sessions) and a rollout waits up to 10 minutes
(`livekit.terminationGracePeriodSeconds`) for calls to end. Out of scope: Redis and
multi-node LiveKit, lk-jwt-service appservice mode (it logs a warning:
without it, room membership is not verified, which suits a single full-access
homeserver).

One host serves both, `livekit.host`: `/sfu/get`, `/get_token`,
`/delegate_delayed_leave` and `/healthz` go to lk-jwt-service, everything else
(`/`, a WebSocket) to LiveKit. The chart derives the rest: the homeserver
advertises `https://<host>` (`well_known.livekit_url`, answered from
`/_matrix/client/unstable/org.matrix.msc4143/rtc/transports`; with
`config.well_known.client` set, which `ingress.wellKnown` does, also from
`.well-known/matrix/client`), lk-jwt-service connects to `wss://<host>` and accepts
users of `serverName`.

Create the Secret first: one file, `<api key>: <api secret>` (a secret of 32
characters or more), shared by both pods (mode `0440`). Write it unquoted, with no
other `:`: lk-jwt-service splits the line on `:` and keeps quotes in the secret,
while LiveKit parses it as YAML, so a quoted secret makes LiveKit reject every token
request (401, `signature is invalid`). The chart never creates it,
and a running pod does not re-read it: after a rotation, change
`livekit.existingSecret.revision` (any string, a hash of the Secret from CI for
instance) to restart both pods.

```sh
kubectl -n matrix create secret generic livekit-keys \
  --from-literal=keys.yaml="lk-$(openssl rand -hex 4): $(openssl rand -hex 24)"
```

```yaml
livekit:
  enabled: true
  host: calls.example.com
  existingSecret:
    name: livekit-keys
  ingress:
    enabled: true
```

`livekit.config` is LiveKit's `config.yaml` (`config-sample.yaml` upstream). The
chart owns `port`, `rtc.tcp_port`, `rtc.udp_port`, `key_file` and
`prometheus.port`.

lk-jwt-service validates each token against `https://<serverName>` from inside the
cluster: when `serverName` differs from the homeserver host, that name must resolve
from the pod and reach the Ingress (delegation, see [Delegation](#delegation)).

### Media

Media uses `livekit.rtc.tcpPort` (ICE over TCP, default 7881) and `livekit.rtc.udpPort`
(every call, multiplexed, default 7882; it may equal `tcpPort`). Each port is the same
inside the pod, on the node and on the media Service: LiveKit advertises the port it
listens on. `livekit.rtc.mode` says how media reaches the pod:

| Mode                 | Media reaches the pod via                      | Advertised address (unless `rtc.node_ip` or `rtc.use_external_ip` is set)  |
| -------------------- | ---------------------------------------------- | -------------------------------------------------------------------------- |
| `hostPort` (default) | `hostPort` `tcpPort`/tcp and `udpPort`/udp     | the node's IP (`NODE_IP`)                                                  |
| `hostNetwork`        | the node's interfaces                          | what LiveKit finds on them                                                 |
| `LoadBalancer`       | a Service of its own, `<fullname>-livekit-rtc` | **must be set**: `config.rtc.node_ip` or `config.rtc.use_external_ip`      |

- Both host modes need a namespace that allows privileged pods (Pod Security
  `baseline` and `restricted` refuse `hostPort`), a node with a public IP (pin it
  with `livekit.nodeSelector`; `helm install` warns while it is empty) and both media ports open to the internet on it.
  `hostPort` needs the CNI `portmap` plugin, UDP included, and keeps the pod network
  (NetworkPolicy and `hostUsers: false` apply). `hostNetwork` has neither:
  LiveKit's API (7880) and metrics (6789) listen on the node's IP, and NetworkPolicy
  does not apply. LiveKit binds every address of the node: on a node with many
  interfaces (or duplicate addresses, as on kind) it can fail with `address already
  in use`: restrict it with `config.rtc.interfaces.includes`.
- `hostPort` advertises the node's InternalIP: on a cloud node behind NAT, set
  `config.rtc.use_external_ip: true` (STUN) or `config.rtc.node_ip`.
- `LoadBalancer` keeps the `restricted` standard, but one Service with TCP and UDP
  needs mixed-protocol support from the provider; otherwise use a host mode.
  `livekit.rtc.service` sets its annotations, `externalTrafficPolicy` and
  `loadBalancerClass`.
- Without TURN, clients behind strict firewalls reach LiveKit only over `tcpPort`
  (see [TURN](#turn)).
- ingress-nginx closes idle WebSockets after 60 s: raise `proxy-read-timeout` and
  `proxy-send-timeout` on the LiveKit Ingress.

### TURN

`livekit.turn.enabled` runs LiveKit's built-in TURN server for clients that cannot
reach `rtc.udpPort`. It adds 3478/udp (TURN over UDP), published like the media ports
(`rtc.mode`), and LiveKit hands its address to clients. For clients that only get
TLS through, also set `livekit.turn.domain` and `livekit.turn.existingSecret.name`,
a `kubernetes.io/tls` Secret for that name: TURN over TLS. `domain` must resolve to
the address clients reach and the certificate must cover it.

LiveKit listens on 5349/tcp but always hands clients `turns:<domain>:443`
(`pkg/service/roommanager.go` upstream), so 443 must reach 5349:

| Mode           | 443 reaches 5349 via                                                            |
| -------------- | ------------------------------------------------------------------------------- |
| `hostPort`     | `hostPort` 443: no other process may hold 443 on that node (ingress controller) |
| `LoadBalancer` | port 443 of the media Service                                                   |
| `hostNetwork`  | nothing: forward 443 to 5349 in front of the node (NAT, firewall)               |

An ingress controller already on 443 can pass `domain` through by SNI (SSL
passthrough, no TLS termination) to the `turn-tls` port (5349) of the LiveKit Service.
LiveKit loads the certificate at start only: restart it on renewal
(`livekit.existingSecret.revision`). Open 3478/udp and 443/tcp like the media ports.

```yaml
livekit:
  turn:
    enabled: true
    domain: turn.example.com
    existingSecret:
      name: turn-tls
```

TLS terminated by a proxy in front of TURN (`turn.external_tls`) and a custom relay
range (`config.turn.relay_range_start` / `relay_range_end`, 30000-40000 by default)
are left to `livekit.config`. The chart owns `turn.enabled`, `turn.domain`,
`turn.udp_port`, `turn.tls_port`, `turn.cert_file` and `turn.key_file`.

### Metrics

`livekit.metrics.enabled` serves Prometheus metrics on 6789 and names the port
`metrics`. `livekit.metrics.service`, `livekit.metrics.serviceMonitor` and
`livekit.metrics.podMonitor` (the last two are exclusive) render a Service and
Prometheus Operator objects. No alert rules yet.

## Storage

`/var/lib/tuwunel` (database and uploaded media) takes one of four types in
`persistence.data.type`:

- `volumeClaimTemplate` (default): a PVC from the StatefulSet, `10Gi`. The
  database **and every uploaded file** live there: size it for media. The
  StatefulSet keeps its PVC when it is deleted or scaled down
  (`persistentVolumeClaimRetentionPolicy: Retain`), so `helm uninstall` leaves
  your data; delete the PVC by hand to remove it.
- `existingClaim`: an existing PVC (and optional `subPath`).
- `hostPath`: a directory on the node, owned by uid/gid 65532 (the chart sets
  `fsGroup`, but Kubernetes does not apply it to `hostPath`). Pin the pod with
  `nodeSelector`. `type: DirectoryOrCreate` makes a root-owned directory tuwunel
  cannot write.
- `emptyDir`: scratch space, lost with the pod.

A `volumeClaimTemplate` cannot be edited on an existing StatefulSet, so changing
`size` in values makes the upgrade fail. To grow a volume, expand the PVC
(`kubectl patch pvc ...`, the StorageClass must allow expansion), then recreate
the StatefulSet without touching the pod or the PVC:

```sh
kubectl -n matrix delete statefulset tuwunel --cascade=orphan
helm upgrade tuwunel ... -n matrix
```

### Backups

tuwunel offers managed online backups and checkpoints of its RocksDB database
(`database_backup_path`, `database_backups_to_keep`), see
[`docs/backups.md`](https://github.com/matrix-construct/tuwunel/blob/main/docs/backups.md).
They **do not include media**, which lives in the same volume: back that up
separately. A repository on the same volume does not survive its loss: point
`database_backup_path` at another volume (`extraVolumes` and `extraVolumeMounts`).

## Image

The default image of each component is pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates tag and
digest together); the homeserver follows `appVersion`. Setting `image.tag` (or
`cinny.image.tag`, `livekit.image.tag`, `livekit.jwt.image.tag`) drops that digest; add `image.digest` to pin the tag again (a
digest without a tag is an error).

The images are signed keyless with cosign (GitHub Actions OIDC). Verify a digest with:

```sh
cosign verify ghcr.io/spnngl/images/tuwunel@sha256:<digest> \
  --certificate-identity-regexp '^https://github.com/spnngl/images/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The amd64 image needs a CPU with x86-64-v2.

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid
65532, read-only root filesystem, all capabilities dropped, no privilege
escalation, `RuntimeDefault` seccomp, no ServiceAccount token, no Service
environment variables. tuwunel writes only to `/var/lib/tuwunel`.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support
(containerd 2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+
(idmapped mounts on tmpfs for Secret and ConfigMap volumes). On other nodes the
pod sandbox cannot be created: set `hostUsers: true`. Volumes without idmapped
mounts (NFS, SMB) and `hostPath` ownership need it too.

## Network

- The NetworkPolicies (`networkPolicy.enabled`, on by default), one per
  component, allow only the component's port. Restrict the sources with
  `networkPolicy.homeserver.from`, `networkPolicy.cinny.from`,
  `networkPolicy.livekit.from` (7880), `networkPolicy.livekit.jwt.from` and
  `networkPolicy.livekit.metrics.from`; empty means any source: clients, other
  homeservers (federation) and your ingress controller can be anywhere. LiveKit's
  media and TURN ports are open to any source. `hostNetwork` pods get no policy.
- `networkPolicy.egress.enabled` (off by default) allows DNS, `peers.to` (the
  internet except private, CGNAT and link-local ranges: federation, push
  gateways, URL previews) and `extraEgress` for the homeserver. lk-jwt-service and
  LiveKit follow the same rules (lk-jwt-service reaches the homeserver and LiveKit
  through their public addresses: add an `extraEgress` rule if those sit on a
  private range). Cinny gets no egress at all: it only serves files. A server on your LAN needs an
  `except` entry removed, or an `extraEgress` rule.

## Autoscaling and resources

The homeserver has no HPA and no PodDisruptionBudget (one replica:
`maxUnavailable: 1` does nothing, `minAvailable: 1` blocks node drains). Cinny has
an opt-in PodDisruptionBudget (`cinny.podDisruptionBudget`) and no HPA. `verticalPodAutoscaler` supports
`Off`, `Initial`, `Recreate` and `InPlaceOrRecreate` (in-place resize needs
Kubernetes 1.33+). A recommender started with another `--recommender-name`
than `default` ignores the VPA unless `verticalPodAutoscaler.recommender`
names it. The default requests (`100m` CPU, `256Mi` memory) are scheduling
floors, not a sizing: memory grows with the number of rooms and the cache, so
measure then tune. Cinny's (`10m`, `16Mi`, limit `64Mi`), LiveKit's
(`100m`, `128Mi`, limit `512Mi`; `GOMEMLIMIT` is 90% of the limit) and
lk-jwt-service's (`10m`, `16Mi`, limit `64Mi`) are floors too.

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
* <https://github.com/matrix-construct/tuwunel>
* <https://github.com/cinnyapp/cinny>
* <https://github.com/livekit/livekit>
* <https://github.com/element-hq/lk-jwt-service>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| cinny.affinity | object | `{}` | Affinity, merged over the chart default: a preferred pod anti-affinity that spreads the replicas over nodes (set `podAntiAffinity` to replace it). |
| cinny.config | object | `{}` | Cinny `config.json` (homeservers, featured communities, hash router, see `config.json` upstream), merged over the chart defaults: `homeserverList: [<serverName>]`, `defaultHomeserver: 0`, `allowCustomHomeservers: false`. Cinny resolves each entry of `homeserverList` through its `/.well-known/matrix/client`: use `ingress.wellKnown` or `httpRoute.wellKnown` when `serverName` is not the homeserver host. The browser reads the file, so keep secrets out. |
| cinny.enabled | bool | `false` | Deploy Cinny. |
| cinny.httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| cinny.httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute for Cinny (path prefix `/`). |
| cinny.httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| cinny.httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| cinny.httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| cinny.image.digest | string | `""` | Image digest, only valid together with `cinny.image.tag`. |
| cinny.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| cinny.image.repository | string | `"ghcr.io/spnngl/images/cinny"` | Image repository. |
| cinny.image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `cinny.image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `cinny.image.digest` to pin it. |
| cinny.ingress.annotations | object | `{}` | Ingress annotations. |
| cinny.ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| cinny.ingress.enabled | bool | `false` | Create an Ingress for Cinny (path `/`). |
| cinny.ingress.hosts | list | `[]` | Host names. Required when enabled. Not the homeserver host unless you route paths yourself: both Ingresses serve `/`. |
| cinny.ingress.labels | object | `{}` | Extra Ingress labels. |
| cinny.ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| cinny.livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Liveness probe (`GET /health`). |
| cinny.minReadySeconds | int | `10` | Seconds a new pod must be ready before it counts as available (rolling updates never drop below `replicaCount`). |
| cinny.podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget (`unhealthyPodEvictionPolicy: AlwaysAllow`). |
| cinny.podDisruptionBudget.maxUnavailable | int | `1` | Pods that may be unavailable at once (a number or a percentage). |
| cinny.priorityClassName | string | `""` | Priority class name. |
| cinny.readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Readiness probe (`GET /health`). |
| cinny.replicaCount | int | `2` | Replicas. Cinny is stateless: two give a rolling update with no gap. |
| cinny.resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}` | Resources of the cinny container. A scheduling floor, not a sizing (VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| cinny.service.annotations | object | `{}` | Service annotations. |
| cinny.service.port | int | `8080` | Service port (the container listens on 8080). |
| cinny.service.type | string | `"ClusterIP"` | Service type. |
| cinny.startupProbe | object | `{"failureThreshold":30,"periodSeconds":2,"timeoutSeconds":2}` | Startup probe (`GET /health`). |
| cinny.terminationGracePeriodSeconds | int | `30` | Seconds Cinny gets to stop (the server drains on SIGTERM). |
| cinny.tolerations | list | `[]` | Tolerations. |
| cinny.topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty: the chart spreads the replicas over zones (`topology.kubernetes.io/zone`, `ScheduleAnyway`). A list you set replaces it and needs its own `labelSelector`. |
| cinny.verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| cinny.verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| cinny.verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler for Cinny (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| cinny.verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| cinny.verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations. |
| cinny.verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. |
| cinny.verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |
| config | object | `{}` | tuwunel settings (the `[global]` table of `tuwunel.toml`, see `tuwunel-example.toml` upstream), rendered into a ConfigMap. Nested maps become `[global.<key>]` tables. Chart-owned keys (`server_name`, `database_path`, `address`, `port`, `unix_socket_path`) are rejected. With `ingress.wellKnown` or `httpRoute.wellKnown` the chart defaults `well_known.client` and `well_known.server`; your values win. Secrets go through `existingSecret` and the `*_file` options, never here. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for federation host names). |
| existingSecret.name | string | `""` | Name of a Secret to mount at `/etc/tuwunel/secrets` (mode 0440), for the `*_file` options: `registration_token_file`, `registration_shared_secret_file`, `turn_secret_file`, `ldap.bind_password_file`, `identity_provider[].client_secret_file`. Each key becomes a file. Empty: nothing mounted. The chart never creates it. |
| extraArgs | list | `[]` | Extra `tuwunel` options, after the chart's own (none). Options for the config file and options that exit or start another mode are rejected. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the tuwunel container. `TUWUNEL_<KEY>` variables win over the config file. Variables for chart-owned settings and the config file path are rejected. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the tuwunel container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pods in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+) and idmapped mounts on every volume's file system (not NFS/SMB, not `hostPath` on some file systems); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute for the homeserver (path prefix `/`). |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). The first one is the homeserver host. |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| httpRoute.wellKnown | bool | `false` | Delegate `serverName` to the homeserver host: create a second HTTPRoute (`<fullname>-well-known`) on host name `serverName`, path prefix `/.well-known/matrix`, and default `well_known.client` to `https://<first host name>` and `well_known.server` to `<first host name>:443`. Needs `hostnames`, and a Gateway listener accepting `serverName`. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/tuwunel"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress for the homeserver (path `/`). |
| ingress.hosts | list | `[]` | Host names. Required when enabled. The first one is the homeserver host. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| ingress.wellKnown | bool | `false` | Delegate `serverName` to the homeserver host: add a rule on host `serverName`, path `/.well-known/matrix`, and default `well_known.client` to `https://<first host>` and `well_known.server` to `<first host>:443`. For a `serverName` that differs from the homeserver host (`example.com` served by `matrix.example.com`). Needs `hosts`. Add `serverName` to `tls`. |
| livekit.affinity | object | `{}` | Affinity of the LiveKit pod. |
| livekit.config | object | `{}` | LiveKit settings (`config.yaml`, see `config-sample.yaml` upstream), rendered into a ConfigMap. Chart-owned keys (`port`, `rtc.tcp_port`, `rtc.udp_port`, `key_file`, `prometheus.port` and `turn.enabled`, `turn.domain`, `turn.udp_port`, `turn.tls_port`, `turn.cert_file`, `turn.key_file`) are rejected. Keys go through `existingSecret`, never here. Redis and multi-node are out of scope. |
| livekit.enabled | bool | `false` | Deploy LiveKit and lk-jwt-service (calls for Element Call and Element X). Needs `host` and `existingSecret.name`. |
| livekit.existingSecret.key | string | `"keys.yaml"` | Key of the Secret: a file holding one line, `<api key>: <api secret>` (a secret of 32 characters or more), unquoted and with no other `:`: lk-jwt-service splits the line on `:` and keeps quotes, LiveKit parses it as YAML (a quoted secret fails every call with a 401 from LiveKit). |
| livekit.existingSecret.name | string | `""` | Name of a Secret holding the LiveKit API key and secret, shared by LiveKit and lk-jwt-service. Required when enabled. The chart never creates it. |
| livekit.existingSecret.revision | string | `""` | Opaque string added to both pods as the `checksum/secret` annotation: change it when you rotate the Secret to restart them (a mounted Secret is not re-read by a running process). The chart cannot hash a Secret it does not own, so it is yours to set, for example from CI: `--set-string livekit.existingSecret.revision=$(kubectl get secret livekit-keys -o json | sha256sum | cut -c1-12)`. Empty: no annotation. |
| livekit.host | string | `""` | Public host of LiveKit and lk-jwt-service (one host for both, `calls.example.com`). Required when enabled. Clients get `https://<host>` from the homeserver (`well_known.livekit_url`), lk-jwt-service gets `wss://<host>`. |
| livekit.httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| livekit.httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute on `livekit.host`: the lk-jwt-service paths go to lk-jwt-service, `/` to LiveKit (WebSocket). |
| livekit.httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| livekit.httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| livekit.image.digest | string | `""` | Image digest, only valid together with `livekit.image.tag`. |
| livekit.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| livekit.image.repository | string | `"ghcr.io/spnngl/images/livekit"` | Image repository. |
| livekit.image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `livekit.image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `livekit.image.digest` to pin it. |
| livekit.ingress.annotations | object | `{}` | Ingress annotations. |
| livekit.ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| livekit.ingress.enabled | bool | `false` | Create an Ingress on `livekit.host`: the lk-jwt-service paths go to lk-jwt-service, `/` to LiveKit (WebSocket). |
| livekit.ingress.labels | object | `{}` | Extra Ingress labels. |
| livekit.ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livekit.jwt.affinity | object | `{}` | Affinity of the lk-jwt-service pod. |
| livekit.jwt.image.digest | string | `""` | Image digest, only valid together with `livekit.jwt.image.tag`. |
| livekit.jwt.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| livekit.jwt.image.repository | string | `"ghcr.io/spnngl/images/lk-jwt-service"` | Image repository. |
| livekit.jwt.image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `livekit.jwt.image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `livekit.jwt.image.digest` to pin it. |
| livekit.jwt.livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Liveness probe (`GET /healthz`). |
| livekit.jwt.priorityClassName | string | `""` | Priority class name of the lk-jwt-service pod. |
| livekit.jwt.readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Readiness probe (`GET /healthz`). |
| livekit.jwt.resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}` | Resources of the lk-jwt-service container. A scheduling floor, not a sizing. |
| livekit.jwt.service.annotations | object | `{}` | Annotations of the lk-jwt-service Service (8080). |
| livekit.jwt.startupProbe | object | `{"failureThreshold":30,"periodSeconds":2,"timeoutSeconds":2}` | Startup probe (`GET /healthz`). |
| livekit.jwt.terminationGracePeriodSeconds | int | `10` | Seconds lk-jwt-service gets to stop. It has no SIGTERM handler: a 5 s `preStop` sleep lets the endpoints drop the pod first, then the image's stop signal (SIGKILL) ends it. |
| livekit.jwt.tolerations | list | `[]` | Tolerations of the lk-jwt-service pod. |
| livekit.livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Liveness probe (TCP on 7880). |
| livekit.metrics.enabled | bool | `false` | Serve Prometheus metrics (`prometheus.port`, 6789) and name the container port `metrics`. On the node's address with `mode: hostNetwork`. |
| livekit.metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor (no Service needed). Exclusive with `serviceMonitor`. |
| livekit.metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| livekit.metrics.podMonitor.labels | object | `{}` | Extra labels. |
| livekit.metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| livekit.metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| livekit.metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| livekit.metrics.service.annotations | object | `{}` | Service annotations. |
| livekit.metrics.service.enabled | bool | `false` | Render the metrics Service (also rendered when `serviceMonitor.enabled`). |
| livekit.metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. Exclusive with `podMonitor`. |
| livekit.metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| livekit.metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| livekit.metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| livekit.metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| livekit.metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| livekit.nodeSelector | object | `{}` | Node selector of the LiveKit pod, merged over `nodeSelector`. The host modes need the node with the public IP. |
| livekit.priorityClassName | string | `""` | Priority class name of the LiveKit pod. |
| livekit.readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Readiness probe (`GET /` on 7880). |
| livekit.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}` | Resources of the livekit container. A scheduling floor, not a sizing. `GOMEMLIMIT` is 90% of `limits.memory` (an integer with a Ki/Mi/Gi/Ti or k/M/G/T suffix; any other form gets the full limit). |
| livekit.rtc.mode | string | `"hostPort"` | How media (`tcpPort`, `udpPort`) reaches the pod. `hostPort`: published on the node, which LiveKit advertises (`NODE_IP`, unless `config.rtc.node_ip` or `config.rtc.use_external_ip` is set). `hostNetwork`: the pod uses the node's network, LiveKit finds the addresses itself. `LoadBalancer`: a Service of its own, needs `config.rtc.node_ip` or `config.rtc.use_external_ip`. Both host modes need a namespace that allows privileged pods and a node with a public IP (`livekit.nodeSelector`). |
| livekit.rtc.service.annotations | object | `{}` | Annotations of the media Service (`mode: LoadBalancer`). |
| livekit.rtc.service.externalTrafficPolicy | string | `""` | `externalTrafficPolicy` of the media Service. Empty: Kubernetes default. |
| livekit.rtc.service.loadBalancerClass | string | `""` | `loadBalancerClass` of the media Service. Empty: cloud provider default. |
| livekit.rtc.tcpPort | int | `7881` | ICE over TCP (`rtc.tcp_port`): the fallback when UDP is blocked. Same port inside the pod, on the node (host modes) and on the media Service: LiveKit advertises the port it listens on. Not one of the chart's other TCP ports (5349, 6789, 7880). |
| livekit.rtc.udpPort | int | `7882` | Every call, multiplexed on one UDP port (`rtc.udp_port`), published like `tcpPort`. It may equal `tcpPort`. Not TURN's 3478. |
| livekit.service.annotations | object | `{}` | Annotations of the LiveKit Service (HTTP and WebSocket, 7880). |
| livekit.startupProbe | object | `{"failureThreshold":30,"periodSeconds":2,"timeoutSeconds":2}` | Startup probe (`GET /` on 7880, 406 until the node is ready). |
| livekit.terminationGracePeriodSeconds | int | `600` | Seconds LiveKit gets to stop: it drains on SIGTERM (no limit) and a second signal forces it. The longest call a rollout waits for. |
| livekit.tolerations | list | `[]` | Tolerations of the LiveKit pod. |
| livekit.turn.domain | string | `""` | DNS name of the TURN server, which must resolve to the address clients reach, and match the certificate. Required with `existingSecret.name`. |
| livekit.turn.enabled | bool | `false` | Run LiveKit's built-in TURN server: clients that cannot reach `rtc.udpPort` (strict firewalls, UDP blocked) relay media through it. Adds 3478/udp and, with `existingSecret`, TURN over TLS: LiveKit listens on 5349/tcp, clients always dial `domain` on 443 (`hostPort` 443 in `hostPort` mode, port 443 of the media Service in `LoadBalancer` mode). |
| livekit.turn.existingSecret.name | string | `""` | Name of a `kubernetes.io/tls` Secret (`tls.crt`, `tls.key`) for `domain`. Set: TURN over TLS (LiveKit on 5349/tcp, clients on 443). LiveKit reads it at start only: restart it on renewal (`livekit.existingSecret.revision`). Empty: TURN over UDP only (3478/udp). The chart never creates it. |
| livenessProbe.failureThreshold | int | `3` |  |
| livenessProbe.periodSeconds | int | `10` |  |
| livenessProbe.timeoutSeconds | int | `5` |  |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.cinny.from | list | `[]` | NetworkPolicyPeer list allowed to reach the Cinny port. Empty: any source (browsers reach it through your ingress controller or gateway). |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, internet peers for federation, push and URL previews, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s. |
| networkPolicy.egress.peers.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["fc00::/7","fe80::/10"]}}]` | Internet peers (any port). Default: the internet, not the private, CGNAT and link-local ranges, so a compromised pod cannot move sideways. Remove an `except` entry to reach a server there. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy per component (ingress: the homeserver port). |
| networkPolicy.homeserver.from | list | `[]` | NetworkPolicyPeer list allowed to reach the homeserver port. Empty: any source (clients, federation and the ingress controller can be anywhere). |
| networkPolicy.livekit.from | list | `[]` | NetworkPolicyPeer list allowed to reach LiveKit's HTTP and WebSocket port (7880). Empty: any source (clients through your ingress controller or gateway, lk-jwt-service). Media and TURN (`rtc.tcpPort`, `rtc.udpPort`, 3478/udp, 5349/tcp) are open to any source. Does not apply with `livekit.rtc.mode: hostNetwork`. |
| networkPolicy.livekit.jwt.from | list | `[]` | NetworkPolicyPeer list allowed to reach lk-jwt-service (8080). Empty: any source. |
| networkPolicy.livekit.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to scrape LiveKit's metrics port (6789). Empty: any source. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. With a `hostPath`, pin the pod to the node. |
| persistence.data.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`, everything is lost with the pod). Empty: none. |
| persistence.data.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.data.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.data.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), owned by uid/gid 65532. Pin the pod to the node. |
| persistence.data.hostPath.type | string | `"Directory"` | `hostPath` type. `DirectoryOrCreate` makes a root-owned directory the server cannot write. |
| persistence.data.type | string | `"volumeClaimTemplate"` | Where `/var/lib/tuwunel` (database and uploaded media) lives. `volumeClaimTemplate` creates a PVC and keeps it on uninstall; the other types use the matching sub-section. |
| persistence.data.volumeClaimTemplate.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.data.volumeClaimTemplate.annotations | object | `{}` | PVC annotations. |
| persistence.data.volumeClaimTemplate.labels | object | `{}` | PVC labels. |
| persistence.data.volumeClaimTemplate.size | string | `"10Gi"` | Requested size. The database and every uploaded file live here: size it for media. The template is immutable once installed: resize the PVC, see the README. |
| persistence.data.volumeClaimTemplate.storageClassName | string | `""` | StorageClass (empty: cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. `fsGroup` does not apply to NFS/SMB volumes or `hostPath`. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe.failureThreshold | int | `3` |  |
| readinessProbe.periodSeconds | int | `10` |  |
| readinessProbe.timeoutSeconds | int | `5` |  |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resources of the tuwunel container. A scheduling floor, not a sizing: memory grows with the number of rooms and the cache (measure, then tune; VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ControllerRevisions to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context of the tuwunel container. Overrides are merged onto these defaults. |
| serverName | string | `"example.com"` | Matrix server name: the domain of user IDs (`@user:example.com`). **Set it before the first install**: the default is a placeholder, only there so the chart renders without values. Permanent: tuwunel cannot change it after the first start without wiping the database. An empty value is rejected. It need not be the host that serves the homeserver, see `ingress.wellKnown`. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8008` | Service port (the container listens on 8008). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe.failureThreshold | int | `180` |  |
| startupProbe.periodSeconds | int | `10` |  |
| startupProbe.timeoutSeconds | int | `5` |  |
| terminationGracePeriodSeconds | int | `1800` | Seconds the homeserver gets to stop. Upstream asks for 1800: a start after an upgrade can run a one-way database migration, and a kill during it corrupts the database. |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler for the homeserver (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

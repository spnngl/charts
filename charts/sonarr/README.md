# sonarr

Sonarr TV series collection manager as a hardened single-replica StatefulSet, with SQLite or an external PostgreSQL

Runs [Sonarr](https://github.com/Sonarr/Sonarr) as a single-replica
StatefulSet. The image is built from
[spnngl/images](https://github.com/spnngl/images): distroless, non-root, no shell.

One replica only: Sonarr is the sole writer of `/config` and of its SQLite
databases. Every upgrade or reschedule is a short downtime.

## Install

```sh
kubectl create namespace sonarr
helm install sonarr oci://ghcr.io/spnngl/charts/sonarr --version <version> -n sonarr
```

The defaults start Sonarr with SQLite in a `1Gi` PVC and no authentication
method pinned: the first visit to the web UI opens Sonarr's setup dialog, which
asks for the method and creates the first user. Complete it before exposing the
Service, or pin a method as below.

## Authentication

The chart always sets `Auth__Required=Enabled`: the web UI never runs
unauthenticated for local addresses. `auth.method` picks how:

- empty (default): nothing is pinned, the first-run dialog decides.
- `Basic`: a browser login dialog. The credentials travel in every request:
  terminate TLS in front. Sonarr locks the UI while no user exists. Create the
  first user as for `Forms`, with `authenticationMethod` set to `basic`.
- `Forms`: a login page. Sonarr locks the UI while no user exists, and the
  dialog does not open when a method is pinned. Create the first user through
  the API with the API key (read it from `config.xml`, or set it with
  `apiKey.existingSecret`): `GET /api/v3/config/host`, set
  `authenticationMethod`, `username`, `password` and `passwordConfirmation` in
  the result, `PUT` it back with the `X-Api-Key` header.
- `External`: an authenticating proxy in front does the login, Sonarr trusts
  everything that reaches it. Sonarr then serves its API key to any client that
  reaches the pod (`GET /initialize.json`), so the chart requires
  `networkPolicy.enabled: true` and a non-empty `networkPolicy.http.from`
  (your proxy only). That protects only with a CNI that enforces NetworkPolicy.
  Put the proxy at the Ingress, for example oauth2-proxy with the ingress-nginx
  `auth-url` / `auth-signin` annotations in `ingress.annotations`.
  Do not use `DisabledForLocalAddresses` instead: every private and loopback
  address passes it, which is every pod in a cluster.

### API key

Sonarr generates its API key and keeps it in `/config/config.xml`. To set it
from a Secret (for Prowlarr, Bazarr and Configarr to share), create the Secret and
point `apiKey.existingSecret.name` at it:

```sh
kubectl -n sonarr create secret generic sonarr-api --from-literal=api-key="$(openssl rand -hex 16)"
```

Sonarr reads it once at startup: restart the pod after changing it. The chart
never creates the Secret.

```sh
kubectl -n sonarr rollout restart statefulset/sonarr
```

## External database

`externalDatabase.enabled: true` uses PostgreSQL instead of SQLite in `/config`.
Sonarr creates its tables, never the databases: create the main and the log
database first (`sonarr-main` and `sonarr-log` by default), owned by the login
in `externalDatabase.existingSecret` (keys `username` and `password`, the shape
of a CloudNativePG role Secret). A missing database makes the pod crash-loop.
The two names must differ.

- One database per application: never point Sonarr or another app at the same
  database.
- The chart does not migrate SQLite data: enabling it on an existing install
  starts empty.
- To keep logs out of PostgreSQL, add `Sonarr__Log__DbEnabled=false` to
  `extraEnv`; the log database is then never opened and need not exist.
- TLS and other connection options are not exposed, and Sonarr has no
  connection-string setting at this version: Npgsql's defaults apply
  (`SslMode=Prefer`, TLS if the server offers it, certificate not checked). Keep
  the database on a trusted network and restrict it with a NetworkPolicy.
- Sonarr prints the connection string, password included, in its log at
  startup (`*** Migrating ... ***`). Keep the logs private, and do not ship them
  to a place the database password must not reach.
- Back up PostgreSQL yourself. Sonarr's own backups are SQLite only.

The readiness probe reads the database: while PostgreSQL is down the pod leaves
the Service without restarting.

## Web UI

```sh
kubectl -n sonarr port-forward service/sonarr 8989:8989
```

then <http://127.0.0.1:8989>. `ingress` (Ingress) and `httpRoute` (Gateway API
HTTPRoute) expose it; both need explicit hosts (and `parentRefs` for the route).
Terminate TLS in front: Sonarr serves plain HTTP.

To serve under a path, set `Sonarr__Server__UrlBase` in `extraEnv`: the chart
prefixes the probe, Ingress and HTTPRoute paths with it. Behind a proxy that
rewrites the `Host` header, also set `Sonarr__Server__AllowedHosts`.

## Configuration

Settings Sonarr reads from the environment go in `extraEnv`, named
`Sonarr__<Section>__<Key>`, for example `Sonarr__App__InstanceName` or
`Sonarr__Log__Level`. Names the chart sets (`Sonarr__Auth__{ApiKey,Enabled,Method,Required}`, `Sonarr__Server__{BindAddress,Port}`,
and `Sonarr__Postgres__*` with `externalDatabase.enabled`) are rejected in any
case and in the `Sonarr:Auth:Method` form. Command-line options go in
`extraArgs`.

The pinned port and bind address keep the Service, probes and NetworkPolicy
valid: changing them in Settings › General has no effect.

Sonarr logs to standard output and to files in `/config/logs`, and keeps a copy
in its log database. Collect the standard output.

## Storage

Two volumes: `/config` (state) and `/data` (media and downloads, see Data volume).

`/config` takes one of four types in `persistence.config.type`:

- `volumeClaimTemplate` (default): a PVC per pod from the StatefulSet. The
  StatefulSet keeps its PVC when it is deleted or scaled down
  (`persistentVolumeClaimRetentionPolicy: Retain`), so `helm uninstall` leaves
  your data; delete the PVC by hand to remove it.
- `existingClaim`: an existing PVC (and optional `subPath`).
- `hostPath`: a directory on the node, owned by uid/gid 65532 (Kubernetes does
  not apply `fsGroup` to `hostPath`). Pin the pod with `nodeSelector`.
  `type: DirectoryOrCreate` makes a root-owned directory Sonarr cannot write.
- `emptyDir`: scratch space, lost with the pod.

Use block storage with SQLite: it corrupts on NFS and SMB (use
`externalDatabase` there). A `volumeClaimTemplate` cannot be edited on an
existing StatefulSet, so changing `size` in values makes the upgrade fail. To
grow the volume, expand the PVC (the StorageClass must allow it), then recreate
the StatefulSet without touching pods or PVCs:

```sh
kubectl -n sonarr delete statefulset sonarr --cascade=orphan
helm upgrade sonarr ... -n sonarr
```

## Data volume

`persistence.data` mounts the tree Sonarr imports into and reads downloads from, at
`/data` by default (`emptyDir`, scratch space, until you choose a type):

- `existingClaim`: a PVC, ReadWriteMany or ReadWriteOnce with every pod on one
  node, with an optional `subPath`.
- `hostPath`: a node directory, writable by uid/gid 65532 (Kubernetes does not
  apply `fsGroup`). Pin the pod with `nodeSelector`.
- `nfs`: `server` and `path`; needs `hostUsers: true` and an export writable by
  65532.

Mount the same volume at the same path in Sonarr and in the download client:
an import is then a hardlink or an atomic move, not a copy. Both directories
must be on one filesystem, for example `/data/usenet/complete` and
`/data/media/tv`. Point Sonarr's root folder at `/data/media/tv` and the
download client's category path at `/data/usenet/complete` (remote path mappings
are then unnecessary).

A library on S3 is a FUSE mount made on the node, under the `hostPath`, by
another pod: set `mountPropagation: HostToContainer` so Sonarr sees the mount
even when it starts first. `Bidirectional` is not offered. Sonarr's `/config` and
its databases never go on S3.

## Image

The default image is `appVersion`, pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates tag and
digest together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (a digest without a tag is an error).

The image is signed with cosign (keyless, GitHub Actions OIDC) and carries SLSA
provenance. See the repository README, "Verifying what you install".

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 65532,
read-only root filesystem (writes go to `/config` and an `emptyDir` on `/tmp`),
all capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp, no
ServiceAccount token, no Service environment variables.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in the
pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support (containerd
2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+. On other nodes the
pod sandbox cannot be created: set `hostUsers: true`. Volumes without idmapped
mounts (NFS, SMB) and `hostPath` ownership need it too.

## Network

- The NetworkPolicy (`networkPolicy.enabled`, on by default) allows the web
  port. `networkPolicy.http.from` restricts the sources; empty means any source.
  When you set it, include the Ingress controller and every application that calls
  Sonarr (Prowlarr, Bazarr, Seerr, Configarr).
- `networkPolicy.egress.enabled` (off by default) allows DNS, `peers.to` (the
  internet except private, CGNAT and link-local ranges: indexers and metadata
  APIs, so a compromised process cannot move sideways) and `extraEgress`. Add
  `extraEgress` rules for PostgreSQL, Prowlarr, SABnzbd, or an indexer or
  media server on your LAN.

## Autoscaling and resources

There is no HPA (one replica). `verticalPodAutoscaler` supports `Off`, `Initial`,
`Recreate` and `InPlaceOrRecreate` (in-place resize needs Kubernetes 1.33+). A
recommender started with another `--recommender-name` than `default` ignores the
VPA unless `verticalPodAutoscaler.recommender` names it. The default requests
are scheduling floors, not a sizing: memory grows with the size of the library
and of the searches, so measure then tune.

## Compatibility

The values schema is strict: unknown keys fail the install. A breaking change to
values bumps the chart MAJOR version; deprecations are announced one MINOR
version ahead. Requires Kubernetes 1.33 or later.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| spnngl |  | <https://github.com/spnngl> |

## Source Code

* <https://github.com/spnngl/charts>
* <https://github.com/Sonarr/Sonarr>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| apiKey.existingSecret.key | string | `"api-key"` | Key of the API key in the Secret. |
| apiKey.existingSecret.name | string | `""` | Name of a Secret holding the API key, passed as `Sonarr__Auth__ApiKey`. Empty: no env, Sonarr generates its own key and keeps it in `config.xml`. The chart never creates the Secret. |
| auth.method | string | `""` | Authentication method for the web UI. Empty: none is pinned and Sonarr's first-run dialog picks one and creates the user. `Basic`: browser login dialog (HTTP Basic, the credentials travel in every request: use TLS in front). `Forms`: login page; with no user yet the UI is locked (create the first one through the API, see the README). `External`: an authenticating proxy in front does the login, Sonarr trusts everything that reaches it and serves its API key to it, so it needs `networkPolicy.enabled` and a non-empty `networkPolicy.http.from`. The chart always pins `Auth__Required=Enabled`. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for indexer host names). |
| externalDatabase.database | string | `"sonarr-main"` | Main database name (`Sonarr__Postgres__MainDb`). |
| externalDatabase.enabled | bool | `false` | Use an external PostgreSQL instead of SQLite in `/config`. Sonarr creates its tables but no database: create both databases first. Enabling it on an existing install starts empty; the SQLite data is not migrated. |
| externalDatabase.existingSecret.name | string | `""` | Name of the Secret holding the database login (for example a CloudNativePG role Secret). Required when enabled. The chart never creates it. |
| externalDatabase.existingSecret.passwordKey | string | `"password"` | Key of the password in the Secret. |
| externalDatabase.existingSecret.usernameKey | string | `"username"` | Key of the user name in the Secret. |
| externalDatabase.host | string | `""` | PostgreSQL host. Required when enabled. |
| externalDatabase.logDatabase | string | `"sonarr-log"` | Log database name (`Sonarr__Postgres__LogDb`), different from `database`. Ignored when `Sonarr__Log__DbEnabled=false` is set in `extraEnv`. |
| externalDatabase.port | int | `5432` | PostgreSQL port. |
| extraArgs | list | `[]` | Extra Sonarr options, after the chart's own `-nobrowser -data=/config`. The data directory and the options that install a service, register a URL or exit are rejected. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the Sonarr container, for example `Sonarr__Server__AllowedHosts` or `Sonarr__App__InstanceName`. Names the chart sets are rejected (`Sonarr__Auth__{ApiKey,Enabled,Method,Required}`, `Sonarr__Server__{BindAddress,Port}`, and `Sonarr__Postgres__*` with `externalDatabase.enabled`), in any case and in the `Sonarr:Auth:Method` form. |
| extraInitContainers | list | `[]` | Extra init containers, rendered as given: seed a file before start, or run a native sidecar (`restartPolicy: Always`) that calls the API. The image has no shell: use another image. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Sonarr container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+) and idmapped mounts on every volume's file system (not NFS/SMB, not `hostPath` on some file systems); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute for the web UI (path prefix `/`, or the `Sonarr__Server__UrlBase` set in `extraEnv`). |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/sonarr"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress for the web UI (path `/`, or the `Sonarr__Server__UrlBase` set in `extraEnv`). |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Liveness probe (TCP on the web port: a database outage must not restart the pod). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, internet indexers, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s: the database, Prowlarr, SABnzbd, a media server. |
| networkPolicy.egress.peers.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["fc00::/7","fe80::/10"]}}]` | Indexers, metadata APIs and notification services (any port). Default: the internet, not the private, CGNAT and link-local ranges, so a compromised process cannot move sideways. Remove an `except` entry to reach an indexer there. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: the web port). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the web UI and API port. Empty: any source. It must admit the Ingress controller and every app that calls Sonarr (Prowlarr, Bazarr, Seerr, Configarr). |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. With a `hostPath`, pin the pod to the node. |
| persistence.config.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`, state is lost with the pod). Empty: none. |
| persistence.config.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.config.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.config.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), owned by uid/gid 65532. Pin the pod to the node. |
| persistence.config.hostPath.type | string | `"Directory"` | `hostPath` type. `DirectoryOrCreate` makes a root-owned directory the app cannot write. |
| persistence.config.type | string | `"volumeClaimTemplate"` | Where `/config` (`config.xml`, the SQLite databases unless `externalDatabase.enabled`, logs, backups) lives. Block storage: SQLite on NFS corrupts. `volumeClaimTemplate` creates a PVC per pod and keeps it on uninstall; the other types use the matching sub-section. |
| persistence.config.volumeClaimTemplate.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.config.volumeClaimTemplate.annotations | object | `{}` | PVC annotations. |
| persistence.config.volumeClaimTemplate.labels | object | `{}` | PVC labels. |
| persistence.config.volumeClaimTemplate.size | string | `"1Gi"` | Requested size. The template is immutable once installed: resize the PVC, see the README. |
| persistence.config.volumeClaimTemplate.storageClassName | string | `""` | StorageClass (empty: cluster default). |
| persistence.data.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`, state is lost with the pod). Empty: none. |
| persistence.data.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.data.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.data.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), writable by uid/gid 65532. Pin the pod to the node. |
| persistence.data.hostPath.type | string | `"Directory"` | `hostPath` type. `DirectoryOrCreate` makes a root-owned directory the app cannot write. |
| persistence.data.mountPath | string | `"/data"` | Mount path. Not `/`, `/config` or `/tmp` (with or without a trailing slash). |
| persistence.data.mountPropagation | string | `"None"` | Mount propagation. `HostToContainer` shows a FUSE mount made on the node under the volume after the pod started (the rclone chart). `Bidirectional` is not offered: it needs a privileged container. |
| persistence.data.nfs.path | string | `""` | Exported path on the server. |
| persistence.data.nfs.server | string | `""` | NFS server (`type: nfs`). Needs `hostUsers: true`. |
| persistence.data.type | string | `"emptyDir"` | Where the media and download tree lives. Mount the same volume at the same path in every app that shares it: a hardlink or an atomic move needs one filesystem (see the README). `emptyDir` is scratch space lost with the pod; the other types use the matching sub-section. ReadWriteMany, or ReadWriteOnce with every pod on one node. `hostPath` and `nfs` ignore `fsGroup`: the share must be writable by uid/gid 65532. |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. `fsGroup` does not apply to NFS/SMB volumes or `hostPath`. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Readiness probe (`GET /ping`, which reads the database: the pod leaves the Service while it is down, without a restart). |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"192Mi"}}` | Resources of the Sonarr container. A scheduling floor, not a sizing: memory grows with the size of the library and of the searches (measure, then tune; VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ControllerRevisions to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context of the Sonarr container. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8989` | Web UI and API Service port (the container listens on 8989). |
| service.type | string | `"ClusterIP"` | Web UI and API Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":5}` | Startup probe (`GET /ping`, Kestrel listens only after the database migrations). A missing database makes Sonarr exit instead of waiting: the pod crash-loops until it exists. |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

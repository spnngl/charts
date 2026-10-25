# seerr

Seerr media request manager for Jellyfin, Emby and Plex as a hardened single-replica StatefulSet, with SQLite or an external PostgreSQL

Runs [Seerr](https://github.com/seerr-team/seerr) as a single-replica
StatefulSet. The image is built from
[spnngl/images](https://github.com/spnngl/images): distroless, non-root, no shell.

One replica only: Seerr is the sole writer of `/app/config` and of its SQLite
database. Every upgrade or reschedule is a short downtime.

## Install

```sh
kubectl create namespace seerr
helm install seerr oci://ghcr.io/spnngl/charts/seerr --version <version> -n seerr
```

The defaults start Seerr with SQLite in a `1Gi` PVC. Open the web UI and finish
the setup wizard **before exposing the Service**: the first sign-in with a
media server account becomes the admin. Seerr has no `External` auth mode: put
oauth2-proxy at the Ingress if you want one more layer.

Seerr keeps its settings in `settings.json`, edited in the UI; the chart has no
settings-as-code value. Behind an Ingress, enable "Enable Proxy Support" in
Settings › Networking (`trustProxy`) so Seerr sees client addresses.

### API key

Seerr generates its API key and keeps it in `settings.json`. To set it from a
Secret, create the Secret and point `apiKey.existingSecret.name` at it:

```sh
kubectl -n seerr create secret generic seerr-api --from-literal=api-key="$(openssl rand -hex 16)"
```

The chart passes it as `API_KEY`. The variable always wins in memory and
reaches `settings.json` on first boot or at the next save; the UI's
"regenerate" returns it unchanged. Rotate it through the Secret, then restart
the pod. The chart never creates the Secret.

```sh
kubectl -n seerr rollout restart statefulset/seerr
```

## External database

`externalDatabase.enabled: true` uses PostgreSQL instead of SQLite in
`/app/config`. Seerr creates its tables, never the database: create it first
(`seerr` by default), owned by the login in `externalDatabase.existingSecret`
(keys `username` and `password`, the shape of a CloudNativePG role Secret).

- One database per application: never point Seerr or another app at the same
  database.
- The chart does not migrate SQLite data: enabling it on an existing install
  starts empty (upstream: `docs/extending-seerr/database-config.mdx`, pgloader).
- TLS: `extraEnv` `DB_USE_SSL=true`, `DB_SSL_REJECT_UNAUTHORIZED` (default
  `true`) and `DB_SSL_CA`, `DB_SSL_KEY`, `DB_SSL_CERT` (or the same with a
  `_FILE` suffix, a path to a file mounted with `extraVolumes`).
- Seerr has no built-in backup. Back up PostgreSQL (CloudNativePG
  `ScheduledBackup`) and the config volume: `settings.json` stays on it.

The probes do not read the database: while PostgreSQL is down the pod stays in
the Service and serves errors.

## Web UI

```sh
kubectl -n seerr port-forward service/seerr 5055:5055
```

then <http://127.0.0.1:5055>. `ingress` (Ingress) and `httpRoute` (Gateway API
HTTPRoute) expose it; both need explicit hosts (and `parentRefs` for the route).
Terminate TLS in front: Seerr serves plain HTTP. Seerr has no URL base: it
serves at `/` only.

## Configuration

The chart sets `PORT`, `LOG_LEVEL=info` (upstream defaults to `debug`, one line
per request), `API_KEY` and the `DB_*` variables. `extraEnv` names the chart
owns fail the install; `LOG_LEVEL` is not owned: an `extraEnv` value replaces
the chart's. Other upstream variables go in `extraEnv`: `TZ`, `DB_POOL_SIZE`,
`DB_LOG_QUERIES`, `DB_USE_SSL`.

Seerr logs to standard output and to `/app/config/logs`. Collect the standard
output.

The pod gets a 5 s grace period: Seerr has no `SIGTERM` handler and runs as
PID 1, so a stop always ends in `SIGKILL` once it elapses.

The probes call `GET /api/v1/status/appdata`, which needs no login, no database
and no outbound call. `/api/v1/status` is not used: it queries GitHub without a
timeout and hangs when egress is blocked.

## Storage

- `/app/config` (`settings.json`, the SQLite database, logs, the image proxy
  cache): `persistence.config`.
- `/app/.next/cache` (Next.js' optimised images, rebuilt on demand): an
  `emptyDir`, with an optional `persistence.cache.sizeLimit`. A limit that is
  hit evicts the pod: leave it empty unless the node disk is tight.
- `/tmp`: an `emptyDir`.

`/app/config` takes one of four types in `persistence.config.type`:

- `volumeClaimTemplate` (default): a PVC per pod from the StatefulSet. The
  StatefulSet keeps its PVC when it is deleted or scaled down
  (`persistentVolumeClaimRetentionPolicy: Retain`), so `helm uninstall` leaves
  your data; delete the PVC by hand to remove it.
- `existingClaim`: an existing PVC (and optional `subPath`).
- `hostPath`: a directory on the node, owned by uid/gid 65532 (Kubernetes does
  not apply `fsGroup` to `hostPath`). Pin the pod with `nodeSelector`.
  `type: DirectoryOrCreate` makes a root-owned directory Seerr cannot write.
- `emptyDir`: scratch space, lost with the pod.

Use block storage with SQLite: it corrupts on NFS and SMB (use
`externalDatabase` there). Seerr's image cache (Settings › General, "Enable
Image Caching") grows with the library and can outgrow the default `1Gi`: size
the volume for it, or leave it off. A `volumeClaimTemplate` cannot be edited on
an existing StatefulSet, so changing `size` in values makes the upgrade fail.
To grow the volume, expand the PVC (the StorageClass must allow it), then
recreate the StatefulSet without touching pods or PVCs:

```sh
kubectl -n seerr delete statefulset seerr --cascade=orphan
helm upgrade seerr ... -n seerr
```

## Image

The default image is `appVersion`, pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates tag and
digest together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (a digest without a tag is an error).

The image is signed with cosign (keyless, GitHub Actions OIDC) and carries SLSA
provenance. See the repository README, "Verifying what you install".

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 65532,
read-only root filesystem (writes go to `/app/config`, `/app/.next/cache` and
`/tmp`), all capabilities dropped, no privilege escalation, `RuntimeDefault`
seccomp, no ServiceAccount token, no Service environment variables.

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
  When you set it, include the Ingress controller and every client of the API.
- `networkPolicy.egress.enabled` (off by default) allows DNS, `peers.to` (the
  internet except private, CGNAT and link-local ranges: TMDB and notification
  services, so a compromised process cannot move sideways) and `extraEgress`.
  Add `extraEgress` rules for PostgreSQL, Radarr, Sonarr and your media server
  when they sit in a private range.

## Autoscaling and resources

There is no HPA (one replica). `verticalPodAutoscaler` supports `Off`, `Initial`,
`Recreate` and `InPlaceOrRecreate` (in-place resize needs Kubernetes 1.33+). A
recommender started with another `--recommender-name` than `default` ignores the
VPA unless `verticalPodAutoscaler.recommender` names it. The default requests
are scheduling floors, not a sizing: measure then tune.

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
* <https://github.com/seerr-team/seerr>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| apiKey.existingSecret.key | string | `"api-key"` | Key of the API key in the Secret. |
| apiKey.existingSecret.name | string | `""` | Name of a Secret holding the API key, passed as `API_KEY`. Empty: no env, Seerr generates its own key and keeps it in `settings.json`. The chart never creates the Secret. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for external host names such as TMDB). |
| externalDatabase.database | string | `"seerr"` | Database name (`DB_NAME`). |
| externalDatabase.enabled | bool | `false` | Use an external PostgreSQL instead of SQLite in `/app/config`. Seerr creates its tables but no database: create it first. Enabling it on an existing install starts empty; the SQLite data is not migrated. |
| externalDatabase.existingSecret.name | string | `""` | Name of the Secret holding the database login (for example a CloudNativePG role Secret). Required when enabled. The chart never creates it. |
| externalDatabase.existingSecret.passwordKey | string | `"password"` | Key of the password in the Secret. |
| externalDatabase.existingSecret.usernameKey | string | `"username"` | Key of the user name in the Secret. |
| externalDatabase.host | string | `""` | PostgreSQL host. Required when enabled. |
| externalDatabase.port | int | `5432` | PostgreSQL port. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the Seerr container: `LOG_LEVEL` (the chart sets `info`; this overrides it), `TZ`, `DB_USE_SSL` and `DB_SSL_*` (PostgreSQL TLS), `DB_POOL_SIZE`. Names the chart sets are rejected: `API_KEY`, `PORT`, `HOST`, `CONFIG_DIRECTORY`, `DB_TYPE`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASS`, `DB_SOCKET_PATH`. Names are case-sensitive. |
| extraInitContainers | list | `[]` | Extra init containers, rendered as given: seed a file before start, or run a native sidecar (`restartPolicy: Always`) that calls the API. The Seerr image has no shell: use another image. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Seerr container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+) and idmapped mounts on every volume's file system (not NFS/SMB, not `hostPath` on some file systems); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute for the web UI (path prefix `/`). |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/seerr"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress for the web UI (path `/`). |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Liveness probe (`GET /api/v1/status/appdata`: a database outage must not restart the pod). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, the internet for TMDB and notifications, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s: the database, Radarr, Sonarr and the media server (they are in the private ranges `peers` excludes). |
| networkPolicy.egress.peers.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["fc00::/7","fe80::/10"]}}]` | TMDB, notification services and other internet hosts (any port). Default: the internet, not the private, CGNAT and link-local ranges, so a compromised process cannot move sideways. Remove an `except` entry to reach a provider there. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: the web port). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the web UI and API port. Empty: any source. It must admit the Ingress controller and every client of the API. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. With a `hostPath`, pin the pod to the node. |
| persistence.cache.sizeLimit | string | `""` | Size limit of the `emptyDir` on `/app/.next/cache` (Next.js' optimised images, rebuilt on demand). Empty: none. A limit that is hit evicts the pod. |
| persistence.config.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`, state is lost with the pod). Empty: none. |
| persistence.config.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.config.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.config.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), owned by uid/gid 65532. Pin the pod to the node. |
| persistence.config.hostPath.type | string | `"Directory"` | `hostPath` type. `DirectoryOrCreate` makes a root-owned directory the app cannot write. |
| persistence.config.type | string | `"volumeClaimTemplate"` | Where `/app/config` (`settings.json`, the SQLite database unless `externalDatabase.enabled`, logs, the image proxy cache) lives. Block storage: SQLite on NFS corrupts. `volumeClaimTemplate` creates a PVC per pod and keeps it on uninstall; the other types use the matching sub-section. |
| persistence.config.volumeClaimTemplate.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.config.volumeClaimTemplate.annotations | object | `{}` | PVC annotations. |
| persistence.config.volumeClaimTemplate.labels | object | `{}` | PVC labels. |
| persistence.config.volumeClaimTemplate.size | string | `"1Gi"` | Requested size. The template is immutable once installed: resize the PVC, see the README. |
| persistence.config.volumeClaimTemplate.storageClassName | string | `""` | StorageClass (empty: cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. `fsGroup` does not apply to NFS/SMB volumes or `hostPath`. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Readiness probe (`GET /api/v1/status/appdata`, which does not read the database: the pod stays in the Service while PostgreSQL is down). |
| resources | object | `{"limits":{"memory":"768Mi"},"requests":{"cpu":"50m","memory":"256Mi"}}` | Resources of the Seerr container. A scheduling floor, not a sizing: memory grows with the number of users and the size of the media scans (measure, then tune; VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ControllerRevisions to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context of the Seerr container (read-only root filesystem: it writes only to the `/app/config`, `/app/.next/cache` and `/tmp` volumes). Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `5055` | Web UI and API Service port (the container listens on 5055). |
| service.type | string | `"ClusterIP"` | Web UI and API Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":5}` | Startup probe (`GET /api/v1/status/appdata`, which needs no login, no database and no outbound call; `/api/v1/status` calls GitHub and hangs with egress blocked). |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

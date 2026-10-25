# bazarr

Bazarr subtitle manager for Sonarr and Radarr as a hardened single-replica StatefulSet, with SQLite or an external PostgreSQL

Runs [Bazarr](https://github.com/morpheus65535/bazarr) as a single-replica
StatefulSet. The image is built from
[spnngl/images](https://github.com/spnngl/images): distroless, non-root, no shell.

One replica only: Bazarr is the sole writer of `/config` and of its SQLite
database. Every upgrade or reschedule is a short downtime.

## Install

```sh
kubectl create namespace bazarr
helm install bazarr oci://ghcr.io/spnngl/charts/bazarr --version <version> -n bazarr
```

The defaults start Bazarr with SQLite in a `1Gi` PVC and **no login**: Bazarr
has none by default, and its web UI then shows the API key to whoever reaches
it. Set a login (Settings › General, or `config.auth` below) before exposing the
Service.

## Settings as code

`config` holds Bazarr settings in the shape of its `config.yaml` (`general`,
`auth`, `sonarr`, `radarr`, providers, ...). The chart renders it to a
ConfigMap that Bazarr loads at every start over its saved settings
(`INCLUDES_FOR_DYNACONF`); changing it restarts the pod.

Each top-level section you list **replaces** Bazarr's whole section:

- a change made in the UI anywhere in that section reverts at the next start;
- a key you leave out of a listed section takes Bazarr's default, not its
  saved value;
- a section you do not list keeps what was saved in the UI.

List complete sections, or none. Language profiles are database rows, not
settings: set them in the UI or through the API.

The chart owns some keys and rejects them in `config`: `postgresql` (use
`externalDatabase`), `auth.apikey` (use `apiKey.existingSecret`), `general.ip`
and `general.port` (they match the Service, probes and NetworkPolicy).

### Secrets

The ConfigMap is readable by anyone who can read the namespace: secrets go in
`extraEnv`, from a Secret. Dynaconf reads `DYNACONF_<SECTION>__<key>` and parses
the value as TOML: load the Secret into a plain variable first, then pass it
with `@str` so it stays a string. A value made only of digits can still turn
into a number and be reset to empty (a Dynaconf bug, seen with an API key of
bare digits): random hex keys are safe. Sonarr's API key, for example:

```yaml
config:
  general:
    use_sonarr: true
  sonarr:
    ip: sonarr.media.svc
    port: 8989
extraEnv:
  - name: SONARR_API_KEY
    valueFrom:
      secretKeyRef:
        name: sonarr-api
        key: api-key
  - name: DYNACONF_SONARR__apikey
    value: "@str $(SONARR_API_KEY)"
```

Kubernetes expands `$(SONARR_API_KEY)` only when it is defined earlier in the
list. Bazarr also copies these values into `/config/config/config.yaml`.

### Login

`config.auth` replaces the whole `auth` section, saved API key included, so it
requires `apiKey.existingSecret.name`: without it Bazarr would generate a new
key at every start. Bazarr stores the password as an unsalted MD5 hex digest:

```sh
kubectl -n bazarr create secret generic bazarr-login \
  --from-literal=password-md5="$(printf %s "$PASSWORD" | openssl md5 -r | cut -d" " -f1)"
```

```yaml
apiKey:
  existingSecret:
    name: bazarr-api
config:
  auth:
    type: form # or basic
    username: admin
extraEnv:
  - name: BAZARR_PASSWORD_MD5
    valueFrom:
      secretKeyRef:
        name: bazarr-login
        key: password-md5
  - name: DYNACONF_AUTH__password
    value: "@str $(BAZARR_PASSWORD_MD5)"
```

The API stays reachable with the API key whatever the login.

### API key

Bazarr generates its API key and keeps it in `/config/config/config.yaml`. To
set it from a Secret, create the Secret and point `apiKey.existingSecret.name`
at it:

```sh
kubectl -n bazarr create secret generic bazarr-api --from-literal=api-key="$(openssl rand -hex 16)"
```

Bazarr reads it once at startup: restart the pod after changing it. The chart
never creates the Secret.

```sh
kubectl -n bazarr rollout restart statefulset/bazarr
```

## External database

`externalDatabase.enabled: true` uses PostgreSQL instead of SQLite in `/config`.
Bazarr creates its tables, never the database: create it first (`bazarr` by
default), owned by the login in `externalDatabase.existingSecret` (keys
`username` and `password`, the shape of a CloudNativePG role Secret). A missing
database makes the pod crash-loop.

- One database per application: never point Bazarr or another app at the same
  database.
- The chart does not migrate SQLite data: enabling it on an existing install
  starts empty.
- Bazarr connects with TLS when the server offers it, without verifying the
  certificate. For other connection options, set `POSTGRES_URL` in `extraEnv`
  to a URL that carries only them, for example
  `postgresql://?sslmode=verify-full&sslrootcert=/certs/ca.crt` (mount the CA
  with `extraVolumes`): the chart's host, port, database and login fill in the
  rest.
- Back up PostgreSQL yourself. Bazarr's own backups hold its settings only
  when PostgreSQL is enabled.

The probes do not read the database: while PostgreSQL is down the pod stays in
the Service and serves errors.

## Web UI

```sh
kubectl -n bazarr port-forward service/bazarr 6767:6767
```

then <http://127.0.0.1:6767>. `ingress` (Ingress) and `httpRoute` (Gateway API
HTTPRoute) expose it; both need explicit hosts (and `parentRefs` for the route).
Terminate TLS in front: Bazarr serves plain HTTP.

To serve under a path, set `config.general.base_url` (for example `/bazarr`):
the chart pins it and prefixes the probe, Ingress and HTTPRoute paths with it.

## Configuration

Command-line options go in `extraArgs` (`--debug`, `--no-tasks`,
`--no-signalr`). The chart passes `--config /config --port 6767` last, so they
win.

The pinned port, bind address and URL base keep the Service, probes and
NetworkPolicy valid: changing them in Settings › General has no effect.

Bazarr logs to standard output and to files in `/config/log`. Collect the
standard output.

## Storage

Two volumes: `/config` (state) and `/data` (the media library, see Data volume).

`/config` takes one of four types in `persistence.config.type`:

- `volumeClaimTemplate` (default): a PVC per pod from the StatefulSet. The
  StatefulSet keeps its PVC when it is deleted or scaled down
  (`persistentVolumeClaimRetentionPolicy: Retain`), so `helm uninstall` leaves
  your data; delete the PVC by hand to remove it.
- `existingClaim`: an existing PVC (and optional `subPath`).
- `hostPath`: a directory on the node, owned by uid/gid 65532 (Kubernetes does
  not apply `fsGroup` to `hostPath`). Pin the pod with `nodeSelector`.
  `type: DirectoryOrCreate` makes a root-owned directory Bazarr cannot write.
- `emptyDir`: scratch space, lost with the pod.

Use block storage with SQLite: it corrupts on NFS and SMB (use
`externalDatabase` there). A `volumeClaimTemplate` cannot be edited on an
existing StatefulSet, so changing `size` in values makes the upgrade fail. To
grow the volume, expand the PVC (the StorageClass must allow it), then recreate
the StatefulSet without touching pods or PVCs:

```sh
kubectl -n bazarr delete statefulset bazarr --cascade=orphan
helm upgrade bazarr ... -n bazarr
```

## Data volume

`persistence.data` mounts the media library Bazarr writes subtitles into, next
to the video files, at `/data` by default (`emptyDir`, scratch space, until you
choose a type):

- `existingClaim`: a PVC, ReadWriteMany or ReadWriteOnce with every pod on one
  node, with an optional `subPath`.
- `hostPath`: a node directory, writable by uid/gid 65532 (Kubernetes does not
  apply `fsGroup`). Pin the pod with `nodeSelector`.
- `nfs`: `server` and `path`; needs `hostUsers: true` and an export writable by
  65532.

Bazarr opens the paths Sonarr and Radarr report. Mount the same volume at the
same path as in those charts (`/data`), and no path mapping is needed;
otherwise set `general.path_mappings` and `general.path_mappings_movie`.

A library on S3 is a FUSE mount made on the node, under the `hostPath`, by
another pod: set `mountPropagation: HostToContainer` so Bazarr sees the mount
even when it starts first. `Bidirectional` is not offered. Bazarr's `/config` and
its database never go on S3.

## Image

The default image is `appVersion`, pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates tag and
digest together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (a digest without a tag is an error).

The image is signed with cosign (keyless, GitHub Actions OIDC) and carries SLSA
provenance. See the repository README, "Verifying what you install".

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 65532,
read-only root filesystem (writes go to `/config`, `/data` and an `emptyDir` on `/tmp`),
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
  When you set it, include the Ingress controller and every client of the API.
- `networkPolicy.egress.enabled` (off by default) allows DNS, `peers.to` (the
  internet except private, CGNAT and link-local ranges: subtitle providers, so
  a compromised process cannot move sideways) and `extraEgress`. Add
  `extraEgress` rules for PostgreSQL, Sonarr, Radarr, or a media server on your
  LAN.

## Autoscaling and resources

There is no HPA (one replica). `verticalPodAutoscaler` supports `Off`, `Initial`,
`Recreate` and `InPlaceOrRecreate` (in-place resize needs Kubernetes 1.33+). A
recommender started with another `--recommender-name` than `default` ignores the
VPA unless `verticalPodAutoscaler.recommender` names it. The default requests
are scheduling floors, not a sizing: memory grows with the size of the library
and with subtitle syncing, so measure then tune.

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
* <https://github.com/morpheus65535/bazarr>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| apiKey.existingSecret.key | string | `"api-key"` | Key of the API key in the Secret. |
| apiKey.existingSecret.name | string | `""` | Name of a Secret holding the API key, passed as `DYNACONF_AUTH__apikey`. Empty: no env, Bazarr generates its own key and keeps it in `/config/config/config.yaml`. The chart never creates the Secret. |
| config | object | `{}` | Bazarr settings as code, in the shape of its `config.yaml` (`general`, `auth`, `sonarr`, `radarr`, ...), loaded over the saved settings at every start. Each top-level section listed replaces Bazarr's whole section: a UI edit anywhere in it reverts at the next start, and a key left out takes Bazarr's default; unlisted sections keep their saved values. Secrets do not belong here (the ConfigMap is readable): pass them by `extraEnv` (see the README). Not allowed: `postgresql` (use `externalDatabase`), `auth.apikey` (use `apiKey.existingSecret`), `general.ip` and `general.port` (fixed to match the Service). `general.base_url` also prefixes the probe, Ingress and HTTPRoute paths. `auth` requires `apiKey.existingSecret.name`. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for subtitle provider host names). |
| externalDatabase.database | string | `"bazarr"` | Database name (`POSTGRES_DATABASE`). |
| externalDatabase.enabled | bool | `false` | Use an external PostgreSQL instead of SQLite in `/config`. Bazarr creates its tables but no database: create it first. Enabling it on an existing install starts empty; the SQLite data is not migrated. |
| externalDatabase.existingSecret.name | string | `""` | Name of the Secret holding the database login (for example a CloudNativePG role Secret). Required when enabled. The chart never creates it. |
| externalDatabase.existingSecret.passwordKey | string | `"password"` | Key of the password in the Secret. |
| externalDatabase.existingSecret.usernameKey | string | `"username"` | Key of the user name in the Secret. |
| externalDatabase.host | string | `""` | PostgreSQL host. Required when enabled. |
| externalDatabase.port | int | `5432` | PostgreSQL port. |
| extraArgs | list | `[]` |  |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the Bazarr container, for example a secret setting from a Secret: `DYNACONF_SONARR__apikey` with `valueFrom` and the value `@str $(VAR)` form (see the README). Names the chart sets are rejected: `BAZARR_API_KEY`, `INCLUDES_FOR_DYNACONF`, `POSTGRES_{ENABLED,HOST,PORT,DATABASE,USERNAME,PASSWORD}`, and the `DYNACONF_` keys `AUTH`, `AUTH__apikey`, `GENERAL`, `GENERAL__ip`, `GENERAL__base_url`, `POSTGRESQL`, `POSTGRESQL__enabled` in any case. |
| extraInitContainers | list | `[]` | Extra init containers, rendered as given: seed a file before start, or run a native sidecar (`restartPolicy: Always`) that calls the API. The image has no shell: use another image. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Bazarr container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+) and idmapped mounts on every volume's file system (not NFS/SMB, not `hostPath` on some file systems); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute for the web UI (path prefix `/`, or `config.general.base_url`). |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/bazarr"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress for the web UI (path `/`, or `config.general.base_url`). |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Liveness probe (TCP on the web port: a database outage must not restart the pod). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, internet subtitle providers, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s: the database, Sonarr, Radarr, a media server. |
| networkPolicy.egress.peers.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["fc00::/7","fe80::/10"]}}]` | Subtitle providers and notification services (any port). Default: the internet, not the private, CGNAT and link-local ranges, so a compromised process cannot move sideways. Remove an `except` entry to reach a provider there. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: the web port). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the web UI and API port. Empty: any source. It must admit the Ingress controller and every client of the API. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. With a `hostPath`, pin the pod to the node. |
| persistence.config.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`, state is lost with the pod). Empty: none. |
| persistence.config.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.config.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.config.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), owned by uid/gid 65532. Pin the pod to the node. |
| persistence.config.hostPath.type | string | `"Directory"` | `hostPath` type. `DirectoryOrCreate` makes a root-owned directory the app cannot write. |
| persistence.config.type | string | `"volumeClaimTemplate"` | Where `/config` (`config/config.yaml`, the SQLite database unless `externalDatabase.enabled`, logs, backups, cache) lives. Block storage: SQLite on NFS corrupts. `volumeClaimTemplate` creates a PVC per pod and keeps it on uninstall; the other types use the matching sub-section. |
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
| persistence.data.type | string | `"emptyDir"` | Where the media library lives: Bazarr writes subtitles next to the video files. Mount the same volume at the same path as in Sonarr and Radarr, or map the paths in Bazarr's settings (see the README). `emptyDir` is scratch space lost with the pod; the other types use the matching sub-section. ReadWriteMany, or ReadWriteOnce with every pod on one node. `hostPath` and `nfs` ignore `fsGroup`: the share must be writable by uid/gid 65532. |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. `fsGroup` does not apply to NFS/SMB volumes or `hostPath`. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Readiness probe (`GET <base_url>/api/system/ping`, which does not read the database: the pod stays in the Service while PostgreSQL is down). |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"192Mi"}}` | Resources of the Bazarr container. A scheduling floor, not a sizing: memory grows with the size of the library and with subtitle syncing (measure, then tune; VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ControllerRevisions to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context of the Bazarr container. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `6767` | Web UI and API Service port (the container listens on 6767). |
| service.type | string | `"ClusterIP"` | Web UI and API Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":5}` | Startup probe (`GET <base_url>/api/system/ping`, served once the database migrations are done). A missing database makes Bazarr exit instead of waiting: the pod crash-loops until it exists. |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

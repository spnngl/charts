# sabnzbd

SABnzbd Usenet downloader as a hardened single-replica StatefulSet, with settings as code

Runs [SABnzbd](https://github.com/sabnzbd/sabnzbd) as a single-replica
StatefulSet. The image is built from
[spnngl/images](https://github.com/spnngl/images): distroless, non-root, no shell.

One replica only: SABnzbd is the sole writer of `/config` and of its download
folders. Every upgrade or reschedule is a short downtime.

## Install

```sh
kubectl create namespace sabnzbd
helm install sabnzbd oci://ghcr.io/spnngl/charts/sabnzbd --version <version> -n sabnzbd
```

The defaults start SABnzbd with its state in a `1Gi` PVC, downloads under
`/data/usenet` and **no login**: its web UI then shows the API key to whoever
reaches it. Set a login (see Secrets) before exposing the Service. The first
visit opens SABnzbd's wizard: add a Usenet server there, or in `secretConfig`.

## Settings as code

SABnzbd reads its settings from `/config/sabnzbd.ini` only: no environment
variable or flag sets them. Before each start, the `config` init container
merges into that file, in order:

1. `config`, from a ConfigMap (a change restarts the pod);
2. the ini fragment in the `secretConfig.existingSecret` Secret, when set.

`config` has the shape of `sabnzbd.ini`: sections of keys, and `servers`,
`categories`, `rss` and `sorters` of one map per entry. Booleans become `1`/`0`,
lists become comma-separated values. For example:

```yaml
config:
  misc:
    download_dir: /data/usenet/incomplete
    complete_dir: /data/usenet/complete
    host_whitelist: [sabnzbd.example.com]
  categories:
    movies:
      dir: movies
    tv:
      dir: tv
```

The merge rules:

- a key you list wins at every start: a UI change to it reverts at the next
  start;
- a key you do not list keeps what was saved in the UI;
- nothing is removed: a server or category you drop from values stays in the
  ini. Delete it in the UI.

`misc.config_lock: true` makes the UI settings read-only, for settings fully as
code. `misc.host` and `misc.port` have no effect: the image starts SABnzbd with
`--server 0.0.0.0:8080`, which matches the Service, probes and NetworkPolicy.

The init container stops the pod when the ini and its `.bak` copy are both
unreadable: repair or delete `/config/sabnzbd.ini`, then restart the pod.

### Secrets

The ConfigMap is readable by anyone who can read the namespace. Secrets go in
an ini fragment, in a Secret you create (key `sabnzbd.ini` by default):

```ini
[misc]
api_key = <32 hex characters>
nzb_key = <32 hex characters>
username = admin
password = <password>

[servers]
[[news.example.com]]
host = news.example.com
port = 563
ssl = 1
username = <login>
password = <password>
connections = 20
```

```sh
kubectl -n sabnzbd create secret generic sabnzbd-ini --from-file=sabnzbd.ini=./sabnzbd.ini
```

```yaml
secretConfig:
  existingSecret:
    name: sabnzbd-ini
```

Only the init container mounts the Secret; SABnzbd reads the merged ini. The
Secret is read at startup only: restart the pod after changing it.

```sh
kubectl -n sabnzbd rollout restart statefulset/sabnzbd
```

SABnzbd saves passwords in the ini as hex (`!!!encoded!!!`), which is an
encoding, not encryption: anyone who reads `/config` reads them.

Radarr and Sonarr need the same API key: keep it in one Secret, or copy it from
Settings › General.

## Clients

Point Radarr, Sonarr and Prowlarr at
`sabnzbd.<namespace>.svc.cluster.local`, port `8080`. SABnzbd checks the
`Host` header: names ending in `.local` pass, short names (`sabnzbd`,
`sabnzbd.<namespace>`) and other cluster domains get `403` unless listed in
`config.misc.host_whitelist` or a login is set.

## Web UI

```sh
kubectl -n sabnzbd port-forward service/sabnzbd 8080:8080
```

then <http://127.0.0.1:8080>. `ingress` (Ingress) and `httpRoute` (Gateway API
HTTPRoute) expose it on path `/`; both need explicit hosts (and `parentRefs` for
the route). Terminate TLS in front: SABnzbd serves plain HTTP.

Behind an Ingress, SABnzbd sees the client in `X-Forwarded-For` and refuses
public addresses (`403 External internet access denied`). Allow them, and list
the host names:

```yaml
config:
  misc:
    inet_exposure: 5 # web UI, login for external clients only; 4: web UI, login (when set) for all
    host_whitelist: [sabnzbd.example.com]
```

The probes call `/api?mode=auth&output=json`, which needs no API key. SABnzbd
accepts it from the kubelet when the node IP is private (RFC 1918 and the like).
With public node IPs or a `100.64.0.0/10` node network, set
`config.misc.local_ranges`: it replaces the private ranges, so list the node,
pod and LAN ranges together.

## Storage

Two volumes: `/config` (state) and the data volume (downloads, see Data volume).

`/config` holds `sabnzbd.ini`, the queue state and the history (SQLite) in
`admin/`, and logs. It takes one of four types in `persistence.config.type`:

- `volumeClaimTemplate` (default): a PVC per pod from the StatefulSet. The
  StatefulSet keeps its PVC when it is deleted or scaled down
  (`persistentVolumeClaimRetentionPolicy: Retain`), so `helm uninstall` leaves
  your data; delete the PVC by hand to remove it.
- `existingClaim`: an existing PVC (and optional `subPath`).
- `hostPath`: a directory on the node, owned by uid/gid 65532 (Kubernetes does
  not apply `fsGroup` to `hostPath`). Pin the pod with `nodeSelector`.
  `type: DirectoryOrCreate` makes a root-owned directory SABnzbd cannot write.
- `emptyDir`: scratch space, lost with the pod.

Use block storage: SQLite corrupts on NFS and SMB. A `volumeClaimTemplate`
cannot be edited on an existing StatefulSet, so changing `size` in values makes
the upgrade fail. To grow the volume, expand the PVC (the StorageClass must
allow it), then recreate the StatefulSet without touching pods or PVCs:

```sh
kubectl -n sabnzbd delete statefulset sabnzbd --cascade=orphan
helm upgrade sabnzbd ... -n sabnzbd
```

## Data volume

`persistence.data` holds the downloads, at `/data` by default (`emptyDir`,
scratch space, until you choose a type):

- `existingClaim`: a PVC, ReadWriteMany or ReadWriteOnce with every pod on one
  node, with an optional `subPath`.
- `hostPath`: a node directory, writable by uid/gid 65532 (Kubernetes does not
  apply `fsGroup`). Pin the pod with `nodeSelector`.
- `nfs`: `server` and `path`; needs `hostUsers: true` and an export writable by
  65532.

`config.misc.download_dir` and `complete_dir` default to
`/data/usenet/incomplete` and `/data/usenet/complete`. Changing
`persistence.data.mountPath` means changing them too: SABnzbd creates them at
every start, and a path outside the volume fails on the read-only root
filesystem. Unfinished jobs also keep their state there, in `__ADMIN__`.

Mount the same volume at the same path in Radarr and Sonarr: they import from
the path SABnzbd reports, by hardlink or move, without a copy or a path mapping.

When the completed folder is a FUSE mount made on the node, under the
`hostPath`, by another pod (an S3 bucket through the rclone chart), set
`mountPropagation: HostToContainer` so SABnzbd sees the mount even when it
starts first. `Bidirectional` is not offered. `/config` never goes on S3.

## Logs

SABnzbd logs to standard output and to `/config/logs/sabnzbd.log` (6 files of
5 MiB), which its UI reads. Collect the standard output.

## Image

The default image is `appVersion`, pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates tag and
digest together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (a digest without a tag is an error). The init container uses the
same image.

The image is signed with cosign (keyless, GitHub Actions OIDC) and carries SLSA
provenance. See the repository README, "Verifying what you install".

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 65532,
read-only root filesystem (writes go to `/config`, the data volume and an
`emptyDir` on `/tmp`), all capabilities dropped, no privilege escalation,
`RuntimeDefault` seccomp, no ServiceAccount token, no Service environment
variables. The init container runs with the same security context.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in the
pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support (containerd
2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+. On other nodes the
pod sandbox cannot be created: set `hostUsers: true`. Volumes without idmapped
mounts (NFS, SMB) and `hostPath` ownership need it too.

## Network

- SABnzbd listens on IPv4 only (`0.0.0.0:8080`): single-stack IPv6 clusters
  cannot reach it.
- The NetworkPolicy (`networkPolicy.enabled`, on by default) allows the web
  port. `networkPolicy.http.from` restricts the sources; empty means any source.
  When you set it, include the Ingress controller and every client of the API
  (Radarr, Sonarr, Prowlarr).
- `networkPolicy.egress.enabled` (off by default) allows DNS, `peers.to` (the
  internet except private, CGNAT and link-local ranges: Usenet servers and the
  version check, so a compromised process cannot move sideways) and
  `extraEgress`. Add `extraEgress` rules for a Usenet server, an indexer or a
  notification target on your LAN.

## Autoscaling and resources

There is no HPA (one replica). `verticalPodAutoscaler` supports `Off`, `Initial`,
`Recreate` and `InPlaceOrRecreate` (in-place resize needs Kubernetes 1.33+). A
recommender started with another `--recommender-name` than `default` ignores the
VPA unless `verticalPodAutoscaler.recommender` names it.

The default requests are scheduling floors, not a sizing: par2 repair and
unpacking use CPU. SABnzbd sizes its article cache once, at the first start, to
a quarter of the memory limit (at most 1 GiB), and keeps that value: set the
memory limit before the first start, or set `config.misc.cache_limit`.

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
* <https://github.com/sabnzbd/sabnzbd>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| config | object | `{"misc":{"complete_dir":"/data/usenet/complete","download_dir":"/data/usenet/incomplete"}}` | SABnzbd settings as code, in the shape of `sabnzbd.ini`: sections (`misc`, `logging`, ...) of keys, and `servers`, `categories`, `rss`, `sorters` of one map per entry. Merged into `/config/sabnzbd.ini` at every start: a listed key reverts a UI edit at the next start, an unlisted key keeps its saved value, nothing is removed (a server left out stays: delete it in the UI). Booleans become `1`/`0`, lists comma-separated. The default puts downloads on the data volume; change it with `persistence.data.mountPath`. Secrets do not belong here (the ConfigMap is readable): use `secretConfig`. `misc.host` and `misc.port` have no effect: the image's `--server 0.0.0.0:8080` wins. |
| config.misc.complete_dir | string | `"/data/usenet/complete"` | Completed downloads, under `persistence.data.mountPath`: the path Radarr and Sonarr import from. |
| config.misc.download_dir | string | `"/data/usenet/incomplete"` | Incomplete downloads, under `persistence.data.mountPath`. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for Usenet server host names). |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the SABnzbd container, for example `TZ`. SABnzbd reads no settings from env: use `config` and `secretConfig`. |
| extraInitContainers | list | `[]` | Extra init containers, rendered as given: seed a file before start, or run a native sidecar (`restartPolicy: Always`) that calls the API. The image has no shell: use another image. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the SABnzbd container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+) and idmapped mounts on every volume's file system (not NFS/SMB, not `hostPath` on some file systems); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute for the web UI (path prefix `/`). Also set `config.misc.inet_exposure` and `config.misc.host_whitelist` (see the README). |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/sabnzbd"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress for the web UI (path `/`). Also set `config.misc.inet_exposure` and `config.misc.host_whitelist` (see the README). |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Liveness probe (`GET /api?mode=auth&output=json`). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, Usenet servers and update checks on the internet, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s: a Usenet server, an indexer or a notification target in a private range. |
| networkPolicy.egress.peers.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["fc00::/7","fe80::/10"]}}]` | Usenet servers, the version check and notification services (any port). Default: the internet, not the private, CGNAT and link-local ranges, so a compromised process cannot move sideways. Remove an `except` entry to reach a provider there. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: the web port). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the web UI and API port. Empty: any source. It must admit the Ingress controller and every client of the API. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. With a `hostPath`, pin the pod to the node. |
| persistence.config.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`, state is lost with the pod). Empty: none. |
| persistence.config.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.config.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.config.hostPath.path | string | `""` | Absolute node path (`type: hostPath`), owned by uid/gid 65532. Pin the pod to the node. |
| persistence.config.hostPath.type | string | `"Directory"` | `hostPath` type. `DirectoryOrCreate` makes a root-owned directory the app cannot write. |
| persistence.config.type | string | `"volumeClaimTemplate"` | Where `/config` (`sabnzbd.ini`, the queue state, the SQLite history in `admin/`, logs) lives. Block storage: SQLite on NFS corrupts. `volumeClaimTemplate` creates a PVC per pod and keeps it on uninstall; the other types use the matching sub-section. |
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
| persistence.data.type | string | `"emptyDir"` | Where downloads land (`config.misc.download_dir` and `complete_dir`). Mount the same volume at the same path as in Sonarr and Radarr: their imports then hardlink or move instead of copying. `emptyDir` is scratch space lost with the pod; the other types use the matching sub-section. ReadWriteMany, or ReadWriteOnce with every pod on one node. `hostPath` and `nfs` ignore `fsGroup`: the share must be writable by uid/gid 65532. |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. `fsGroup` does not apply to NFS/SMB volumes or `hostPath`. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Readiness probe (`GET /api?mode=auth&output=json`). |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resources of the SABnzbd container and of the config init container. A scheduling floor, not a sizing: par2 repair and unpacking use CPU, the article cache uses memory (measure, then tune; VPA in `Off` mode gives recommendations). SABnzbd sizes its article cache at the first start to a quarter of the memory limit (at most 1 GiB) and keeps it: set the limit before, or set `config.misc.cache_limit`. No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ControllerRevisions to keep. |
| secretConfig.existingSecret.key | string | `"sabnzbd.ini"` | Key of the ini fragment in the Secret. |
| secretConfig.existingSecret.name | string | `""` | Name of a Secret holding an `sabnzbd.ini` fragment merged after `config`: `misc.api_key`, `misc.nzb_key`, `misc.username`, `misc.password`, Usenet logins under `servers`. Mounted in the config init container only. Read at startup: roll the pod after a change. Empty: none. The chart never creates it. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context of the SABnzbd container. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8080` | Web UI and API Service port (the container listens on 8080). |
| service.type | string | `"ClusterIP"` | Web UI and API Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":5}` | Startup probe (`GET /api?mode=auth&output=json`, which needs no API key). SABnzbd refuses it when the kubelet's source IP is not private, or not in `config.misc.local_ranges` when set (see the README). |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

# mjolnir

Mjolnir Matrix moderation bot as a hardened single-replica StatefulSet

Runs [Mjolnir](https://github.com/matrix-org/mjolnir), a moderation bot for
Matrix, as a single-replica StatefulSet. The image is built from
[spnngl/images](https://github.com/spnngl/images): distroless, non-root, no shell.

One replica only: two bots on one account act twice on every event and share one
crypto device. Every upgrade or reschedule is a short downtime: the StatefulSet
stops the old pod before it starts the new one. `replicaCount: 0` pauses the bot.

## Install

Mjolnir needs a Matrix account of its own, a management room and a Secret with its
credentials. The chart creates none of them.

1. Register the bot's account on your homeserver. Give it Synapse **admin rights**
   if you want the commands that need them (deactivate users, shut down rooms,
   move aliases) or `pollReports`.
2. Create the management room with a moderator, and invite the bot's account to it.
3. Create the Secret: one key holding a YAML fragment, merged over `config`.
   Mjolnir takes either an access token or, for
   [encrypted rooms](#encryption), a username and password:

   ```sh
   # access token
   kubectl -n moderation create secret generic mjolnir-credentials \
     --from-literal=config.yaml='accessToken: <token>'

   # username and password (with config.encryption.use: true)
   kubectl -n moderation create secret generic mjolnir-credentials \
     --from-literal=config.yaml=$'encryption:\n  username: mjolnir\n  password: <password>'
   ```
4. Install with your homeserver and management room:

   ```sh
   helm install mjolnir oci://ghcr.io/spnngl/charts/mjolnir --version <version> -n moderation --create-namespace \
     --set existingSecret.name=mjolnir-credentials \
     --set config.homeserverUrl=https://matrix.example.com \
     --set config.managementRoom='#moderators:example.com'
   ```

`config.homeserverUrl` and `config.managementRoom` default to placeholders that
only let the chart render without values: change both, or the bot cannot start.
The startup probe turns Ready once Mjolnir has synced its lists and checked its
permissions in every protected room (up to 10 minutes are allowed).

### Settings

Everything else goes in `config`: Mjolnir's `config/default.yaml`
([upstream](https://github.com/matrix-org/mjolnir/blob/main/config/default.yaml)).
The chart renders it into a ConfigMap (`production.yaml`) and the Secret becomes
`local.yaml` in a second directory; Mjolnir (node-config) merges both over its
defaults, the Secret last. `rawHomeserverUrl` (the address of the admin API,
which Mjolnir otherwise assumes is `http://localhost:8008`) defaults to
`config.homeserverUrl`: set it when Synapse has an internal address.

Keys the chart owns are rejected in `config`: `dataPath`, `health.healthz`,
`health.openMetrics` (turned on with `metrics.enabled`), `web.port` and
`web.address`. So are the secrets, which belong in the Secret and not in a
ConfigMap, Helm release history and Git: `accessToken`, `encryption.password`,
`pantalaimon.password`, `MAS.clientSecret`,
`web.synapseHTTPAntispam.authorization` and `health.sentry.dsn`. `extraEnv`
rejects `NODE_CONFIG_DIR` and `NODE_ENV`, and `extraArgs` rejects
`--mjolnir-config`, which makes Mjolnir ignore both directories.

Mjolnir reads its settings and the Secret **at start only**. After editing the
Secret, restart the pod (`kubectl rollout restart statefulset/<fullname>`), or
change `existingSecret.revision` (any string, a hash of the Secret from CI for
instance) to roll it. A change to `config` rolls the pod by itself.

### Encryption

With `config.encryption.use: true` Mjolnir logs in with a password and keeps an
end-to-end encryption device in `/data`. Losing that volume means a new login and a
new device on every restart: the chart refuses `emptyDir` together with
`config.encryption.use`.

## Web API

`config.web.enabled: true` serves, on port 8081 (the chart owns it: upstream's
default collides with the health endpoint), the abuse report API
(`config.web.abuseReporting`), the Synapse antispam hooks
(`config.web.synapseHTTPAntispam`) and the rule server
(`config.web.ruleServer`). The chart then adds a Service (`service.type`,
`service.port`) and a NetworkPolicy rule.

**The rule server has no access control** upstream: anyone who can reach the
port reads your ban lists. Turn on the NetworkPolicy (`networkPolicy.enabled`,
off by default), restrict the sources with `networkPolicy.web.from`, and expose
the Service with care.

## Metrics

`metrics.enabled` serves Prometheus metrics on 9090 (port `metrics`):
`mjolnir_status_api_request_pass` and `_fail`, `mjolnir_performance_http_request`
and Node's defaults. `metrics.service`, `metrics.serviceMonitor` and
`metrics.podMonitor` (the last two are exclusive) render a Service and Prometheus
Operator objects; the ServiceMonitor needs no other Service.

`metrics.prometheusRule.enabled` adds two alerts (list names in
`metrics.prometheusRule.disabled` to drop one):

- `MjolnirDown`: no target `up` for 5 minutes. It also fires when `replicaCount`
  is `0`.
- `MjolnirHomeserverUnreachable`: more than `apiFailureRatio` of the bot's
  requests failed for 10 minutes. Mjolnir counts only transport errors (DNS,
  refused, timeout) as failures: an HTTP 4xx or 5xx reply is a success, so a
  broken homeserver that answers is not caught.

The `/healthz` endpoint (the probes) stays 200 once the bot has started, even if the
homeserver is down: the alerts, not the probes, tell you.

## Storage

`/data` (the sync token, and the encryption device with `encryption.use`) takes
one of three types in `persistence.data.type`:

- `volumeClaimTemplate` (default): a PVC from the StatefulSet, `1Gi`. The
  StatefulSet keeps it when it is deleted or scaled down
  (`persistentVolumeClaimRetentionPolicy: Retain`): delete it by hand.
- `existingClaim`: a PVC of yours (`existingClaim.name`, optional `subPath`).
- `emptyDir`: lost with the pod, fine without encryption (see
  [Encryption](#encryption)).

Protected rooms and watched lists live in your Matrix account data, not on the
volume.

## Security

The pod follows the Pod Security `restricted` standard: user and group `65532`,
no capabilities, a read-only root filesystem (Mjolnir writes only to `/data`,
`fsGroup: 65532`), the `RuntimeDefault` seccomp profile and no service account
token. `hostUsers: false` runs it in a user namespace; nodes without support
(containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+), or volumes without idmapped
mounts (NFS, SMB), cannot start it: set `hostUsers: true`.

Mjolnir does not handle `SIGTERM` (Node as PID 1 ignores it), so a stop always
ends in `SIGKILL`: `terminationGracePeriodSeconds` (`5`) only delays it. Its
state is SQLite and a sync token, which a kill does not corrupt.

## Network

- The NetworkPolicy (`networkPolicy.enabled`, **off by default**: a CNI without
  support ignores it, and egress to an in-cluster homeserver needs a peer you
  write yourself) allows only the
  metrics port (with `metrics.enabled`) and the web port (with `config.web.enabled`).
  Restrict the sources with `networkPolicy.metrics.from` and `networkPolicy.web.from`;
  empty means any source. Kubelet probes are not affected.
- `networkPolicy.egress.enabled` (off by default) allows DNS, `peers.to` (the
  internet except private, CGNAT and link-local ranges) and `extraEgress`. A
  homeserver inside the cluster or on your LAN sits on a private range: add its
  pods or address to `peers.to` or `extraEgress`, or the bot cannot reach it.
  Allow `config.homeserverUrl`, `config.rawHomeserverUrl`, `config.MAS.url` and
  Sentry if you use them.

## Rollouts

If a rollout produces a pod that never becomes Ready (bad Secret, wrong homeserver),
a StatefulSet does not replace it when you fix the values or roll back: delete the
pod, and the StatefulSet recreates it from the current revision.

## Autoscaling and resources

There is no HPA and no PodDisruptionBudget (one replica).
`verticalPodAutoscaler` supports `Off`, `Initial`, `Recreate` and
`InPlaceOrRecreate`. Idle, Mjolnir takes about 210Mi. The default requests (`50m`
CPU, `256Mi` memory) are scheduling floors and the memory limit is `1Gi`: Node
sizes its heap at about half the limit, and `NsfwProtection` decodes every image
posted in a protected room. A burst of large images ran a `512Mi` limit out of heap
(the pod crash-looped while the backlog replayed); `1Gi` held, with a peak of about
600Mi. Measure with your rooms, then tune.

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
* <https://github.com/matrix-org/mjolnir>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| config | object | `{"homeserverUrl":"https://matrix.example.com","managementRoom":"#moderators:example.com"}` | Mjolnir settings (see `config/default.yaml` upstream), rendered into a ConfigMap as `production.yaml`. **Set `homeserverUrl` and `managementRoom` before the first install**: the defaults are placeholders, only there so the chart renders without values. `rawHomeserverUrl` (the URL of Synapse's admin API) defaults to `homeserverUrl`. Chart-owned keys (`dataPath`, `health.healthz`, `health.openMetrics`, `web.port`, `web.address`) are rejected. So are the credential keys listed at `existingSecret.key`: they go through `existingSecret`, never here. `web.enabled` turns the web API on (abuse reports, rule server, spam checker) and adds its Service port and NetworkPolicy rule. Settings are read at start: a change restarts the pod. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for the homeserver name). |
| existingSecret.key | string | `"config.yaml"` | Key of the Secret that holds a YAML fragment with the credentials, for example `accessToken: <token>`. Mounted as `local.yaml`, read after the chart's own settings (mode 0440). Upstream reads credentials from the config file only (no `*_file` option, no environment variable). Credential keys: `accessToken`, `encryption.password`, `pantalaimon.password`, `MAS.clientSecret`, `web.synapseHTTPAntispam.authorization`, `health.sentry.dsn`. |
| existingSecret.name | string | `""` | Name of the Secret holding the credentials of the bot. Empty: `<fullname>`. The pod cannot start until it exists. The chart never creates it. |
| existingSecret.revision | string | `""` | Opaque string added to the pod as the `checksum/secret` annotation: change it when you rotate the Secret to restart the pod (Mjolnir reads the file at start only). The chart cannot hash a Secret it does not own, so it is yours to set, for example from CI: `--set-string existingSecret.revision=$(kubectl get secret mjolnir -o json | sha256sum | cut -c1-12)`. Empty: no annotation. |
| extraArgs | list | `[]` | Extra arguments for Mjolnir, after the chart's own (none). `--mjolnir-config` is rejected: it makes Mjolnir ignore the config directories, and with them the Secret. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the mjolnir container. The config directories and the Node environment are chart-owned: such variables are rejected. Settings go through `config`. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the mjolnir container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+) and idmapped mounts on the volume's file system (not NFS/SMB); the pod fails to start otherwise. `true` uses host users. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/mjolnir"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe (`/healthz`). The endpoint answers 200 for the life of the process once started, even when the homeserver is down: a homeserver outage never restarts the pod. It fails when the event loop is stuck. |
| metrics.enabled | bool | `false` | Serve Prometheus metrics (`health.openMetrics`, port 9090, path `/metrics`). Needed by the metrics Service, the monitors and the rule. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor (no Service needed). Exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.prometheusRule.apiFailureRatio | float | `0.05` | `MjolnirHomeserverUnreachable` threshold: the share of the bot's requests to the homeserver that fail at the transport level (DNS, connection refused, timeout) over 5 minutes, for 10 minutes. HTTP error replies (4xx, 5xx) do not count: Mjolnir counts them as successes. |
| metrics.prometheusRule.disabled | list | `[]` | Alerts to leave out (at most one: disable `prometheusRule` instead). `MjolnirDown` also fires when no target exists (pod Pending) and with `replicaCount: 0`. |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alerts `MjolnirDown`, `MjolnirHomeserverUnreachable`). Needs `serviceMonitor` or `podMonitor`: the rules select the `job` label it sets. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.service.annotations | object | `{}` | Service annotations. |
| metrics.service.enabled | bool | `false` | Render the metrics Service (also rendered when `serviceMonitor.enabled`). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. Exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. Empty allows any destination. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, internet peers, `extraEgress`). A homeserver inside the cluster needs a peer in `extraEgress`: the default peers exclude the private ranges. |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s. |
| networkPolicy.egress.peers.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["fc00::/7","fe80::/10"]}}]` | Internet peers (any port): the homeserver, an OIDC provider, Sentry. Default: the internet, not the private, CGNAT and link-local ranges, so a compromised pod cannot move sideways. Remove an `except` entry to reach a server there. Empty allows any destination. |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy (ingress: the metrics port with `metrics.enabled`, the web API port with `config.web.enabled`; nothing else listens for other pods, kubelet probes are not filtered). Off by default: egress to an in-cluster homeserver needs a peer you write yourself, and a CNI without NetworkPolicy support ignores it. Turn it on when `config.web.enabled` is set: the rule server has no access control. |
| networkPolicy.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to scrape the metrics port (9090). Empty: any source. |
| networkPolicy.web.from | list | `[]` | NetworkPolicyPeer list allowed to reach the web API port (8081). Empty: any source (the homeserver and the clients that file abuse reports can be anywhere). |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. |
| persistence.data.emptyDir.sizeLimit | string | `""` | Size limit (`type: emptyDir`, everything is lost with the pod). Empty: none. |
| persistence.data.existingClaim.name | string | `""` | Name of an existing PVC (`type: existingClaim`). |
| persistence.data.existingClaim.subPath | string | `""` | Sub-path inside the claim. |
| persistence.data.type | string | `"volumeClaimTemplate"` | Where `/data` (sync token, and with `config.encryption.use` the crypto store and its device) lives. `volumeClaimTemplate` creates a PVC and keeps it on uninstall; the other types use the matching sub-section. `emptyDir` loses the state with the pod and is rejected with `config.encryption.use` (every restart would create a new device). |
| persistence.data.volumeClaimTemplate.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| persistence.data.volumeClaimTemplate.annotations | object | `{}` | PVC annotations. |
| persistence.data.volumeClaimTemplate.labels | object | `{}` | PVC labels. |
| persistence.data.volumeClaimTemplate.size | string | `"1Gi"` | Requested size. The template is immutable once installed: resize the PVC, see the README. |
| persistence.data.volumeClaimTemplate.storageClassName | string | `""` | StorageClass (empty: cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. `fsGroup` does not apply to NFS/SMB volumes. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe (`/healthz`). The bot serves no traffic of its own: this only reports the state. |
| replicaCount | int | `1` | Replicas: `1`, or `0` to pause the bot. Two bots on one account would act twice and share one crypto device, so more than one is rejected. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"256Mi"}}` | Resources of the mjolnir container. Idle, Mjolnir takes about 210Mi. Node derives its heap limit from the memory limit (about half of it), and `NsfwProtection` decodes every image posted in a protected room: a burst of large images ran a `512Mi` limit out of heap (crash loop), where `1Gi` held (peak about 600Mi). Measure, then tune; VPA in `Off` mode gives recommendations. No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ControllerRevisions to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context of the mjolnir container. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8081` | Service port (the container listens on 8081). |
| service.type | string | `"ClusterIP"` | Service type. The Service exists only with `config.web.enabled`. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":60,"periodSeconds":10,"timeoutSeconds":5}` | Startup probe (`/healthz`, which answers 418 until startup completes). 10 minutes: the bot syncs its lists and checks its permissions in every protected room before it is ready, and a failed startup exits the process. |
| terminationGracePeriodSeconds | int | `5` | Seconds the bot gets to stop. Mjolnir handles no signal and runs as PID 1, so SIGTERM is ignored and the kernel kills it when this expires: a long value only delays every restart. Nothing needs flushing (SQLite is crash-safe). |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

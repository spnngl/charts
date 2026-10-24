# mailpit

Mailpit, an email and SMTP testing tool with a web UI and an API, as a hardened single-replica Deployment

Runs [Mailpit](https://github.com/axllent/mailpit), an SMTP server that catches
every message and serves it through a web UI and an API. The image comes from
[spnngl/images](https://github.com/spnngl/images/tree/main/containers/mailpit):
`scratch`, uid 65532, no shell.

Mailpit runs as one replica: messages live in one SQLite database with a single
writer. The Deployment uses the `Recreate` strategy, so every upgrade or
reschedule is a short downtime.

## Install

```sh
helm install mailpit oci://ghcr.io/spnngl/charts/mailpit --version <version> -n mailpit --create-namespace
```

Applications send to `mailpit-smtp.<namespace>.svc:1025`; the web UI and the API
answer on `mailpit.<namespace>.svc:8025`. The defaults are open: anyone reaching
the HTTP port reads every message. Set `secrets.uiAuth` before exposing the UI
(see [Secrets](#secrets)).

## Storage

`/data` holds the database, on an `emptyDir` by default: messages last as long
as the pod, which suits a test inbox. `persistence.emptyDir.sizeLimit` caps it;
past the limit the kubelet evicts the pod.

`persistence.enabled: true` keeps messages on a PersistentVolumeClaim: the chart
PVC `<fullname>`, or `persistence.existingClaim`. The chart PVC carries
`helm.sh/resource-policy: keep`: it survives `helm uninstall`, and a reinstall
with the same release name adopts it. Delete it by hand to drop the messages.

The database uses SQLite WAL mode; on a network filesystem (NFS) set
`config.MP_DISABLE_WAL: true`. Upstream keeps the newest 500 messages
(`config.MP_MAX_MESSAGES`, `0` keeps all) and accepts messages up to 50 MB
(`config.MP_MAX_MESSAGE_SIZE`).

## Settings

`config` takes upstream environment variables (`MP_*` and `TZ`, see the
[runtime options](https://mailpit.axllent.org/docs/configuration/runtime-options/))
and sets them as container `env`: a change rolls the pod, a key left out keeps
the upstream default.

```yaml
config:
  MP_MAX_MESSAGES: 5000
  MP_ALLOWED_HOSTS: mail.example.com
  MP_SMTP_ALLOWED_RECIPIENTS: "@example\\.com$"
  TZ: Europe/Paris
```

The schema rejects three groups of variables:

- Chart-owned: listeners, metrics, file paths and `MP_DATABASE`. Set them
  through `secrets`, `metrics` and `persistence`.
- Inline secrets (`MP_*_AUTH`, `MP_SMTP_RELAY_PASSWORD`/`SECRET`,
  `MP_SMTP_FORWARD_PASSWORD`/`SECRET`): they would land in the Deployment and in
  the release history. Put them in the files of `secrets`.
- Deprecated aliases (`MP_DATA_FILE`, `MP_UI_SSL_*`, `MP_SMTP_SSL_*`): upstream
  reads them after the current names, so they would override the chart paths.

`extraEnv` (an `EnvVar` list) overrides `config` and follows the same rules.
Two more names belong to the chart there: `GOMEMLIMIT` (set from the memory
limit) and `MP_WEBROOT` (set it in `config`, where the chart reads it).
`extraArgs` are `mailpit` flags: they override every variable, chart-owned ones
included.

## Secrets

Credentials come only from existing Secrets, so they stay out of Helm values,
the release history and Git. Each `secrets.<x>.name` names a Secret in the
release namespace; the chart mounts it read-only (mode `0440`) under
`/etc/mailpit/` and points the upstream variable at the file. Mailpit reads the
files at startup: roll the pod after changing a Secret.

```sh
htpasswd -nbB admin '<password>' > htpasswd
kubectl -n mailpit create secret generic mailpit-ui --from-file=htpasswd
```

```yaml
secrets:
  uiAuth:
    name: mailpit-ui
```

The chart checks two upstream rules at render time:

- SMTP authentication needs TLS: set `secrets.smtpTls` next to
  `secrets.smtpAuth`, or `config.MP_SMTP_AUTH_ALLOW_INSECURE: true`.
- POP3 runs only with credentials: `secrets.pop3Tls` needs `secrets.pop3Auth`.

TLS Secrets come from cert-manager or `kubectl create secret tls`. The chart
owns the TLS variables, which rules out Mailpit's self-signed `sans:`
certificates.

Relaying (`config.MP_SMTP_RELAY_ALL`, `MP_SMTP_RELAY_MATCHING` or the web UI
release button) and forwarding read their host and credentials from the
`relayConfig` and `forwardConfig` files:

```yaml
# relay.yaml
host: smtp.example.com
port: 587
starttls: true
auth: plain
username: mailpit
password: <password>
```

## Access

```sh
kubectl -n mailpit port-forward service/mailpit 8025:8025
```

then <http://localhost:8025/>.

`ingress` and `httpRoute` (Gateway API) expose the UI and the API. Before
exposing them:

- Set `secrets.uiAuth`.
- Set `config.MP_ALLOWED_HOSTS` to the public host names: Mailpit then answers
  only those `Host` headers (DNS rebinding protection). The probes and
  `helm test` keep working.
- Raise the proxy read timeout so the UI websocket for live updates stays open
  (ingress-nginx: `nginx.ingress.kubernetes.io/proxy-read-timeout`, 60 s by
  default).
- With `secrets.uiTls` the Service speaks HTTPS: configure backend TLS
  (ingress-nginx: `nginx.ingress.kubernetes.io/backend-protocol: HTTPS`; Gateway
  API: a `BackendTLSPolicy`).

`config.MP_WEBROOT` (for example `mail`) serves the UI under `/mail/`; the
probes, the Ingress, the HTTPRoute and `helm test` follow it.

SMTP has its own Service, `<fullname>-smtp` (`service.smtp`), which also carries
POP3 (1110) when on. To catch mail from outside the cluster, make it a
`LoadBalancer` and narrow what it accepts: `config.MP_SMTP_ALLOWED_RECIPIENTS`,
`secrets.smtpAuth` or `networkPolicy.smtp.from`.

`helm test` runs `mailpit readyz` against the web UI Service.

## Metrics

`metrics.enabled` serves Prometheus metrics on port 9090 of the pod (`/metrics`,
without the UI authentication). `metrics.serviceMonitor` or `metrics.podMonitor`
(one of them) also turns it on and creates the Prometheus Operator object. The
ServiceMonitor scrapes a dedicated ClusterIP Service, `<fullname>-metrics`, so
the web UI Service carries HTTP only.

`metrics.prometheusRule` selects the `job` label the monitor sets, so it needs
one. It creates two alerts (`disabled` removes one):

- `MailpitDown`: the target has been down (crashing pod) or absent (no pod,
  `replicaCount: 0`) for `downFor` (`5m`). A running pod that is not ready
  still serves metrics, so it stays quiet.
- `MailpitSMTPRejected`: Mailpit rejected a message (unparsable, or a recipient
  outside `MP_SMTP_ALLOWED_RECIPIENTS`) within `rejectedWindow` (`15m`). Failed
  logins and oversized messages stay outside this counter.

## Image

The default image is `appVersion`, pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates both
together). Setting `image.tag` drops that digest; add `image.digest` to pin the
tag again (`image.digest` without `image.tag` is an error).

The image is signed with the spnngl/images key (the charts are signed keyless)
and carries a GitHub build provenance attestation:

```sh
cosign verify --insecure-ignore-tlog=true --new-bundle-format=false \
  --key https://raw.githubusercontent.com/spnngl/images/main/bootc/fedora/sysroot/common/usr/share/pki/containers/spnngl-images.pub \
  ghcr.io/spnngl/images/mailpit@<digest>
gh attestation verify oci://ghcr.io/spnngl/images/mailpit@<digest> -R spnngl/images
```

The signature skips the Rekor transparency log (`--insecure-ignore-tlog`) and
uses the legacy signature format (`--new-bundle-format=false`).

## Security

The defaults meet the `restricted` Pod Security Standard: uid/gid 65532,
read-only root filesystem, all capabilities dropped, no privilege escalation,
`RuntimeDefault` seccomp, no ServiceAccount token, no Service environment
variables. Mailpit writes only to `/data`, made writable by `fsGroup`.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in the
pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need user namespace support: containerd 2.0+ or CRI-O, runc 1.2+
or crun, Linux 6.3+. Elsewhere the pod sandbox fails to start: set
`hostUsers: true`.

## Network

The NetworkPolicy (on by default) opens each port to its own `from` list
(`networkPolicy.http`, `smtp`, `pop3`, `metrics`); an empty list allows any
source. Narrow `http.from` to your ingress controller or Gateway plus the
`helm test` pod, and `smtp.from` to the applications under test.

`networkPolicy.egress.enabled` restricts egress to DNS and `extraEgress`. Add
the targets Mailpit dials there: relay and forward servers, `MP_WEBHOOK_URL`,
link checks.

## Resources and autoscaling

Mailpit holds a message in memory while it receives and parses it: scale the
memory limit (`256Mi`) with `config.MP_MAX_MESSAGE_SIZE` and concurrent
deliveries. The requests (`10m` CPU, `32Mi` memory) are scheduling floors.
`GOMEMLIMIT` follows the memory limit; a memory resize restarts the container.

Scaling is vertical only: `verticalPodAutoscaler` supports `Off`, `Initial`,
`Recreate` and `InPlaceOrRecreate`.

## Compatibility

The values schema is strict: an unknown key fails the install. A breaking
values change bumps the chart major version; deprecations are announced one
minor version ahead.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| spnngl |  | <https://github.com/spnngl> |

## Source Code

* <https://github.com/spnngl/charts>
* <https://github.com/axllent/mailpit>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| config | object | `{}` | Mailpit settings as upstream environment variables (`MP_*` and `TZ`), set as container `env`. A key left out keeps the upstream default. Chart-owned variables, inline secrets and deprecated aliases are schema errors: see [Settings](#settings). |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for relay, forward and webhook hosts). |
| extraArgs | list | `[]` | Extra `mailpit` command-line flags (see `mailpit help`). A flag overrides every variable, chart-owned ones included: prefer `config`. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list), applied over `config`. Allowed names: see [Settings](#settings). |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the mailpit container. |
| extraVolumes | list | `[]` | Extra volumes (for example a ConfigMap for `config.MP_TAGS_CONFIG`). |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | `false` runs the pod in a user namespace, `true` with host users. Node requirements: see [User namespaces](#user-namespaces). |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute for the web UI and the API (path prefix `config.MP_WEBROOT`, default `/`). Read [Access](#access) first. |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/mailpit"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress for the web UI and the API (path `config.MP_WEBROOT`, default `/`). Read [Access](#access) first. |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels. |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Liveness probe (`GET <webroot>livez`: process alive only). |
| metrics.enabled | bool | `false` | Serve Prometheus metrics on port 9090 of the pod (`/metrics`, without authentication). `serviceMonitor` and `podMonitor` turn it on too. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor. Exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.prometheusRule.disabled | list | `[]` | Alerts to leave out, at most one (to drop both, disable `prometheusRule`). |
| metrics.prometheusRule.downFor | string | `"5m"` | How long the target may be down or absent before `MailpitDown` fires. |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alerts `MailpitDown`, `MailpitSMTPRejected`). Needs `serviceMonitor` or `podMonitor`: the rules select the `job` label it sets. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.prometheusRule.rejectedWindow | string | `"15m"` | Window in which a rejected message fires `MailpitSMTPRejected`. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor and the ClusterIP Service it scrapes (`<fullname>-metrics`). Exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress to DNS and `extraEgress`. |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s (relay and forward SMTP servers, webhook URL). |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: HTTP, SMTP, and POP3 and metrics when on). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the web UI and API port (your ingress controller or Gateway, the `helm test` pod). Empty: any source. |
| networkPolicy.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to reach the metrics port (your Prometheus). Empty: any source. |
| networkPolicy.pop3.from | list | `[]` | NetworkPolicyPeer list allowed to reach the POP3 port (`secrets.pop3Auth` set). Empty: any source. |
| networkPolicy.smtp.from | list | `[]` | NetworkPolicyPeer list allowed to reach the SMTP port (the applications under test). Empty: any source. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes of the chart PVC. |
| persistence.annotations | object | `{}` | Chart PVC annotations. |
| persistence.emptyDir.sizeLimit | string | `""` | Size limit of the emptyDir (`enabled: false`). Past it the kubelet evicts the pod, messages included. Empty: none. |
| persistence.enabled | bool | `false` | Keep messages on a PersistentVolumeClaim. `false`: `/data` is an emptyDir and messages last as long as the pod. |
| persistence.existingClaim | string | `""` | Existing PVC to use (`enabled: true`). Empty: the chart creates `<fullname>`, kept on uninstall (`helm.sh/resource-policy: keep`). |
| persistence.labels | object | `{}` | Chart PVC labels. |
| persistence.size | string | `"1Gi"` | Requested size of the chart PVC. |
| persistence.storageClassName | string | `""` | StorageClass of the chart PVC (empty: cluster default). |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. `fsGroup` makes the volume writable by the image user. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Readiness probe (`GET <webroot>readyz`). |
| replicaCount | int | `1` | Replicas: `1`, or `0` to stop Mailpit. One SQLite database has one writer, so one replica holds the whole inbox. |
| resources | object | `{"limits":{"memory":"256Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. Sizing: see [Resources and autoscaling](#resources-and-autoscaling). No CPU limit on purpose. With a memory limit, `GOMEMLIMIT` follows it. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| secrets.forwardConfig.key | string | `"forward.yaml"` | Key of the configuration file in the Secret. |
| secrets.forwardConfig.name | string | `""` | Existing Secret holding an SMTP forward configuration file (`MP_SMTP_FORWARD_CONFIG`, YAML with the forward host, credentials and recipients). Needs an egress rule when `networkPolicy.egress.enabled`. |
| secrets.pop3Auth.key | string | `"htpasswd"` | Key of the htpasswd file in the Secret. |
| secrets.pop3Auth.name | string | `""` | Existing Secret holding an htpasswd file for POP3 (`MP_POP3_AUTH_FILE`). Turns the POP3 server on (port 1110, on the SMTP Service). |
| secrets.pop3Tls.name | string | `""` | Existing `kubernetes.io/tls` Secret (`tls.crt`, `tls.key`) for POP3 over TLS (`MP_POP3_TLS_CERT`, `MP_POP3_TLS_KEY`). Needs `secrets.pop3Auth`. |
| secrets.relayConfig.key | string | `"relay.yaml"` | Key of the configuration file in the Secret. |
| secrets.relayConfig.name | string | `""` | Existing Secret holding an SMTP relay configuration file (`MP_SMTP_RELAY_CONFIG`, YAML with the relay host and credentials). Relaying also needs `config.MP_SMTP_RELAY_ALL` or `MP_SMTP_RELAY_MATCHING`, and an egress rule when `networkPolicy.egress.enabled`. |
| secrets.sendApiAuth.key | string | `"htpasswd"` | Key of the htpasswd file in the Secret. |
| secrets.sendApiAuth.name | string | `""` | Existing Secret holding an htpasswd file for the send API (`MP_SEND_API_AUTH_FILE`). Empty: the send API uses the web UI credentials. |
| secrets.smtpAuth.key | string | `"htpasswd"` | Key of the htpasswd file in the Secret. |
| secrets.smtpAuth.name | string | `""` | Existing Secret holding an htpasswd file for SMTP authentication (`MP_SMTP_AUTH_FILE`). Needs `secrets.smtpTls` or `config.MP_SMTP_AUTH_ALLOW_INSECURE: true`. Empty: SMTP accepts mail without authentication. |
| secrets.smtpTls.name | string | `""` | Existing `kubernetes.io/tls` Secret (`tls.crt`, `tls.key`) for SMTP STARTTLS (`MP_SMTP_TLS_CERT`, `MP_SMTP_TLS_KEY`). `config.MP_SMTP_REQUIRE_STARTTLS` or `MP_SMTP_REQUIRE_TLS` enforce it. |
| secrets.uiAuth.key | string | `"htpasswd"` | Key of the htpasswd file in the Secret. |
| secrets.uiAuth.name | string | `""` | Existing Secret holding an htpasswd file for the web UI and the API (`MP_UI_AUTH_FILE`). Empty: the UI and the API are open to anyone reaching the HTTP port. |
| secrets.uiTls.name | string | `""` | Existing `kubernetes.io/tls` Secret (`tls.crt`, `tls.key`) to serve the web UI and the API over HTTPS (`MP_UI_TLS_CERT`, `MP_UI_TLS_KEY`). The probes and the `helm test` pod switch to HTTPS; an Ingress or HTTPRoute then needs backend TLS (see [Access](#access)). |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| service.http.annotations | object | `{}` | Service annotations. |
| service.http.port | int | `8025` | Web UI and API port (the container listens on 8025). |
| service.http.type | string | `"ClusterIP"` | Type of the web UI and API Service (`<fullname>`). |
| service.smtp.annotations | object | `{}` | Service annotations. |
| service.smtp.pop3Port | int | `1110` | POP3 port (the container listens on 1110). |
| service.smtp.port | int | `1025` | SMTP port (the container listens on 1025). |
| service.smtp.type | string | `"ClusterIP"` | Type of the SMTP Service (`<fullname>-smtp`, also carries POP3 when `secrets.pop3Auth` is set). |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":2}` | Startup probe (`GET <webroot>readyz`: answers once the database is open and migrated). |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 10m, memory: 32Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

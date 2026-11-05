# ignition-converter

Admission webhook converting the Ignition 2.x user data of Cluster API bootstrap Secrets to spec 3.0 for Fedora CoreOS, running as a hardened, highly available Deployment

Runs [ignition-converter](https://github.com/spnngl/ignition-converter), a
mutating admission webhook for Cluster API management clusters. Cluster API's
kubeadm bootstrap provider renders Ignition spec 2.x, which Fedora CoreOS
rejects (it reads spec 3.x only). The webhook rewrites the user data of each
bootstrap Secret to spec 3.0 as Cluster API writes it, so machines boot without
a change to Cluster API.

## Install

Prerequisites: [cert-manager](https://cert-manager.io) (Cluster API already
requires it) for the default `tls.mode`, and the bootstrap provider's feature
gate `KubeadmBootstrapFormatIgnition=true`
(`EXP_KUBEADM_BOOTSTRAP_FORMAT_IGNITION=true` with `clusterctl`).

```sh
helm install ignition-converter oci://ghcr.io/spnngl/charts/ignition-converter --version <version> -n ignition-converter --create-namespace
```

The webhook only sees Secrets of type `cluster.x-k8s.io/secret` labelled
`cluster.x-k8s.io/cluster-name` with a `format` key, and changes those whose
`format` is `ignition`. Narrow it further with `webhook.namespaceSelector`.

## Failure policy

`failurePolicy` is `Fail`: while no replica answers, the API server rejects
every matched Secret, and Cluster API retries. A Secret stored unconverted
would fail later, at machine boot, far from the cause. Keep the webhook
available (3 replicas by default, see
[Availability and scheduling](#availability-and-scheduling)), and remember
that Secrets outside `webhook.namespaceSelector` are stored unconverted.

## TLS

The API server calls webhooks over HTTPS only, and checks the certificate
against the webhook's `caBundle`. The webhook reads its key pair at every TLS
handshake: a renewed certificate needs no restart.

- `tls.mode: certManager` (default): the chart creates a self-signed issuer, a
  ten-year private CA (`<fullname>-ca`) and a serving certificate it signs
  (`<fullname>-tls`). cert-manager's cainjector writes the CA, not the serving
  certificate, into `caBundle`, so serving certificate renewals leave
  `caBundle` alone. When the CA itself renews, `caBundle` changes at once:
  renew the serving certificate right after
  (`cmctl renew -n <namespace> <fullname>`).
- `tls.mode: existingSecret`: `tls.existingSecret.name` is a
  `kubernetes.io/tls` Secret you manage in the release namespace, valid for
  `<fullname>.<namespace>.svc`, and `tls.existingSecret.caBundle` the base64
  PEM of the CA that signed it.

cert-manager keeps the Secrets of deleted certificates: `helm uninstall`
leaves `<fullname>-ca` and `<fullname>-tls` behind. Delete them by hand, or
let a reinstall reuse them.

## Image

The default image is `appVersion` pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates both
together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (`image.digest` without `image.tag` is an error).

The image is built and signed by [spnngl/images](https://github.com/spnngl/images)
(cosign key signature and GitHub build attestation).

## Availability and scheduling

- 3 replicas, `RollingUpdate` with `maxUnavailable: 0`, `maxSurge: 1`. On
  SIGTERM a `preStop` sleep of 5 s lets the endpoint removal propagate, then
  the webhook finishes in-flight reviews within its 10 s shutdown timeout. On
  kind, 914 Secret writes during a rollout restart all succeeded.
- Default spread: preferred pod anti-affinity on the hostname, preferred
  topology spread over zones. `affinity` / `topologySpreadConstraints`
  replace these defaults.
- `podDisruptionBudget.enabled` is off by default; turn it on for node drains
  that should keep the webhook up.
- Readiness and liveness probes call `/healthz` over HTTPS.

## Resources

Requests `10m` CPU / `32Mi` memory, a `128Mi` memory limit and no CPU limit.
Measured on kind: about 4 MiB working set per pod. `GOMEMLIMIT` follows the
memory limit; to set it yourself, set `resources.limits.memory` to `null`.

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid
65532, read-only root filesystem, all capabilities dropped, no privilege
escalation, `RuntimeDefault` seccomp, no ServiceAccount token, no Service
environment variables. The webhook calls no Kubernetes API, so its
ServiceAccount has no RBAC.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support
(containerd 2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+
(idmapped mounts on tmpfs for Secret volumes). On other nodes the pod sandbox
cannot be created: set `hostUsers: true`.

## Network

- The NetworkPolicy (`networkPolicy.enabled`, on by default) allows the
  webhook port (8443) from `networkPolicy.ingress.from`, and denies all
  egress: the webhook dials nothing. With `ingress.from: []` (default) any
  source is allowed, because the API server, often on the host network,
  cannot be selected by a `podSelector`.
- The webhook exposes no Prometheus metrics, so there is no ServiceMonitor.

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
* <https://github.com/spnngl/ignition-converter>
* <https://github.com/spnngl/images/tree/main/containers/ignition-converter>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. Empty: preferred podAntiAffinity on hostname. A non-empty value replaces that default wholesale. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list), for the Go runtime (`GODEBUG`, `GOMAXPROCS`): the webhook reads no variable itself. With `resources.limits.memory` set, `GOMEMLIMIT` is the chart's and rejected here. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the webhook container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: container uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/ignition-converter"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: `appVersion` pinned by the digest recorded in `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/healthz","port":"https","scheme":"HTTPS"},"periodSeconds":10}` | Liveness probe: `GET /healthz` over HTTPS. The webhook depends on nothing, so a failure means the process itself is stuck. |
| minReadySeconds | int | `5` | Seconds a new pod must be Ready before an old one is retired. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy: ingress on 8443 only, no egress at all (the webhook dials nothing, not even DNS). |
| networkPolicy.ingress.from | list | `[]` | NetworkPolicyPeer list allowed to reach 8443. Empty: any source, because the API server is not a pod a `podSelector` can select; narrow it to the control plane node addresses (`ipBlock`). |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget (`unhealthyPodEvictionPolicy: AlwaysAllow`). |
| podDisruptionBudget.maxUnavailable | int | `1` | Pods that may be evicted at once. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":2,"httpGet":{"path":"/healthz","port":"https","scheme":"HTTPS"},"periodSeconds":5}` | Readiness probe: `GET /healthz` over HTTPS. |
| replicaCount | int | `3` | Number of replicas. The webhook fails closed: with no replica ready, Cluster API cannot write any bootstrap Secret. |
| resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. A scheduling floor and a memory ceiling, not a sizing: measure, then tune. No CPU limit: throttling delays reviews the API server waits on. `limits.memory` also sets `GOMEMLIMIT`. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. The webhook never calls the Kubernetes API: no token is mounted, no RBAC is bound. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| strategy.rollingUpdate.maxSurge | int | `1` | Extra pods during a rollout. |
| strategy.rollingUpdate.maxUnavailable | int | `0` | Pods that may be unavailable during a rollout. |
| strategy.type | string | `"RollingUpdate"` | Deployment strategy type. `Recreate` leaves no replica during a rollout, so bootstrap Secret writes fail meanwhile. |
| tls.existingSecret.caBundle | string | `""` | Base64 of the PEM CA certificate that signed the Secret's certificate: the webhook's `caBundle`. Required with `tls.mode: existingSecret`, empty otherwise. |
| tls.existingSecret.name | string | `""` | Name of a `kubernetes.io/tls` Secret (keys `tls.crt`, `tls.key`) in the release namespace, valid for `<fullname>.<namespace>.svc`. Required with `tls.mode: existingSecret`, empty otherwise. Read at every TLS handshake: a renewed key pair needs no restart. |
| tls.mode | string | `"certManager"` | Source of the serving certificate. `certManager`: the chart creates a private CA and the serving certificate it signs (needs cert-manager, which Cluster API already requires); cainjector writes the CA into the webhook's `caBundle`. `existingSecret`: a `kubernetes.io/tls` Secret you manage, plus its CA in `existingSecret.caBundle`. The API server calls webhooks over HTTPS only, so TLS cannot be turned off. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty: spread over `topology.kubernetes.io/zone` (`ScheduleAnyway`). A non-empty value replaces that default. |
| webhook.namespaceSelector | object | `{}` | Namespace selector of the webhook (a `LabelSelector`). Empty: every namespace. Narrow it to the namespaces holding Cluster API clusters; Secrets outside it are stored unconverted. |

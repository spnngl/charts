# sable-next

Sable, a Matrix web client, as a hardened stateless Deployment serving its static app

Runs [Sable](https://github.com/SableClient/sable-next) (a Matrix web client, a
single-page app) as a stateless, highly available Deployment: three replicas of
[static-web-server](https://static-web-server.net/) serving the built app. The
image is built from [spnngl/images](https://github.com/spnngl/images): `scratch`,
non-root, no shell, nothing written at runtime.

The chart ships no Matrix homeserver: Sable is a client, the browser talks to the
homeserver directly. To run a homeserver too, see the `tuwunel` chart.

## Install

```sh
helm install sable oci://ghcr.io/spnngl/charts/sable-next --version <version> -n sable --create-namespace
```

With no values, the app starts with the `config.json` of the image: upstream's
homeserver list (matrix.org and five others, custom homeservers allowed) and
upstream's push, GIF and supporter-award services. Set [`config`](#configuration)
to choose your own.

## Configuration

`config` is the content of Sable's `config.json` (see `static/config.json`
upstream). The browser fetches it at startup. Empty (default), the image's own
file serves. Set, the chart renders it into a ConfigMap and mounts it as
`/app/config.json` (a `subPath` mount, read-only), which **replaces the image's
file whole**: a key you leave out gets the app's built-in default, not the image's
value (the built-in homeserver list, no push gateway, no GIF provider, no embeds,
no supporter awards, no calls). A change rolls the pods (`checksum/config`).

```yaml
config:
  homeserverList:
    - example.org
  defaultHomeserver: 0
  allowCustomHomeservers: false
```

Every value is public: the browser downloads the file, so do not put a secret in
it. A GIF provider API key is readable by every visitor.

The image's file also points at services run by the Sable project (push gateway,
GIF proxy, supporter awards). Browsers contact them while the file lists them:
replace `config` entirely to avoid that.

## Access

Open the app on `/`:

```sh
kubectl -n sable port-forward service/sable-sable-next 8080:8080
```

then <http://localhost:8080/>. `ingress` (Ingress) and `httpRoute` (Gateway API
HTTPRoute) expose it publicly; both need explicit hosts (and `parentRefs` for the
route).

- **HTTPS is mandatory.** The app needs a secure context (service worker,
  WebCrypto for end-to-end encryption): browsers only provide one on HTTPS (and
  `localhost`). The image serves plain HTTP: terminate TLS in front.
- **Single-page app.** Unknown paths answer `index.html` with status 200, so the
  client router handles them.
- **Homeserver.** Use another host name than the homeserver's, unless you route
  paths yourself: both serve `/`.

## Image

The default image is `appVersion`, pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates tag and
digest together). Setting `image.tag` drops that digest; add `image.digest` to
pin the tag again (a digest without a tag is an error).

The image is signed with cosign (keyless, GitHub Actions OIDC). Verify a digest with:

```sh
cosign verify \
  --certificate-identity-regexp 'https://github.com/spnngl/images/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/spnngl/images/sable-next@sha256:<digest>
```

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 65532,
read-only root filesystem, all capabilities dropped, no privilege escalation,
`RuntimeDefault` seccomp, no ServiceAccount token, no Service environment
variables. The server only reads files, so no writable volume is mounted.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support
(containerd 2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+. On other
nodes the pod sandbox cannot be created: set `hostUsers: true`.

## Availability

Three replicas, spread over nodes (preferred pod anti-affinity) and zones
(`topologySpreadConstraints`, `ScheduleAnyway`): a pod that cannot be spread
still schedules. A rolling update surges one pod and never drops below
`replicaCount` (`maxUnavailable: 0`, `minReadySeconds`). On shutdown, the pod
waits 5 seconds (`preStop`) for the endpoints to drop it before the server stops
accepting connections; `terminationGracePeriodSeconds` covers that wait and the
drain.

`podDisruptionBudget.enabled` creates a PodDisruptionBudget (`maxUnavailable`,
`unhealthyPodEvictionPolicy: AlwaysAllow`); it is off by default so a node drain
never blocks on a single-node cluster. Setting `affinity` merges over the default
anti-affinity (set `podAntiAffinity` to replace it); a
`topologySpreadConstraints` list replaces the default and needs its own
`labelSelector`.

## Network

The NetworkPolicy (`networkPolicy.enabled`, on by default) allows the HTTP port
(8080). Restrict the sources with `networkPolicy.http.from` (your ingress
controller or Gateway); empty means any source. `networkPolicy.egress.enabled`
(off by default) blocks all egress except `extraEgress`: the server makes no
outbound connection, so it needs no rule, not even DNS.

## Autoscaling and resources

There is no HPA: the server uses a few MiB and the replica count is an
availability setting. `verticalPodAutoscaler` supports `Off`, `Initial`,
`Recreate` and `InPlaceOrRecreate` (in-place resize needs Kubernetes 1.33+). A
recommender started with another `--recommender-name` than `default` ignores the
VPA unless `verticalPodAutoscaler.recommender` names it. The default requests
(`10m` CPU, `16Mi` memory) are scheduling floors, not a sizing.

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
* <https://github.com/SableClient/sable-next>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity, merged over the chart default: a preferred pod anti-affinity that spreads the replicas over nodes (set `podAntiAffinity` to replace it). |
| config | object | `{}` | Sable `config.json` (see `static/config.json` upstream): `homeserverList`, `defaultHomeserver`, `allowCustomHomeservers`, `featuredCommunities`, `pushNotificationDetails`, `embeds`, `supporterAwards`, `gifs`, `calls`, `disableAccountSwitcher`, `settingsDefaults`, `hideUsernamePasswordFields`. Empty: the image's own file serves. Set: the chart mounts this map as `/app/config.json`, which replaces the image's file whole, so list every key you need: a key left out gets the app's built-in default (the six built-in homeservers with custom ones allowed; no push gateway, GIF provider, embeds, supporter awards or calls), not the image's value. The browser reads the file: every value, API keys included, is public. A change rolls the pods. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list): static-web-server's `SERVER_*` settings. Names the chart, its Service, probes and mount rely on (`SERVER_PORT`, `SERVER_ROOT`, `SERVER_HEALTH`), and the image's response-header file (`SERVER_CONFIG_FILE`), are rejected. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Sable container (not on `/app/config.json`: use `config`). |
| extraVolumes | list | `[]` | Extra volumes (the name `config` is the chart's). |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute (path prefix `/`). Sable needs HTTPS (service worker, WebCrypto): terminate TLS on the Gateway. |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/sable-next"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress (path `/`). Sable needs HTTPS (service worker, WebCrypto): terminate TLS here or in front. |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Liveness probe (`GET /health`). |
| minReadySeconds | int | `10` | Seconds a new pod must be ready before it counts as available (rolling updates never drop below `replicaCount`). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress to `extraEgress` (none by default: the server makes no outbound call, so no DNS rule either). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: the HTTP port). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the HTTP port (your ingress controller or Gateway). Empty: any source. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget | object | `{"enabled":false,"maxUnavailable":1}` | PodDisruptionBudget (`unhealthyPodEvictionPolicy: AlwaysAllow`). `maxUnavailable` is a number or a percentage. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Readiness probe (`GET /health`). |
| replicaCount | int | `3` | Replicas. Sable is stateless: three keep serving through a node loss during a rolling update. `0` stops the app. |
| resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}` | Resources. A scheduling floor, not a sizing: the server serves files from disk (VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8080` | Service port (the container listens on 8080). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":2,"timeoutSeconds":2}` | Startup probe (`GET /health`). |
| terminationGracePeriodSeconds | int | `30` | Seconds the pod gets to stop. It covers the 5 seconds the chart waits (`preStop`) for the endpoints to drop the pod before the server stops accepting connections, then the drain. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty: the chart spreads the replicas over zones (`topology.kubernetes.io/zone`, `ScheduleAnyway`). A list you set replaces it and needs its own `labelSelector`. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 32Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

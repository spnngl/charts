# cinny

Cinny, a Matrix web client, as a hardened stateless Deployment serving its static app

Runs [Cinny](https://github.com/cinnyapp/cinny), a Matrix web client, as a
stateless Deployment of two replicas. The image is built from
[spnngl/images](https://github.com/spnngl/images): `scratch`,
[static-web-server](https://static-web-server.net/), non-root, no shell.

Cinny runs in the browser: the pods only serve its static files. The browser
talks to the homeservers directly, so they must be reachable from your users,
not from the cluster.

## Install

```sh
helm install cinny oci://ghcr.io/spnngl/charts/cinny --version <version> -n cinny --create-namespace
```

## Settings

`config` is Cinny's `config.json`, rendered into a ConfigMap and mounted over
the image's file; a change rolls the pods (`checksum/config`). It is served to
every browser: keep secrets out. Keys Cinny reads:

| Key | Meaning |
|-----|---------|
| `homeserverList` | Homeservers offered at login (server names or `https://` URLs) |
| `defaultHomeserver` | Index of the preselected one in `homeserverList` |
| `allowCustomHomeservers` | Let users type another homeserver |
| `featuredCommunities` | `openAsDefault`, `spaces`, `rooms`, `servers` shown in Explore |
| `hashRouter` | `enabled`, `basename`: route with `#/` URLs |

For example, a client locked to your homeserver:

```yaml
config:
  allowCustomHomeservers: false
  homeserverList:
    - example.com
```

Maps merge with the chart defaults, lists replace them; set a key to `null` to
drop it. Cinny looks each entry up at
`https://<name>/.well-known/matrix/client` (CORS headers needed:
`Access-Control-Allow-Origin: *`) to find the homeserver URL; when that file is
missing or unreachable, it uses `https://<name>` itself.

`gracePeriodSeconds` (default `5`) is how long a pod keeps serving after
`SIGTERM`, while Services and proxies stop routing to it; it then drains open
requests.

Other static-web-server settings (`SERVER_*` variables) go in
`extraEnv`; the names the chart sets or relies on are rejected (see the value).

The server sends no security headers, on purpose: Cinny frames its bundled
Element Call from its own origin, which `X-Frame-Options: DENY` would block.
Set the headers you want at your ingress or gateway (for clickjacking,
`Content-Security-Policy: frame-ancestors 'self'` instead of `X-Frame-Options`).

## Access

```sh
kubectl -n cinny port-forward service/cinny 8080:8080
```

then <http://localhost:8080/>. `ingress` (Ingress) and `httpRoute` (Gateway API
HTTPRoute) expose it publicly; both need explicit hosts (and `parentRefs` for the
route). Cinny is built for the root path: serve it on its own host, not under
a prefix. Every unknown path answers `index.html`, so deep links work.

The image serves plain HTTP: terminate TLS in front.

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
  ghcr.io/spnngl/images/cinny@sha256:<digest>
```

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 65532,
read-only root filesystem, all capabilities dropped, no privilege escalation,
`RuntimeDefault` seccomp, no ServiceAccount token, no Service environment
variables. The server writes nothing to disk.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support
(containerd 2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+. On other
nodes the pod sandbox cannot be created: set `hostUsers: true`.

## Network

The NetworkPolicy (`networkPolicy.enabled`, on by default) allows the HTTP port
(8080). Restrict the sources with `networkPolicy.http.from` (your ingress
controller or Gateway, and Prometheus with metrics); empty means any source.
`networkPolicy.egress.enabled` (off by default) allows only `extraEgress`: the
server opens no connection and resolves no name, so an empty list denies all
egress safely.

## Metrics

`metrics.enabled` serves Prometheus metrics (`sws_http_requests_total`,
`sws_http_request_duration_seconds`, ...) on `/metrics`, on the app port and
without authentication: an Ingress or HTTPRoute publishes them too, so block the
path in your proxy. `metrics.serviceMonitor` or `metrics.podMonitor` (one of
them) creates the Prometheus Operator scrape object.

## Autoscaling and resources

Two replicas, spread over nodes (preferred pod anti-affinity) and zones
(`ScheduleAnyway`), rolled one at a time without dropping below the replica
count. `podDisruptionBudget` (off by default) keeps node drains from evicting
both at once.

`autoscaling` (off by default) creates a HorizontalPodAutoscaler on CPU; the
target is a percentage of `resources.requests.cpu`, so size requests first.
`verticalPodAutoscaler` (off by default) supports `Off`, `Initial`, `Recreate`
and `InPlaceOrRecreate` (in-place resize needs Kubernetes 1.33+); it must not act
on a resource the HPA scales. A recommender started with another
`--recommender-name` than `default` ignores the VPA unless
`verticalPodAutoscaler.recommender` names it. The default requests (`10m` CPU,
`16Mi` memory) are scheduling floors, not a sizing: measure then tune.

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
* <https://github.com/cinnyapp/cinny>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity, merged over the chart default: a preferred pod anti-affinity that spreads the replicas over nodes (set `podAntiAffinity` to replace it). |
| autoscaling.behavior | object | `{"scaleDown":{"stabilizationWindowSeconds":300}}` | HPA behavior. Slow scale-down: traffic of a web client comes in bursts (page loads). |
| autoscaling.enabled | bool | `false` | Create a HorizontalPodAutoscaler. Enabling it drops `replicas` from the Deployment: it falls to 1 until the HPA reacts. |
| autoscaling.maxReplicas | int | `10` | HPA maximum replicas. |
| autoscaling.metrics | list | `[{"resource":{"name":"cpu","target":{"averageUtilization":75,"type":"Utilization"}},"type":"Resource"}]` | Raw `autoscaling/v2` MetricSpec list. CPU `Utilization` is a percentage of `resources.requests.cpu`: with the 10m floor, 75% fires at ~8m, so size requests first. |
| autoscaling.minReplicas | int | `2` | HPA minimum replicas. |
| config | object | `{"allowCustomHomeservers":true,"defaultHomeserver":0,"homeserverList":["matrix.org"]}` | Cinny `config.json`, served to the browser as is (keep secrets out). Keys read by Cinny: `defaultHomeserver` (index in `homeserverList`), `homeserverList`, `allowCustomHomeservers`, `featuredCommunities` (`openAsDefault`, `spaces`, `rooms`, `servers`), `hashRouter` (`enabled`, `basename`). `homeserverList` entries are server names or `https://` URLs: Cinny reads `/.well-known/matrix/client` there (CORS needed) for the homeserver URL, and uses `https://<name>` (or the URL) itself when that file is missing or unreachable. Maps merge with these defaults, lists replace them; set a key to `null` to drop it. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list), for the other static-web-server `SERVER_*` settings. Rejected names: those the chart sets (use `gracePeriodSeconds` and `metrics.enabled`); the port, listening socket, health endpoint, root and fallback page, which the probes, Service, NetworkPolicy and `config.json` mount rely on; security headers and HTTP/2 (which turns them on and needs TLS files), whose `X-Frame-Options: DENY` breaks the Element Call Cinny frames from its own origin. `SERVER_HOST` must not be a loopback address: probes and Service reach the pod IP. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| gracePeriodSeconds | int | `5` | Seconds the server keeps serving after SIGTERM (`SERVER_GRACE_PERIOD`), while Services and proxies stop sending it traffic; then it drains open requests. `terminationGracePeriodSeconds` is this plus 10. |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute (path prefix `/`: Cinny cannot be served under a prefix). |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/cinny"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress (path `/`: Cinny is built for the root path, it cannot be served under a prefix). |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Liveness probe (`GET /health`; the handler is fixed, set timings only). |
| metrics.enabled | bool | `false` | Serve Prometheus metrics on `/metrics` (`SERVER_METRICS`). Same port as the app and unauthenticated: an Ingress or HTTPRoute publishes them too, unless your proxy blocks the path. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor. Needs `metrics.enabled`; exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor (scrapes the app Service). Needs `metrics.enabled`; exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| minReadySeconds | int | `10` | Seconds a new pod must be ready before it counts as available, so a rolling update replaces the next pod only once the new one is serving. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress to `extraEgress`. The server opens no connection and resolves no name, so an empty list (deny all) is enough. |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: the HTTP port). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the HTTP port (your ingress controller or Gateway, and Prometheus with `metrics.enabled`). Empty: any source. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget (`unhealthyPodEvictionPolicy: AlwaysAllow`). |
| podDisruptionBudget.maxUnavailable | int | `1` | Pods that may be unavailable at once (a number or a percentage). |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Readiness probe (`GET /health`; the handler is fixed, set timings only). |
| replicaCount | int | `2` | Replicas (ignored with `autoscaling.enabled`). Cinny is stateless: two keep a rolling update gap-free (`podDisruptionBudget` does the same for node drains). `0` stops the app. |
| resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}` | Resources. A scheduling floor, not a sizing (VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8080` | Service port (the container listens on 8080). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":2,"timeoutSeconds":2}` | Startup probe (`GET /health`; the handler is fixed, set timings only). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty: the chart spreads the replicas over zones (`topology.kubernetes.io/zone`, `ScheduleAnyway`). A list you set replaces it and needs its own `labelSelector`. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 10m, memory: 16Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. Not combinable with an HPA acting on the same resource. |

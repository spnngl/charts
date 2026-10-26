# fluffychat

FluffyChat, a Matrix web client, as a hardened Deployment serving static files

Runs [FluffyChat](https://github.com/krille-chan/fluffychat) (a Matrix web client)
as a Deployment of static files served by
[static-web-server](https://static-web-server.net/). The image is built from
[spnngl/images](https://github.com/spnngl/images): `scratch`, non-root, no shell.
The upstream image is amd64-only and unsigned.

The app is stateless and needs no backend: the browser talks to the Matrix
homeserver directly. The chart ships no homeserver.

## Install

```sh
helm install fluffychat oci://ghcr.io/spnngl/charts/fluffychat --version <version> \
  -n fluffychat --create-namespace --set config.defaultHomeserver=matrix.example.com
```

`config.defaultHomeserver` is required: the homeserver pre-filled on the login page.

## Settings

Two files, both rendered into one ConfigMap (a change rolls the pods,
`checksum/config`):

- `config` is `config.json`, which the browser fetches next to the page. Keys are
  the names of the `AppSettings` enum of the app (`lib/config/setting_keys.dart`,
  not the stale sample file). They set **defaults only**: a setting a user changed
  in the browser wins, and a value of the wrong type is ignored silently. The
  schema types the known keys and lets other keys through, for settings added
  upstream later. The file is public: no secrets. `presetHomeserver` locks the
  homeserver on the login page.
- `server` is `sws.toml`, the static-web-server configuration file
  ([options](https://static-web-server.net/configuration/config-file/)):
  `server.general` is the `[general]` table, `server.advanced` the `[advanced]`
  one (`headers`, `redirects`, `rewrites`, `virtual-hosts`, typed by the schema;
  `memory-cache` needs a build the image does not have). Header values are
  strings: quote `yes`, `true` and numbers, or the server rejects the file and
  the pod crash-loops (a failed upgrade keeps the old pods serving). The file beats the
  `SERVER_*` variables of the image and the command line. `health`, `host`,
  `metrics`, `port` and `root` belong to the chart and are rejected. Three keys are
  set by default: `compression-level`, `security-headers` and `grace-period`.
  `compression-level` is `fastest` on purpose: the server compresses the files
  without a precompressed copy (the 7.5 MB source map) on the fly, and at its own
  `default` level one brotli request for that file exceeds the memory limit and
  kills the container.

`extraEnv` rejects `SERVER_*` names (the file wins over them anyway) and
`extraArgs` rejects the flags the chart owns. A flag whose option is also set in
`sws.toml` loses to the file. `extraVolumeMounts` rejects `/sws.toml` and
`/config.toml`, the paths the server reads as its configuration; `/app` is the
published site root, so files mounted there are served to everyone.

## Access

```sh
kubectl -n fluffychat port-forward service/fluffychat 8080:8080
```

then <http://localhost:8080/>. `ingress` (Ingress) and `httpRoute` (Gateway API
HTTPRoute) expose it publicly; both need explicit hosts (and `parentRefs` for the
route).

- **Host root only.** Sub-paths break asset loading: give the app its own host.
- **HTTPS is mandatory.** The app encrypts in the browser with WebCrypto, which
  browsers only offer on HTTPS (and `localhost`). The image serves plain HTTP:
  terminate TLS in front.
- **CORS on the homeserver.** The browser calls the homeserver from the app's
  origin: the homeserver must allow it.
- **Security headers.** `server.general.security-headers` sends
  `X-Frame-Options: DENY` and `frame-ancestors 'self'`, which blocks embedding the
  client in another origin, plus HSTS with `preload` (a browser that saw it keeps
  HTTPS-only for two years, subdomains included). Turn it off when another layer
  sets them or to embed.
- **Caching.** The app files keep their names across releases, and the image
  sends no `Cache-Control`: a browser could then reuse a stale `index.html`,
  service worker or `config.json` after an upgrade. The chart sends
  `Cache-Control: no-cache` on every file by default (`server.advanced.headers`):
  the browser revalidates and gets a `304` when unchanged. To cache the heavy
  files, replace the list with `no-cache` on `/**` and a longer `max-age` on
  `/canvaskit/**` and `/assets/**` (later entries win).

## Metrics

`metrics.enabled` serves Prometheus metrics (`GET /metrics`) **on the app port,
without authentication**. Any Ingress or HTTPRoute that forwards `/` publishes
them, and a NetworkPolicy cannot close that: the port is shared. Close it in the
proxy in front (a rule that denies `/metrics`), or leave `metrics.enabled` off
when the app is public. `metrics.serviceMonitor` or `metrics.podMonitor` (not
both) create the scrape resource; `metrics.prometheusRule` adds two alerts:

- `FluffyChatDown`: the target is down or absent for `downFor`.
- `FluffyChatServerErrors`: the share of 5xx responses over
  `serverErrorsWindow` exceeds `serverErrorsRatio`, at more than
  `serverErrorsMinRate` requests per second (one 5xx among a handful of requests
  stays silent).

The alerts select the `job` label set by the monitor (the Service name for a
ServiceMonitor, `<namespace>/<name>` for a PodMonitor): a relabeling that
changes `job` or `namespace` silences them. They need the Prometheus Operator
CRDs.

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
  ghcr.io/spnngl/images/fluffychat@sha256:<digest>
```

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 65532,
read-only root filesystem, all capabilities dropped, no privilege escalation,
`RuntimeDefault` seccomp, no ServiceAccount token, no Service environment
variables. The app writes nothing to disk.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in
the pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support
(containerd 2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+. On other
nodes the pod sandbox cannot be created: set `hostUsers: true`.

## Network

The NetworkPolicy (`networkPolicy.enabled`, on by default) allows the HTTP port
(8080) and no egress: the pod serves files and calls nothing. Restrict the
sources with `networkPolicy.http.from` (your ingress controller or Gateway);
empty means any source. With `metrics.enabled` and a non-empty `http.from`, name
your Prometheus in `networkPolicy.metrics.from`: the port is shared, so the
rule opens the whole app to those peers, not `/metrics` alone.

## Availability

Three replicas, spread over nodes and zones, `maxUnavailable: 0` during a rolling
update, `minReadySeconds` after readiness. On `SIGTERM` the server keeps serving
for `server.general.grace-period` seconds, which covers the delay before the
endpoint removal reaches the proxies in front; `terminationGracePeriodSeconds`
must exceed it (the chart refuses the install otherwise). `podDisruptionBudget`
is opt-in.

## Autoscaling and resources

There is no HPA. `verticalPodAutoscaler` supports `Off`, `Initial`, `Recreate`
and `InPlaceOrRecreate` (in-place resize needs Kubernetes 1.33+). A recommender
started with another `--recommender-name` than `default` ignores the VPA unless
`verticalPodAutoscaler.recommender` names it. The default requests (`10m` CPU,
`16Mi` memory) are scheduling floors, not a sizing: measure then tune.

## Compatibility

The values schema is strict: unknown keys fail the install (`config` is the
exception: unknown keys pass). A breaking change to values bumps the chart MAJOR
version; deprecations are announced one MINOR version ahead. Requires
Kubernetes 1.33 or later.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| spnngl |  | <https://github.com/spnngl> |

## Source Code

* <https://github.com/spnngl/charts>
* <https://github.com/krille-chan/fluffychat>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity, merged over the chart default: a preferred pod anti-affinity that spreads the replicas over nodes (set `podAntiAffinity` to replace it). |
| config | object | `{"defaultHomeserver":"example.com"}` | Contents of `config.json`, which the browser fetches next to the page. Keys are the names of the `AppSettings` enum in `lib/config/setting_keys.dart` (not the sample file, which is stale). They set defaults only: a setting a user changed in the browser wins, and a value of the wrong type is ignored silently, so the schema types the known keys and lets others through (`additionalProperties`). `defaultHomeserver` is required: the homeserver pre-filled on the login page (`presetHomeserver` also locks it). The file is public: no secrets. The state keys the app writes itself (`autoSendErrorReports`, `knownErrorHashes`, `lastUpdateCheckDate`, `noEncryptionWarningShown`, `unifiedPushEndpoint`, `unifiedPushRegistered`) are rejected. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options. |
| extraArgs | list | `[]` | Extra `static-web-server` command-line flags. Flags the chart owns (`-a`, `-p`, `-d`, `-q`, `-w`, `--host`, `--port`, `--root`, `--health`, `--metrics`, `--config-file`) are rejected. A flag whose option is also set in `sws.toml` loses to the file. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list). `SERVER_*` names are rejected: they configure the server, which reads `/sws.toml` first (use `server`). |
| extraVolumeMounts | list | `[]` | Extra volume mounts. `/sws.toml` and `/config.toml` are rejected: the server reads them as its configuration file, which belongs to the chart. `/app` is the published site root: mounting there serves the files to everyone. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute (path prefix `/`). FluffyChat needs a host root: sub-paths break asset loading. `/metrics` is served on the same port: see the README. |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/fluffychat"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress (path `/`). FluffyChat needs a host root: sub-paths break asset loading. `/metrics` is served on the same port: see the README. |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Liveness probe (`GET /health`). |
| metrics.enabled | bool | `false` | Serve Prometheus metrics (`GET /metrics`) on the app port, without authentication: an Ingress or HTTPRoute that forwards `/` exposes them. See the README. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor (needs `metrics.enabled`). Exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.prometheusRule.disabled | list | `[]` | Alerts to leave out, at most one (to drop both, disable `prometheusRule`). |
| metrics.prometheusRule.downFor | string | `"5m"` | How long the target may be down or absent before `FluffyChatDown` fires. |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alerts `FluffyChatDown`, `FluffyChatServerErrors`). Needs `serviceMonitor` or `podMonitor`: the rules select the `job` label it sets. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.prometheusRule.serverErrorsMinRate | float | `0.1` | Requests per second below which `FluffyChatServerErrors` stays silent: one 5xx among a handful of requests is no incident. `0`: no floor. |
| metrics.prometheusRule.serverErrorsRatio | float | `0.05` | Share of 5xx responses above which `FluffyChatServerErrors` fires (`0.05`: 5 %). |
| metrics.prometheusRule.serverErrorsWindow | string | `"15m"` | Window over which `FluffyChatServerErrors` compares 5xx responses to all responses. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor (needs `metrics.enabled`). Exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| minReadySeconds | int | `10` | Seconds a new pod must stay ready before the rollout moves on (the readiness probe only sees the port open). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: the HTTP port; no egress at all: the pod serves files and calls nothing; the browser talks to the homeserver). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the HTTP port (your ingress controller or Gateway). Empty: any source. |
| networkPolicy.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to reach the HTTP port besides `http.from`, for your Prometheus. Used only with `metrics.enabled` and a non-empty `http.from` (the port is shared with the app: with an empty `http.from`, every source already reaches it). It opens the whole app to those peers, not `/metrics` alone. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget (`unhealthyPodEvictionPolicy: AlwaysAllow`). |
| podDisruptionBudget.maxUnavailable | int | `1` | Pods that may be unavailable at once (a number or a percentage). |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2}` | Readiness probe (`GET /health`). |
| replicaCount | int | `3` | Replicas. The app is stateless: three keep a rolling update and a node loss gap-free. `0` stops the app (maintenance). |
| resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}` | Resources. A scheduling floor, not a sizing (VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| server.advanced | object | `{"headers":[{"headers":{"Cache-Control":"no-cache"},"source":"/**"}]}` | The `[advanced]` table of `sws.toml`, reachable through the file only: `headers`, `redirects`, `rewrites`, `virtual-hosts` (shapes as in the [documentation](https://static-web-server.net/configuration/config-file/); `memory-cache` is not built into the image). Header values are strings: quote `yes`, `true` and numbers, which the server rejects otherwise and the pod crash-loops. A list you set replaces the default one. Default: revalidate every file on each load (`no-cache`: a `304` when unchanged). The app files keep their names across releases (`index.html`, `main.dart.js`, `flutter_service_worker.js`, `config.json`), so a cached copy would serve a stale app after an upgrade or a `config` change. Example: `headers: [{source: "/**", headers: {Cache-Control: "no-cache"}}, {source: "/assets/**", headers: {Cache-Control: "public, max-age=3600"}}]` (later entries win). |
| server.general | object | `{"compression-level":"fastest","grace-period":5,"security-headers":true}` | The `[general]` table of the static-web-server configuration file (`sws.toml`, mounted at `/sws.toml`): upstream option names (kebab-case), see the [options](https://static-web-server.net/configuration/config-file/). The file beats the image's `SERVER_*` variables and the command line, so a key set here always wins. `health`, `host`, `metrics`, `port` and `root` belong to the chart and are rejected (`metrics` follows `metrics.enabled`). |
| server.general.compression-level | string | `"fastest"` | Compression level of the responses the server compresses on the fly (the app's own files ship precompressed; this covers the rest, such as the 7.5 MB `main.dart.js.map`). `fastest` bounds memory and CPU: at `default` (brotli quality 11) one request for that file with `Accept-Encoding: br` exceeds the `64Mi` limit and kills the container, and any visitor can send it. |
| server.general.grace-period | int | `5` | Seconds the server keeps serving after SIGTERM before it drains (0 to 255). It covers the delay before endpoint removal reaches the proxies in front, so a rolling update drops no request. `terminationGracePeriodSeconds` must exceed it. |
| server.general.security-headers | bool | `true` | Send the security headers: `Strict-Transport-Security` (`max-age=63072000; includeSubDomains; preload`), `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff` and `Content-Security-Policy: frame-ancestors 'self'`. Turn off when another layer sets them, or to embed the client in a page of another origin. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8080` | Service port (the container listens on 8080). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"periodSeconds":2,"timeoutSeconds":2}` | Startup probe (`GET /health`). |
| terminationGracePeriodSeconds | int | `30` | Seconds the pod gets to stop. Must exceed `server.general.grace-period`: the server keeps serving that long before it drains. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty: the chart spreads the replicas over zones (`topology.kubernetes.io/zone`, `ScheduleAnyway`). A list you set replaces it and needs its own `labelSelector`. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 32Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

# cryptgeon

Cryptgeon, a secure self-destructing notes and files service, as a hardened single-replica Deployment on an external Redis

Runs [cryptgeon](https://github.com/cupcakearmy/cryptgeon) (end-to-end encrypted
self-destructing notes and files) as a single-replica Deployment. The image is
built from [spnngl/images](https://github.com/spnngl/images): `scratch`, non-root,
no shell.

Cryptgeon keeps every note in **Redis**. The chart ships none: you bring one
(see [Redis](#redis)).

One replica only: the view counter is guarded by an in-process lock, so with two
instances a note can be read more often than its view limit. Every upgrade or
reschedule is a short downtime (`Recreate` strategy, so two instances never
overlap).

## Install

The chart never creates the Redis URL Secret: the URL can carry a password, which
must not live in Helm values, release history or Git. Create it first, then install.

```sh
kubectl create namespace cryptgeon
kubectl -n cryptgeon create secret generic cryptgeon \
  --from-literal=url=redis://<host>:6379/
helm install cryptgeon oci://ghcr.io/spnngl/charts/cryptgeon --version <version> -n cryptgeon
```

The Secret is named after the release (`redis.existingSecret.name` and `key` to
override). The URL is `redis://[:password@]host[:port]/[db]`; the image has no TLS
client, so `rediss://` fails at startup. Cryptgeon reads it once at startup:
restart the pod after changing the Secret.

```sh
kubectl -n cryptgeon rollout restart deployment/cryptgeon
```

Without the Secret the pod stays in `CreateContainerConfigError`. Without a
reachable Redis, cryptgeon exits at startup and the pod crash-loops until Redis
answers. Once running, a Redis outage only makes the pod unready (readiness
checks `/api/live`, which pings Redis); liveness uses `/api/status`, which does
not, so it never restarts the pod.

## Redis

Notes live only in Redis, and cryptgeon does not configure it. Settings that fit:

- **No persistence** (`save ""`, `appendonly no`): notes are secrets meant to
  vanish, persistence would write them to disk. A Redis restart loses every note.
- **A memory limit and an eviction policy** (`maxmemory`, `maxmemory-policy
  allkeys-lru`). Notes with a view limit have no expiry, so without eviction a
  full Redis refuses new notes. Keep `maxmemory` below the container memory limit.
- **Reachable only from cryptgeon** (NetworkPolicy): no TLS, and a password
  travels in the URL.

An example with the [valkey-helm](https://github.com/valkey-io/valkey-helm)
`valkey` chart, in memory:

```yaml
# valkey-values.yaml
valkeyConfig: |
  save ""
  appendonly no
  maxmemory 400mb
  maxmemory-policy allkeys-lru
resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    memory: 512Mi
```

```sh
helm install valkey oci://ghcr.io/valkey-io/valkey-helm/valkey -n cryptgeon -f valkey-values.yaml
kubectl -n cryptgeon create secret generic cryptgeon \
  --from-literal=url=redis://valkey:6379/
```

(the Service is named after the release: adjust the host.) Check the valkey chart
values for your version.

With `networkPolicy.egress.enabled`, add a rule to the Redis pods; without it the
app cannot reach Redis:

```yaml
networkPolicy:
  egress:
    enabled: true
    extraEgress:
      - to:
          - podSelector:
              matchLabels:
                app.kubernetes.io/name: valkey
        ports:
          - port: 6379
            protocol: TCP
```

## Settings

`config` holds the cryptgeon settings (upstream environment variable names). The
chart renders them into a ConfigMap read through `envFrom`; a change rolls the
pod (`checksum/config`). A key left out keeps the upstream default:

| Key | Upstream default |
|-----|------------------|
| `SIZE_LIMIT` | `1 KiB` (chart: `20 MiB`) |
| `MAX_VIEWS` | `100` |
| `MAX_EXPIRATION` | `360` (minutes) |
| `ID_LENGTH` | `32` |
| `ALLOW_ADVANCED`, `ALLOW_FILES`, `THEME_NEW_NOTE_NOTICE`, `THEME_HOME_LINK` | `true` |
| `IMPRINT_URL`, `IMPRINT_HTML`, `THEME_IMAGE`, `THEME_TEXT`, `THEME_PAGE_TITLE`, `THEME_FAVICON` | empty |

Cryptgeon panics at startup on a value it cannot parse, so the schema types every
key and rejects the others. `REDIS`, `LISTEN_ADDR` and `FRONTEND_PATH` belong to
the chart and the image. For a setting added upstream later, use `extraEnv`
(`EnvVar` list; the three owned names are rejected, and `extraEnv` wins over
`config`). `extraArgs` is passed to the binary, which takes none today.

`SIZE_LIMIT` bounds the whole request body, files included, and the body is
buffered in memory. A browser adds about 35 % of encoding overhead to a file:
with `20 MiB`, the largest file is about 15 MiB, and a body of about 27 MiB
reaches the server before it is refused. Raise the memory limit with the limit
and the number of concurrent uploads.

## Access

Open the app on `/`:

```sh
kubectl -n cryptgeon port-forward service/cryptgeon 8000:8000
```

then <http://localhost:8000/>. `ingress` (Ingress) and `httpRoute` (Gateway API
HTTPRoute) expose it publicly; both need explicit hosts (and `parentRefs` for the
route).

- **HTTPS is mandatory.** The app encrypts in the browser with WebCrypto, which
  browsers only offer on HTTPS (and `localhost`). The image serves plain HTTP:
  terminate TLS in front.
- **Body size.** ingress-nginx refuses bodies above 1 MiB by default
  (`413`): set `nginx.ingress.kubernetes.io/proxy-body-size` above
  `config.SIZE_LIMIT`, with the encoding overhead.
- **Known issue in 2.9.3**: every path except `/` (a note link, for
  example) is answered by the single-page app with status `404` even though the
  page renders. Do not alert on it. The upstream fix is not released yet.

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
  ghcr.io/spnngl/images/cryptgeon@sha256:<digest>
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
(8000). Restrict the sources with `networkPolicy.http.from` (your ingress
controller or Gateway); empty means any source. `networkPolicy.egress.enabled`
(off by default) allows DNS and `extraEgress`: add the Redis rule (see
[Redis](#redis)).

## Autoscaling and resources

There is no HPA (one replica). `verticalPodAutoscaler` supports `Off`,
`Initial`, `Recreate` and `InPlaceOrRecreate` (in-place resize needs
Kubernetes 1.33+). A recommender started with another `--recommender-name`
than `default` ignores the VPA unless `verticalPodAutoscaler.recommender`
names it. The default requests (`10m` CPU, `32Mi` memory) are scheduling
floors, not a sizing: memory follows `config.SIZE_LIMIT` and concurrent uploads,
so measure then tune.

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
* <https://github.com/cupcakearmy/cryptgeon>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| config | object | `{"SIZE_LIMIT":"20 MiB"}` | Cryptgeon settings (upstream environment variable names), rendered into a ConfigMap read through `envFrom`. A key left out keeps the upstream default. Upstream parses every value at startup and panics on a bad one, so the schema types each key and rejects the others (`VERBOSITY` is unused upstream; `REDIS`, `LISTEN_ADDR` and `FRONTEND_PATH` belong to the chart and the image; use `extraEnv` for a setting added upstream later). Upstream defaults: `MAX_VIEWS` 100, `MAX_EXPIRATION` 360 (minutes), `ID_LENGTH` 32, `ALLOW_ADVANCED` true, `ALLOW_FILES` true, `THEME_NEW_NOTE_NOTICE` true, `THEME_HOME_LINK` true, the others empty. `SIZE_LIMIT` is the maximum request body, files included (upstream default `1 KiB`, maximum `512 MiB`); the whole body is buffered in memory, and the browser adds about 35 % of encoding overhead to a file. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for the Redis host name). |
| extraArgs | list | `[]` | Extra arguments for the `cryptgeon` binary, which takes none today. |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list). Chart- and image-owned names are rejected. They win over `config`. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute (path prefix `/`). Cryptgeon needs HTTPS (WebCrypto): terminate TLS on the Gateway. |
| httpRoute.hostnames | list | `[]` | Host names (empty: any host of the Gateway listener). |
| httpRoute.labels | object | `{}` | Extra HTTPRoute labels. |
| httpRoute.parentRefs | list | `[]` | Gateways (`parentRefs`). Required when enabled. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/cryptgeon"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| ingress.annotations | object | `{}` | Ingress annotations (for ingress-nginx, `nginx.ingress.kubernetes.io/proxy-body-size` must exceed `config.SIZE_LIMIT`). |
| ingress.className | string | `""` | Ingress class name (empty: cluster default). |
| ingress.enabled | bool | `false` | Create an Ingress (path `/`). Cryptgeon needs HTTPS (WebCrypto): terminate TLS here or in front. |
| ingress.hosts | list | `[]` | Host names. Required when enabled. |
| ingress.labels | object | `{}` | Extra Ingress labels (for example the label an external-dns `--label-filter` selects). |
| ingress.tls | list | `[]` | Ingress TLS blocks (`secretName`, `hosts`). |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Liveness probe (`GET /api/status`: does not touch Redis, so a Redis outage never restarts the pod). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS and `extraEgress`). Add a rule to the Redis pods in `extraEgress`: without it the app cannot reach Redis. |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s (the Redis pods). |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: the HTTP port). |
| networkPolicy.http.from | list | `[]` | NetworkPolicyPeer list allowed to reach the HTTP port (your ingress controller or Gateway). Empty: any source. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":10}` | Readiness probe (`GET /api/live`: answers 503 while Redis is unreachable, which only removes the pod from the Service). |
| redis.existingSecret.key | string | `"url"` | Key of the URL in the Secret (`redis://[:password@]host[:port]/[db]`; the image has no TLS client, `rediss://` fails at startup). Read once at startup: restart the pod after changing it. |
| redis.existingSecret.name | string | `""` | Name of the Secret holding the Redis URL. Empty: `<fullname>`. The chart never creates it: the URL can carry a password. |
| replicaCount | int | `1` | Replicas, 0 or 1. Never more: the view counter is guarded by an in-process lock, so with two instances a note can be read more often than its view limit. `0` stops the app (maintenance). The Deployment uses the `Recreate` strategy (short downtime on every upgrade) so two instances never overlap. |
| resources | object | `{"limits":{"memory":"256Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. The memory limit bounds uploads: a request body is buffered in memory, so size it from `config.SIZE_LIMIT` times the concurrent uploads you expect (measure, then tune; VPA in `Off` mode gives recommendations). No CPU limit on purpose. |
| revisionHistoryLimit | int | `3` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8000` | Service port (the container listens on 8000). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| tolerations | list | `[]` | Tolerations. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.recommender | string | `""` | Recommender name (`spec.recommenders`, which takes at most one). Empty: the recommender named `default`. Set it when the cluster's recommender runs under another `--recommender-name`: a VPA nobody serves gets no recommendation. |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. |

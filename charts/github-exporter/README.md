# github-exporter

Prometheus exporter for GitHub repository, organization and build status metrics (github-exporter) running as a hardened Deployment

Runs [github-exporter](https://github.com/d0ugal/github-exporter) as a single
Deployment. It polls the GitHub API with a token and exports metrics for the
repositories you list (or those of the organizations you list): repository
statistics, open pull requests and issues, and, for the branches you list,
workflow runs, check runs and build status. Each replica would poll GitHub on
its own with the same token and export duplicate series, so keep
`replicaCount` at 1.

## Install

The exporter needs a GitHub token and something to export (`github.repos`
and/or `github.orgs`).

The chart never creates the token Secret: the token stays out of Helm values,
release history and Git. Create it, then install:

```sh
kubectl create namespace github-exporter
kubectl -n github-exporter create secret generic github-exporter --from-literal=token=<token>
helm install github-exporter oci://ghcr.io/spnngl/charts/github-exporter --version <version> -n github-exporter \
  --set 'github.repos[0]=spnngl/charts'
```

The Secret is named after the release (`github.existingSecret.name` to
override, `github.existingSecret.key` defaults to `token`). Without it the pod
stays in `CreateContainerConfigError` (`secret "github-exporter" not found`)
until the Secret exists.

**Use a dedicated token.** Before each rate limit reset the exporter spends
80% of what the token has left (`github.rateLimitBuffer`), which starves every
other tool sharing the token. The token needs read access to the repositories
it exports (and to Actions and checks when `github.branches` is set); the
chart was not tested against a real token. For a shared token lower
`github.rateLimitBuffer` or set `github.refreshInterval`.

`github.repos` and `github.orgs`:

- `github.repos` takes `owner/name` entries, or `"*"` for every repository the
  token can see.
- `github.orgs` lists the repositories of each organization.
- At least one of them is required: the exporter exits at startup otherwise,
  and the chart refuses to render. **`github.repos` defaults to a
  placeholder (`d0ugal/github-exporter`)** that keeps the default render valid.
  Helm replaces lists instead of merging them, so when you set `github.orgs`
  only, also set `github.repos: []`, or the placeholder stays. `NOTES.txt`
  warns while it is there.

The token is visible in the container environment (upstream has no token-file
option) and is read at startup: after rotating it, restart the pod,

```sh
kubectl -n github-exporter rollout restart deployment/github-exporter
```

or let [Reloader](https://github.com/stakater/Reloader) do it with
`podAnnotations: {reloader.stakater.com/auto: "true"}`.

## Image

The default image is `appVersion` pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates both
together, weekly). Setting `image.tag` drops that digest; add `image.digest` to
pin the tag again (`image.digest` without `image.tag` is an error).

The upstream image is not signed (no cosign signature, no attestations beyond
the build ones, checked on v0.5.73). The digest pin only guarantees that the
same bytes are pulled every time, not who built them.

## Configuration

- Upstream ignores the `server`, `logging`, `metrics`, `tracing` and
  `profiling` keys of its YAML configuration file (an upstream bug: the
  embedded base configuration is not inlined), and its `/` page only shows
  those ignored defaults. The chart therefore has no
  configuration file: every setting is an environment variable, built from
  the values. Settings without a value (`GITHUB_EXPORTER_GITHUB_TIMEOUT`,
  tracing `TRACING_*`, profiling `PROFILING_*`) go through `extraEnv`; names
  the chart owns are rejected. OTLP headers cannot be set at all.
- Entries of `github.orgs`, `github.repos`, `github.branches` and
  `github.workflows` are joined with commas: they cannot contain commas
  (workflow names can contain spaces, the others cannot contain whitespace).
- Build status (`github.branches`) costs API calls per repository and
  branch every cycle, and the open pull request counts use the Search API,
  which allows 30 requests per minute: with more than about 30 repositories
  the exporter hits that limit on every cycle (`github_api_errors_total` with
  `endpoint="search_issues"`; the chart's alert leaves it out for that reason).
- The refresh interval is computed from the remaining rate limit unless you
  set `github.refreshInterval`; it does not account for the Search API limit
  or for the repositories behind `github.orgs`.
- The exporter never forgets a series. A deleted or renamed repository, and a
  workflow run `conclusion` that changed, keep their last value until the pod
  restarts. Alert and graph on `github_branch_build_status` (no `conclusion`
  label, the worst status of the branch wins), not on
  `github_workflow_run_status`.
- `github_check_run_status` has one series per repository, branch, check and
  conclusion: with many repositories it dominates the cardinality. Drop it with
  `metrics.serviceMonitor.metricRelabelings` (or `podMonitor`) when you do not
  need it:

  ```yaml
  metricRelabelings:
    - sourceLabels: [__name__]
      regex: github_check_run_status
      action: drop
  ```

- The exporter logs every HTTP request at `info`, probes and scrapes
  included; `logLevel: warn` silences them.
- `/health` answers 200 once the server listens, whatever GitHub does: a
  GitHub outage or a bad token never restarts or unreadies the pod. Watch
  `github_api_errors_total` (or the alerts below) instead.

## Resources

Requests `10m` CPU / `32Mi` memory and a `128Mi` memory limit, no CPU limit.
These are estimates, not measurements under a real collection: tune them for
your repository count. With a memory limit set, `GOMEMLIMIT` follows it, and a
memory resize restarts the container so the value never goes stale.

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 1000,
read-only root filesystem, all capabilities dropped, no privilege escalation,
`RuntimeDefault` seccomp, no ServiceAccount token, no Service environment
variables. The exporter writes nothing to disk.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 1000 in the
pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support (containerd
2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+; see the Kubernetes
documentation on user namespaces. On other nodes the pod sandbox cannot be
created (`FailedCreatePodSandBox` event): set `hostUsers: true`.

## Network

- **Warning**: upstream cannot turn off its web interface, and the metrics
  port serves it at `/`: it lists the metrics and basic server settings (no token,
  no repository names; its footer even links to another exporter). The NetworkPolicy (`networkPolicy.enabled`, on by default)
  restricts ingress to port 8080, but with `networkPolicy.metrics.from: []`
  any in-cluster source is allowed: set it to your Prometheus namespace / pods.
- `networkPolicy.egress.enabled` (off by default) allows DNS, HTTPS to GitHub
  (`api.github.com`) and `networkPolicy.egress.extraEgress` (for example a
  tracing endpoint). GitHub has no stable address, so `egress.github.to`
  defaults to any address. Narrow it to GitHub's published ranges (regional
  `/32`s serve clusters outside the US and EU):

  ```sh
  curl -s https://api.github.com/meta | jq '[.api[]] | unique'
  ```

  The list changes over time: refresh it. Override `dns.to` for NodeLocal DNSCache
  or a non-default DNS namespace.
- `metrics.serviceMonitor` or `metrics.podMonitor` (not both) integrate with
  the Prometheus Operator; a PodMonitor needs no Service. The ClusterIP
  Service `<fullname>-metrics` on port 8080 is rendered with a ServiceMonitor,
  or with `metrics.service.enabled`.
- `metrics.prometheusRule` adds alerts and needs one of the monitors (the
  rules select the `job` label it sets; do not rewrite `job` in
  `relabelings`): `GitHubExporterDown` (critical, also fires with
  `replicaCount: 0` or a Pending pod), `GitHubExporterAPIErrors` and
  `GitHubExporterRateLimitLow` (warning). Silence some with
  `metrics.prometheusRule.disabled`. The exporter spends most of the
  remaining quota before each reset, so the rate limit gauge dips right before
  it by design: keep `rateLimitLowFor` above 10 minutes.
- `helm test` calls `/health` through the Service. It works with a fake token
  because `/health` does not depend on GitHub, so it checks the wiring, not
  the token. It exists only with the Service and when `replicaCount` > 0, and
  fails when `networkPolicy.metrics.from` does not allow the test pod.

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
* <https://github.com/d0ugal/github-exporter>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. Empty on purpose: a single replica has nothing to spread. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for `api.github.com`). |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for settings without a value: `GITHUB_EXPORTER_GITHUB_TIMEOUT`, tracing (`TRACING_*`) and profiling (`PROFILING_*`). Names the chart owns are rejected. Rendered after `GOMEMLIMIT`. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the exporter container. |
| extraVolumes | list | `[]` | Extra volumes. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| github.branches | list | `[]` | Branches whose workflow and check run status is exported (`github_branch_build_status`, `github_workflow_run_*`, `github_check_run_status`). Empty: no build status. Each repository and branch costs 2 API calls per cycle, and needs a token that can read Actions and checks. |
| github.existingSecret.key | string | `"token"` | Key of the token in the Secret. |
| github.existingSecret.name | string | `""` | Name of an existing Secret holding the GitHub token. Empty: `<fullname>`. The chart never creates it: upstream reads the token from its environment only (no file option), so the chart passes it with a `secretKeyRef`. |
| github.orgs | list | `[]` | Organizations to export: their repositories are listed and exported. With `repos` empty and only `orgs` set, also set `repos: []` (the default below is a placeholder). Entries cannot contain commas or whitespace (they are passed comma-separated in an environment variable). |
| github.rateLimitBuffer | float | `0.8` | Share of the remaining API rate limit the exporter may spend before the next reset. With a shared token the exporter starves its other users at the default; lower it, or set `refreshInterval`. |
| github.refreshInterval | string | `""` | Fixed time between collections, a Go duration (`5m`). Empty: computed from the remaining API rate limit, between 30s and 1h (upstream ignores the Search API limit and the repositories listed through `orgs` in that computation). Set it when the token is shared with other tools. |
| github.repos | list | `["d0ugal/github-exporter"]` | Repositories to export, `owner/name`, or `"*"` for every repository the token can see. At least one of `orgs` and `repos` is required: the exporter exits at startup without them, and the chart refuses to render. The default is a placeholder that keeps the default render valid and polls a public repository: replace it, or set `repos: []` when you use `orgs` only. |
| github.workflows | list | `[]` | Workflow names to export. Empty: every workflow. Names can contain spaces but not commas. |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 1000 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+); pods fail to start otherwise. `true` uses host users. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/d0ugal/github-exporter"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: `appVersion` pinned by the digest recorded in `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/health","port":"http-metrics"},"periodSeconds":10}` | Liveness probe, `/health`. A GitHub outage or an invalid token never restarts the pod. |
| logFormat | string | `"json"` | Log format. |
| logLevel | string | `"info"` | Log level. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor (no Service needed). Exclusive with `serviceMonitor`. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.podMonitor.labels | object | `{}` | Extra labels. |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.prometheusRule.apiErrorsFor | string | `"15m"` | `GitHubExporterAPIErrors` duration. Search API errors are excluded (see the README). |
| metrics.prometheusRule.disabled | list | `[]` | Alerts to leave out (at most two: disable `prometheusRule` instead). `GitHubExporterDown` also fires when no target exists (pod Pending) and with `replicaCount: 0`. |
| metrics.prometheusRule.downFor | string | `"5m"` | `GitHubExporterDown` duration. |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alerts `GitHubExporterAPIErrors`, `GitHubExporterRateLimitLow`, `GitHubExporterDown`). Needs `serviceMonitor` or `podMonitor`: the rules select the `job` label it sets. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.prometheusRule.rateLimitLowFor | string | `"15m"` | `GitHubExporterRateLimitLow` duration. The exporter spends most of the remaining quota before each reset, so a busy configuration dips low right before it (and the gauge lags up to 5 minutes after it): keep this above 10m. |
| metrics.prometheusRule.rateLimitRemainingRatio | float | `0.1` | `GitHubExporterRateLimitLow` threshold: remaining share of the core API rate limit. |
| metrics.service.annotations | object | `{}` | Service annotations. |
| metrics.service.enabled | bool | `false` | Render the metrics Service (also rendered when `serviceMonitor.enabled`; adds the `helm test` pod). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. Exclusive with `podMonitor`. |
| metrics.serviceMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.serviceMonitor.metricRelabelings | list | `[]` | Metric relabelings (for example to drop `github_check_run_status`, one series per repository, branch, check and conclusion). |
| metrics.serviceMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.serviceMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| minReadySeconds | int | `10` | Seconds a new pod must be Ready before the old one is retired. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, GitHub, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s (for example a tracing endpoint). |
| networkPolicy.egress.github.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0"}},{"ipBlock":{"cidr":"::/0"}}]` | GitHub peers (port 443, `api.github.com`). See the README to narrow the default to GitHub's published ranges. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy (ingress: port 8080 only). |
| networkPolicy.metrics.from | list | `[]` | NetworkPolicyPeer list allowed to reach port 8080. Empty: any source. The port also serves the `/` dashboard (metric list and basic server settings; upstream cannot turn it off): restrict it to your Prometheus. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. Merged with (and cannot drop) the default `kubernetes.io/os: linux`. |
| podAnnotations | object | `{}` | Pod annotations (for example `reloader.stakater.com/auto: "true"` to restart on Secret rotation). |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":1000,"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":1,"httpGet":{"path":"/health","port":"http-metrics"},"periodSeconds":10}` | Readiness probe, `/health`. It answers 200 once the server listens, whatever GitHub does. |
| replicaCount | int | `1` | Number of exporters. Keep `1`: every replica polls GitHub on its own with the same token (N replicas spend N times the rate limit, and each then slows down) and exports the same series (`sum()` counts them twice). An exporter outage only leaves a gap in the graphs. `0` stops the exporter. |
| resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. Idle estimates, not measurements under a real collection (many repositories, `"*"`, build status): tune them for your configuration. No CPU limit on purpose. With a memory limit, `GOMEMLIMIT` follows it. |
| revisionHistoryLimit | int | `10` | Old ReplicaSets to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":30,"httpGet":{"path":"/health","port":"http-metrics"},"periodSeconds":2}` | Startup probe, `/health`. Restarts a pod that does not listen within `periodSeconds` x `failureThreshold` (60s). |
| strategy.rollingUpdate | object | `{"maxSurge":1,"maxUnavailable":0}` | Used with `RollingUpdate` only. |
| strategy.type | string | `"RollingUpdate"` | Update strategy. `Recreate` stops the old exporter first (a gap in the graphs) instead of overlapping two for `minReadySeconds`. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty on purpose: a single replica has nothing to spread. |
| verticalPodAutoscaler.controlledResources | list | `["cpu","memory"]` | Resources VPA controls. |
| verticalPodAutoscaler.controlledValues | string | `"RequestsAndLimits"` | Whether VPA also scales limits. |
| verticalPodAutoscaler.enabled | bool | `false` | Create a VerticalPodAutoscaler (needs the VPA CRDs, see the `vertical-pod-autoscaler-crds` chart). |
| verticalPodAutoscaler.maxAllowed | object | `{}` | Upper bound of recommendations. |
| verticalPodAutoscaler.minAllowed | object | `{}` | Lower bound of recommendations (for example `{cpu: 25m, memory: 64Mi}`). |
| verticalPodAutoscaler.updateMode | string | `"Off"` | VPA update mode. Recommendations only by default. |

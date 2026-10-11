# nftables-exporter

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.4.5](https://img.shields.io/badge/AppVersion-0.4.5-informational?style=flat-square)

Prometheus exporter for the nftables ruleset of every node (counters, chains, rules), running as a hardened DaemonSet

Runs the [metal-stack nftables exporter](https://github.com/metal-stack/nftables-exporter)
as a DaemonSet. On every scrape it reads the node's nftables ruleset
(`nft -j -t list ruleset`, set elements left out) and exports:

- `nftables_up`: 1 when `nft` succeeded, 0 otherwise (the HTTP answer is 200
  either way);
- `nftables_counter_bytes` / `nftables_counter_packets`: named counters;
- `nftables_table_chains`, `nftables_chain_rules`: ruleset size;
- `nftables_rule_bytes` / `nftables_rule_packets`: one series per rule with a
  `counter` statement, labelled with its chain, handle, comment, addresses and
  ports.

Every table of the node is read, whoever owns it (kube-proxy in `nftables`
mode, iptables-nft, firewalls, CNI plugins).

## Install

The pods read the node's netfilter: they run as root in the host network
namespace with `NET_ADMIN`. The namespace must allow that (Pod Security
Standard `privileged`):

```sh
kubectl create namespace nftables-exporter
kubectl label namespace nftables-exporter pod-security.kubernetes.io/enforce=privileged
helm install nftables-exporter oci://ghcr.io/spnngl/charts/nftables-exporter --version <version> -n nftables-exporter \
  --set metrics.podMonitor.enabled=true
```

Exporter options go in `config`, rendered as its config file (maps merge with
the defaults, lists replace, unknown keys are ignored by the exporter).
`nftables_exporter.bind_to` is chart-owned: set `metrics.port` and
`metrics.bindAddress` instead.

## Image

The default image is `appVersion` pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates both
together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (`image.digest` without `image.tag` is an error).

The image is built in [spnngl/images](https://github.com/spnngl/images) with
[Dalec](https://github.com/project-dalec/dalec): Debian trixie without shell
or package manager, the exporter compiled from the upstream release commit,
Debian's `nft` at `/usr/sbin/nft`. It is rebuilt weekly: the tag is the
exporter version, the digest moves. The exporter is GPL-3.0-only: its license
ships in the image (`/usr/share/doc/nftables-exporter/`), the source is the
upstream tag of the image version. The image is signed with a key, not
keyless like the charts, and carries a SLSA provenance and an SBOM:

```sh
cosign verify --insecure-ignore-tlog=true --new-bundle-format=false \
  --key https://raw.githubusercontent.com/spnngl/images/main/images/fedora/sysroot/common/usr/share/pki/containers/spnngl-images.pub \
  ghcr.io/spnngl/images/nftables-exporter@<digest>
docker buildx imagetools inspect ghcr.io/spnngl/images/nftables-exporter@<digest> --format '{{ json .Provenance }}'
```

The signature is not uploaded to the Rekor transparency log
(`--insecure-ignore-tlog`) and uses the legacy signature format
(`--new-bundle-format=false`).

## Availability and scheduling

- One pod per node, `RollingUpdate` with `maxUnavailable: 1` and `maxSurge: 0`
  (not configurable: two pods cannot share the node port),
  `minReadySeconds: 5`. A node's metrics are missing for a few seconds during
  an update. `updateStrategy.type: OnDelete` gives full control.
- Control-plane and other tainted nodes are skipped. Set `tolerations`
  (`- operator: Exists`) to export them too.
- The readiness probe is a TCP check of the metrics port: `/metrics` runs
  `nft` and answers 200 even when it fails. There is no liveness probe: the
  exporter exits when it cannot listen, and no check can tell a hung process.
- No PodDisruptionBudget, HorizontalPodAutoscaler or NetworkPolicy: the pods
  are one per node and use the host network (NetworkPolicy does not apply).

## Resources

Defaults: requests `10m` CPU / `32Mi` memory, a `512Mi` memory limit and no
CPU limit. Every scrape runs `nft` once, inside the pod's cgroup, and parses
its JSON output: memory and CPU grow with the ruleset size and the scrape
rate. The size that matters is `nft list ruleset | wc -l` on a node, not the
number of services:

| kube-proxy mode, 3000 services with one endpoint each | Ruleset | Exporter memory |
|---|---:|---|
| `nftables` | 4900 lines (0.5 MB JSON) | 16 MiB |
| `iptables` | 33000 lines (6.7 MB JSON) | killed at 256Mi, fine at 512Mi |

Measured on kind (exporter 0.4.5, nft 1.1.3), one scraper. With rules that
have a counter and a comment, `128Mi` held about 7000 rules with one scraper
and 3000 with two.

Every scrape runs its own `nft` (about 80 MiB for 10000 rules) and the
exporter does not serialise them: an HA Prometheus pair doubles the peak. A
scrape takes 0.13 s for 1000 rules, 0.35 s for 10000. Size the limit to your
largest node: a pod killed by the OOM killer restarts and is killed again at
the next scrape.

No `GOMEMLIMIT` is set: the `nft` child process is outside the Go runtime's
accounting, and a Go memory limit did not move the breaking point (same with
90% of the limit, 50% and none).

`nftables_rule_*` has one series per counted rule, with its comment and
addresses as labels: on nodes with large or churning rulesets, drop it with
`metrics.podMonitor.metricRelabelings`.

## Security

Root is required: Kubernetes has no ambient capabilities, so only root keeps
`NET_ADMIN` in the `nft` child process (as UID 65532 with `NET_ADMIN`,
`nftables_up` stays 0). Defaults: all capabilities dropped but `NET_ADMIN`,
no privilege escalation, read-only root filesystem, `RuntimeDefault` seccomp,
no ServiceAccount token, no Service environment variables. The pod uses the
host network, so it never runs in a user namespace (`hostUsers` is not
offered). SELinux policies that deny the container
`netlink_netfilter_socket` need `securityContext.seLinuxOptions.type: spc_t`.

The exporter only reads the ruleset (`nft list`), logs JSON to stdout and
writes nothing to disk.

## Network

- The metrics listen on port `metrics.port` (a port of every node), at
  `127.0.0.1` by default. With `metrics.podMonitor.enabled` they listen on
  every node interface (`0.0.0.0`) and Prometheus scrapes the node IP: open
  the port from Prometheus to the nodes (cloud firewalls, security groups),
  and firewall it from untrusted networks, the metrics have no
  authentication. `metrics.bindAddress: 0.0.0.0` does the same without the
  Prometheus Operator. IPv6-only nodes are not supported.
- `metrics.prometheusRule` adds the alert `NftablesExporterReadFailed`
  (warning): `nftables_up == 0` for 5 minutes, the exporter cannot read its
  node's ruleset. It needs the PodMonitor (the rule selects the `job` label
  it sets; do not rewrite `job` in `relabelings`).
- The exporter resolves no name: `dnsPolicy: Default`.

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
* <https://github.com/metal-stack/nftables-exporter>
* <https://github.com/spnngl/images/tree/main/images/nftables-exporter>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| config | object | `{"nftables_exporter":{"log_level":"warn","nft_location":"/usr/sbin/nft","url_path":"/metrics"}}` | Free-form exporter configuration, rendered as its YAML config file (maps merge with these defaults, lists replace). Unknown keys are ignored by the exporter. `nftables_exporter.bind_to` is chart-owned (see `metrics`) and rejected. |
| config.nftables_exporter.log_level | string | `"warn"` | Log level (JSON logs on stdout). |
| config.nftables_exporter.nft_location | string | `"/usr/sbin/nft"` | Path of `nft` in the image. The exporter runs `nft -j -t list ruleset` on every scrape. |
| config.nftables_exporter.url_path | string | `"/metrics"` | HTTP path of the metrics (every other path answers 404). |
| extraArgs | list | `[]` | Extra exporter command-line arguments, placed after `--config <file>`. The exporter has no other option than `--version` (prints and exits): settings belong in `config`. |
| extraEnv | list | `[]` | Extra environment variables (list of `EnvVar`). The exporter reads none: only the Go runtime ones apply (`GOMEMLIMIT`, `GODEBUG`, ...). |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the exporter container. |
| extraVolumes | list | `[]` | Extra volumes (for example a ruleset JSON for `config.nftables_exporter.fake_nft_json`). |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/nftables-exporter"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: `appVersion` pinned by the digest recorded in `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| metrics.bindAddress | string | `""` | Metrics listen address. Empty: `127.0.0.1`, or `0.0.0.0` (every node interface, Prometheus scrapes the node IP) with `podMonitor.enabled`. Set `0.0.0.0` to scrape without the Prometheus Operator. IPv6-only nodes are not supported. The metrics have no authentication: firewall the port from untrusted networks. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor. The metrics then listen on every node interface: Prometheus must reach the port on the nodes (cloud firewalls, security groups), firewall it from untrusted networks. |
| metrics.podMonitor.interval | string | `""` | Scrape interval (empty: Prometheus default). Every scrape runs `nft` once. |
| metrics.podMonitor.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| metrics.podMonitor.metricRelabelings | list | `[]` | Metric relabelings, for example to drop `nftables_rule_*`: one series per counted rule, with its comment and addresses as labels. |
| metrics.podMonitor.relabelings | list | `[]` | Relabelings. |
| metrics.podMonitor.scrapeTimeout | string | `""` | Scrape timeout (empty: Prometheus default). |
| metrics.port | int | `9630` | Metrics listen port. It is a port of every node (host network): the pod does not schedule on a node where it is taken. |
| metrics.prometheusRule.enabled | bool | `false` | Create a Prometheus Operator PrometheusRule (alert `NftablesExporterReadFailed`: `nftables_up == 0` for 5 minutes). Needs `podMonitor`: the rule selects the `job` label it sets. |
| metrics.prometheusRule.labels | object | `{}` | Extra labels (for example `release: kube-prometheus-stack`). |
| minReadySeconds | int | `5` | Seconds a new exporter must be Ready before the next node is updated. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. Merged with the default `kubernetes.io/os: linux`: set that key to `null` to drop it. |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"runAsGroup":0,"runAsNonRoot":false,"runAsUser":0,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. Root is required: Kubernetes has no ambient capabilities, so only root keeps `NET_ADMIN` in the `nft` child process. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":1,"periodSeconds":2,"tcpSocket":{"port":"metrics"}}` | Readiness probe: the metrics port accepts connections. TCP on purpose: `/metrics` runs `nft` and answers 200 even when it fails (see `nftables_up`). The chart sets `tcpSocket.host` to `metrics.bindAddress` unless it is `0.0.0.0`. No liveness probe: the exporter exits when it cannot listen, and no check can tell a hung process. |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources. Memory grows with the ruleset size: every scrape runs `nft -j` in the pod's cgroup and parses its JSON output. Concurrent scrapes (an HA Prometheus pair) each run their own `nft`. Measured with one scraper: 512Mi holds 33000 ruleset lines (kube-proxy iptables mode, 3000 services with one endpoint each), 256Mi does not; kube-proxy nftables mode needs far less (16 MiB for 3000 services). Size it to `nft list ruleset | wc -l` on your largest node. No CPU limit on purpose. Like the other maps, `limits` and `requests` merge with these defaults: set a key to `null` to drop it. |
| revisionHistoryLimit | int | `3` | Old ControllerRevisions to keep. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["NET_ADMIN"],"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":0,"runAsNonRoot":false,"runAsUser":0,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. Overrides are merged onto these defaults. `NET_ADMIN` is the only capability, needed to read the node's nftables ruleset. On SELinux nodes that deny `netlink_netfilter_socket`, set `seLinuxOptions: {type: spc_t}`. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| terminationGracePeriodSeconds | int | `5` | Termination grace period. The exporter does not handle SIGTERM: it exits at once. |
| tolerations | list | `[]` | Tolerations. None by default: tainted nodes (control plane) are skipped. Uncomment `operator: Exists` to run on every node. |
| updateStrategy.rollingUpdate.maxUnavailable | int | `1` | Nodes updated at once (their metrics are missing for a few seconds). |
| updateStrategy.type | string | `"RollingUpdate"` | DaemonSet update strategy. There is no `maxSurge`: two exporters cannot share the node port. |

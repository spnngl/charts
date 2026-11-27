# speculaire

Spéculaire node agent (registry mirror, P2P image distribution and NRI image-verification gate) and its reflectors, as two DaemonSets

Runs [Spéculaire](https://github.com/spnngl/speculaire) on every node: a
registry mirror on the node's loopback that the container runtime pulls
through, peer-to-peer image distribution between nodes, and an NRI plugin
that refuses to start containers whose image fails the verification policy.
Two DaemonSets: `<release>-agent` on most nodes, `<release>-reflector` on the
nodes labelled `reflector.nodeLabel` (the control plane by default). A
reflector is an agent with `role = "reflector"`: it also tells the agents
which peers hold which image. Nodes labelled
`speculaire.spnngl.github.io/disabled` run neither.

## Install

Install into `kube-system`, next to the other node components: its Pod
Security level allows the host network and host directories the pods need
(another namespace must be labelled `pod-security.kubernetes.io/enforce=privileged`).

```sh
helm install speculaire oci://ghcr.io/spnngl/charts/speculaire --version <version> -n kube-system \
  --set runtime=containerd \
  --set-file config.toml=config.toml \
  --set-file config.policy=policy.yaml
```

- `runtime` (`containerd` or `cri-o`) picks the node directories the pods
  mount. Every node of a release runs the same runtime: install one release
  per runtime, split with `nodeSelector`.
- The runtime must have NRI enabled. Before making it require `speculaire`
  (containerd `required_plugins`, CRI-O `nri_validator_required_plugins`),
  set the key of `gate.tolerateAnnotation`
  (`speculaire.spnngl.github.io/tolerate-missing-plugins` by default), which
  the chart puts on both pods, in the runtime's NRI `default_validator`:
  containerd `tolerate_missing_plugins_annotation` under
  `[plugins.'io.containerd.nri.v1.nri'.default_validator]`, CRI-O
  `nri_validator_tolerate_missing_plugins_annotation` under
  `[crio.nri.default_validator]`. Otherwise a node whose agent stops cannot
  start it again.
- CRI-O: set `auto_reload_registries = true` under `[crio.image]`. The
  `configure` init container writes `registries.conf.d/99-speculaire.conf`
  but cannot run `systemctl reload crio` from a pod.
- The pods mount `/etc/kubernetes/pki/ca.crt` (the cluster CA, kubeadm's
  path) and `/var/lib/kubelet/pki` (the kubelet client certificate, the
  node's identity towards its peers). On another layout, point
  `identity.ca` / `identity.certificate` in `config.toml` at a path mounted
  with `extraVolumes` / `extraVolumeMounts`.

### Config

`config.toml` is the agent's config as a TOML string (a map would lose its
integers: Helm turns every number into a float). Keys left out take the
agent's defaults (`packaging/config.toml` in spnngl/speculaire). Set
`reflector.url` (and the reflectors' `reflector.members`) or each node pulls
from upstream alone. `role` is chart-owned: the reflectors get the same text
after `role = "reflector"`.

With `config.source: configMap` (default) the chart writes `config.toml`,
`policy.yaml` (`config.policy`) and `trusted_root.json` (`config.trustedRoot`,
with `verify.trusted_root = "/etc/speculaire/trusted_root.json"`) to a
ConfigMap, mounted as the directory `/etc/speculaire` (never `subPath`, which
never updates).

- **Live keys** (the policy included) reload by themselves: the kubelet
  syncs the ConfigMap within about a minute, the agent reads it within
  `config.poll_interval`. A config change does not roll the pods.
- **Restart keys** (marked `Restart` in `packaging/config.toml`: identity,
  runtime paths, listener addresses, `verify.trusted_root`, ...) keep their
  running value, with a warning in the logs, until a restart, reflectors
  first:

  ```sh
  kubectl -n kube-system rollout restart daemonset/speculaire-reflector
  kubectl -n kube-system rollout restart daemonset/speculaire-agent
  ```

With `config.source: host` the pods read each node's own `/etc/speculaire`
(read-only), managed outside the chart, and `config.toml`, `config.policy`
and `config.trustedRoot` must stay empty. The reflector nodes' own
`config.toml` must then set `role = "reflector"`.

### Trust store

The agent trusts the image's CA bundle (Alpine's Mozilla bundle) for
upstream registries. `hostTrustStore.enabled: true` mounts the node's trust
store over it, read-only, so a CA added on the node (a private registry's) is
trusted as with the systemd install. The agent loads roots like OpenSSL: the
first bundle file found and every file of `/etc/ssl/certs` and
`/etc/pki/tls/certs`. `hostTrustStore.paths` lists the node directories
mounted; the default covers both layouts:

- Debian/Ubuntu: `/etc/ssl/certs/ca-certificates.crt` is a file of the first
  directory.
- Fedora/RHEL/Fedora CoreOS: `/etc/ssl/certs/*.crt` are absolute symlinks
  into `/etc/pki/ca-trust/extracted`, which resolve inside the container, so
  that directory is mounted too; the agent then reads
  `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`.

A listed directory missing on the node is created empty (hostPath
`DirectoryOrCreate`): keep only your layout's paths to avoid it. Another
layout lists its own directories, symlink targets included.

## Image

The default image is `appVersion` pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml`.

Spéculaire has no release yet: spnngl/images tags its image with the first
8 characters of the commit it builds (`3e1010cf`), and `appVersion` is that
tag. Renovate cannot order commit tags, so a manager of its own
(`renovate.json5`, `custom.speculaire-*`) reads the newest commit tag and its
digest from Docker Hub's tag list (`docker.io/loladelannoy/speculaire`, the
same digests as ghcr.io) and moves `appVersion`, the tag and the digest in
one PR, merged by hand. At the first release: put back the
`# renovate: datasource=docker depName=ghcr.io/spnngl/images/speculaire`
line above `appVersion`, set `appVersion` and the annotation to the version
tag and its digest, and delete the `speculaire` custom manager and
custom datasources from `renovate.json5` (their 8-hex patterns stop matching
by themselves). The shared chart manager then tracks version tags.

Setting `image.tag` drops the chart's digest; add `image.digest` to pin
the tag again (`image.digest` without `image.tag` is an error). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (`image.digest` without `image.tag` is an error). The agents,
the reflectors and the init container run the same image, except that
`reflector.image.tag` (and `digest`) moves the reflectors alone.

The image is built in [spnngl/images](https://github.com/spnngl/images)
(`FROM scratch`, the static `speculaire` binary). It is signed with a key,
not keyless like the charts, and carries a SLSA provenance attestation:

```sh
gh attestation verify oci://ghcr.io/spnngl/images/speculaire:<tag> -R spnngl/images
cosign verify --insecure-ignore-tlog=true --new-bundle-format=false \
  --key https://raw.githubusercontent.com/spnngl/images/main/bootc/fedora/sysroot/common/usr/share/pki/containers/spnngl-images.pub \
  ghcr.io/spnngl/images/speculaire@<digest>
```

## Upgrade

One minor version at a time, reflectors first. The chart does not order its
two DaemonSets: an upgrade that changes the peer protocol takes two commands,
the first rolling the reflectors alone:

```sh
helm upgrade speculaire <chart> -n kube-system --reuse-values --wait --set reflector.image.tag=<new>
helm upgrade speculaire <chart> -n kube-system --reuse-values --wait --set image.tag=<new> --set reflector.image.tag=null
```

The second leaves the reflectors' image as it is, so only the agents roll.

## Uninstall

`helm uninstall` first runs `speculaire unconfigure` on every node that runs
a pod of the chart, in a `pre-delete` hook: a DaemonSet per component runs
it in an init container, and a pod waits for both, as a ServiceAccount that
may read them and list the namespace's pods. The nodes are then as before
the install (no mirror entry in the runtime's registry config, no mirror
certificates, no image pinned by the agent), and Helm deletes the agents.

`unconfigure` refuses while the runtime requires `speculaire`: once its
agent is gone, the runtime would start no container. The wait pod then fails
at once, naming each node and the runtime's key; Helm 4 prints its log,
Helm 3 names the pod only (`kubectl logs`). The uninstall stops there: the
agents keep running, but the nodes whose `unconfigure` succeeded pull
without the mirror. Remove `speculaire` from the runtime's required plugins,
restart the runtime and uninstall again; or, to keep Spéculaire, restart
both DaemonSets (`kubectl rollout restart`), whose `configure` puts the
mirror back.

- The hook's pods are gated like any other: under `gate.mode = "enforce"`
  the policy must allow the chart's image, or exempt its namespace.
- `--timeout` (5 minutes by default) bounds the hook; the wait pod gives up
  after 4 minutes, naming each node not done and why.
- `helm uninstall --no-hooks` skips the hook and leaves every node
  configured: run `speculaire unconfigure` on each first.

## Availability and scheduling

- One pod per node, every taint tolerated, `priorityClassName:
  system-node-critical`: once the runtime requires `speculaire`, a node
  without its agent starts no container.
- `RollingUpdate` with `maxUnavailable: 1` and `maxSurge: 0` (two agents on a
  node would compete for the host ports). While its agent restarts a node
  pulls without the mirror, and under `required_plugins` starts only pods
  carrying the tolerate annotation. `updateStrategy.type: OnDelete` gives
  full control.
- The `configure` init container runs at every pod start: it is idempotent,
  and keeps the runtime's registry config in line with `config.toml`.
- Probes on the status listener (port 7482, `metrics.address`): startup and
  liveness `GET /livez`, readiness `GET /readyz` (the gate registered with
  NRI, the mirror and the reflector listening). Moving `metrics.address`
  needs the three probes overridden.
- `terminationGracePeriodSeconds: 20`: the agent drains and exits within it.
- No PodDisruptionBudget, Service or NetworkPolicy: the pods are one per node
  and use the host network.

## Resources

Requests `50m` CPU / `128Mi` memory, no limit on purpose: an agent killed for
memory blocks every container start on a node whose runtime requires it.

## Security

Root, because the agent writes the runtime's root-owned registry config and
connects to the root-only runtime and NRI sockets. Not privileged, no
capability, no privilege escalation, read-only root filesystem,
`RuntimeDefault` seccomp, no host PID, no ServiceAccount token, no Service
environment variables.

The pods mount node directories, each at its node path:

| Path | Access | Why |
| --- | --- | --- |
| `/run/containerd` or `/var/run/crio` | read-only | runtime socket (a directory: a runtime restart makes a new socket) |
| `/var/run/nri` | read-only | NRI socket |
| `/etc/containerd` or `/etc/containers` | read-only | runtime config |
| `/etc/containerd/certs.d`, or `/etc/containers/registries.conf.d` and `/etc/containers/certs.d` | read-write | the mirror entry `configure` writes |
| `/var/lib/containerd/io.containerd.content.v1.content` or `/var/lib/containers/storage/overlay-images` | read-only | images the node holds, served to peers |
| `/var/lib/kubelet/pki` | read-only | node identity (a directory: the kubelet rotates the certificate behind a symlink) |
| `/etc/kubernetes/pki/ca.crt` | read-only | cluster CA, this file only |
| `/var/lib/speculaire`, `/run/speculaire` | read-write | the agent's state and cache |
| `/etc/speculaire` | read-only | `config.source: host` only |
| `hostTrustStore.paths` (`/etc/ssl/certs`, `/etc/pki/ca-trust/extracted`) | read-only | the node's CA trust store, `hostTrustStore.enabled` only |

A read-only path is read-only below too (`recursiveReadOnly: IfPossible`):
`/run/containerd` holds every container's root filesystem. On a kernel
older than 5.12 or a runtime without recursive read-only mounts, the mounts
below stay writable.

Other directories of containerd's `config_path` (for example
`/etc/docker/certs.d`) and CRI-O's `global_auth_file` need `extraVolumes` /
`extraVolumeMounts`.

## Network

The pods use the host network: the mirror listens on `127.0.0.1:7480`, the
status listener (`/livez`, `/readyz`, `/metrics`) on port 7482, the peer API
on port 7481 and the reflectors on port 7483, each a port of the node
(`config.toml` moves them). DNS is `ClusterFirst`, which on the host network
is the node's resolver: the agent, which CoreDNS pulls through, does not
depend on cluster DNS.

## Compatibility

The values schema is strict: unknown keys fail the install. A breaking change
to values bumps the chart MAJOR version; deprecations are announced one MINOR
version ahead. Requires Kubernetes 1.33 or later, containerd or CRI-O with NRI.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| spnngl |  | <https://github.com/spnngl> |

## Source Code

* <https://github.com/spnngl/charts>
* <https://github.com/spnngl/speculaire>
* <https://github.com/spnngl/images/tree/main/containers/speculaire>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| config.policy | string | `""` | Image policy (`policy.yaml`, at the default `verify.policy`). Empty: no file, so no policy. |
| config.source | string | `"configMap"` | Where the agent reads its config. `configMap`: the chart writes `toml`, `policy` and `trustedRoot` to a ConfigMap mounted as the directory `/etc/speculaire`. `host`: each node's own `/etc/speculaire` (read-only), and the three values below must stay empty. |
| config.toml | string | `""` | Agent config (`config.toml`), a TOML string: the agent's defaults apply to every key left out (`packaging/config.toml` in spnngl/speculaire lists them). A string, not a map, because Helm turns every number into a float. The reflectors get the same text after `role = "reflector"`, so `role` is chart-owned. Live keys reload within `config.poll_interval` after the kubelet syncs the ConfigMap (about a minute); restart keys need `kubectl rollout restart`. Set `reflector.url` for the agents to find their peers. |
| config.trustedRoot | string | `""` | Sigstore trusted root (`trusted_root.json`), a JSON string. Set it together with `verify.trusted_root = "/etc/speculaire/trusted_root.json"` in `toml`; empty: the agent fetches the public-good root over TUF. |
| extraVolumeMounts | list | `[]` | Extra volume mounts, for the agent and the `configure` init container. |
| extraVolumes | list | `[]` | Extra volumes, for both DaemonSets (for example a node directory of `containerd`'s `config_path` other than `/etc/containerd/certs.d`, or CRI-O's `global_auth_file`). |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). The DaemonSets add `-agent` and `-reflector`. |
| gate.tolerateAnnotation | string | `"speculaire.spnngl.github.io/tolerate-missing-plugins"` | Pod annotation that lets the runtime start the speculaire pods while the gate is down. Set the same key in the runtime's NRI validator: containerd `tolerate_missing_plugins_annotation` under `[plugins.'io.containerd.nri.v1.nri'.default_validator]`, CRI-O `nri_validator_tolerate_missing_plugins_annotation` under `[crio.nri.default_validator]`. Without it, a node whose runtime requires `speculaire` cannot restart the agent that serves the requirement. The chart sets it to `"true"` on both pods. |
| hostTrustStore.enabled | bool | `false` | Mount the node's CA trust store read-only over the image's own (Alpine's Mozilla bundle), as the systemd install reads it: a CA added on the node (a private registry's, a TLS-inspecting proxy's) is then trusted for upstream registries. The agent loads roots like OpenSSL: the first bundle file found (`/etc/ssl/certs/ca-certificates.crt` on Debian/Ubuntu, `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` on Fedora/RHEL) and every file of `/etc/ssl/certs` and `/etc/pki/tls/certs`. |
| hostTrustStore.paths | list | `["/etc/ssl/certs","/etc/pki/ca-trust/extracted"]` | Node directories mounted, each at the same path, when `enabled`. The default covers Debian/Ubuntu and Fedora/RHEL/Fedora CoreOS: there `/etc/ssl/certs` holds absolute symlinks into `/etc/pki/ca-trust/extracted`, which resolve inside the container, so that directory is mounted too (not all of `/etc/pki`: `tls/private` holds keys). A directory missing on the node is created empty (hostPath `DirectoryOrCreate`): keep only your layout's paths to avoid it. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/speculaire"` | Image repository, shared by the agents, the reflectors and the `configure` init container. |
| image.tag | string | `""` | Image tag. Empty: `appVersion` pinned by the digest recorded in `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/livez","port":"metrics"},"periodSeconds":10,"terminationGracePeriodSeconds":5}` | Liveness probe, `GET /livez`: the agent's watchdog (it answers while its event loop runs). A hung agent cannot drain, so the kubelet kills it after 5 s rather than `terminationGracePeriodSeconds`, and a new one runs within 40 s of the hang. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector, for both DaemonSets. Merged with the default `kubernetes.io/os: linux`: set that key to `null` to drop it. |
| podAnnotations | object | `{}` | Pod annotations, for both DaemonSets. |
| podLabels | object | `{}` | Extra pod labels, for both DaemonSets. |
| podSecurityContext | object | `{"runAsGroup":0,"runAsNonRoot":false,"runAsUser":0,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. Root is required: the agent writes runtime config owned by root and connects to root-only sockets. |
| priorityClassName | string | `"system-node-critical"` | Priority class name. The agent is a node component: without it, preemption can evict the agent the node's container starts depend on. |
| readinessProbe | object | `{"failureThreshold":1,"httpGet":{"path":"/readyz","port":"metrics"},"periodSeconds":5}` | Readiness probe, `GET /readyz`: ready once the gate and the mirror serve. It paces the rolling update. |
| reflector.image.digest | string | `""` | Reflector image digest, only valid together with `reflector.image.tag`. |
| reflector.image.tag | string | `""` | Reflector image tag on `image.repository`. Empty: the agents' image. An upgrade that changes the peer protocol sets this first, then `image.tag`: reflectors stay one minor ahead of the agents. |
| reflector.nodeLabel | string | `"node-role.kubernetes.io/control-plane"` | Node label (key only) of the nodes that run a reflector instead of an agent. A reflector is an agent with `role = "reflector"` (it gates and mirrors its own node too). Nodes labelled `speculaire.spnngl.github.io/disabled` run neither. |
| resources | object | `{"requests":{"cpu":"50m","memory":"128Mi"}}` | Resources, for the agent and the `configure` init container. No limit on purpose: an agent killed for memory blocks every container start on a node whose runtime requires `speculaire`. Like the other maps, `requests` merges with these defaults: set a key to `null` to drop it. |
| runtime | string | `"containerd"` | Container runtime of the nodes. It picks the node directories the pods mount (socket, runtime config, registry config, image store). Every node of the release runs the same runtime: install one release per runtime, split with `nodeSelector`. A wrong value fails the `configure` init container, which names both runtime sockets. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":0,"runAsNonRoot":false,"runAsUser":0,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context, for the agent and the `configure` init container. Overrides are merged onto these defaults. No capability: root's file ownership is enough. On SELinux nodes that deny the runtime sockets to containers, set `seLinuxOptions: {type: spc_t}`. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. The pods do not use the Kubernetes API: its token is not mounted. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| startupProbe | object | `{"failureThreshold":120,"httpGet":{"path":"/livez","port":"metrics"},"periodSeconds":1}` | Startup probe, `GET /livez` on the status listener (`metrics.address`, port 7482). Two minutes for the agent to load its cache and open its listeners. |
| terminationGracePeriodSeconds | int | `20` | Termination grace period. The agent drains its connections and exits within it. |
| tolerations | list | `[{"operator":"Exists"}]` | Tolerations, for both DaemonSets. Every taint by default: the agent gates every node's containers. |
| updateStrategy.rollingUpdate.maxUnavailable | int | `1` | Nodes updated at once. While its agent restarts, a node pulls without the mirror and, if its runtime requires `speculaire`, starts no container. |
| updateStrategy.type | string | `"RollingUpdate"` | DaemonSet update strategy, for both DaemonSets. There is no `maxSurge`: two agents on a node would compete for the host ports. |

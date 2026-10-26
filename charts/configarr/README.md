# configarr

Configarr as a hardened CronJob that syncs TRaSH-Guides profiles and settings as code into Sonarr, Radarr and Prowlarr

Runs [Configarr](https://github.com/raydak-labs/configarr) as a CronJob. Each
run reads one `config.yml`, clones or updates the
[TRaSH-Guides](https://github.com/TRaSH-Guides/Guides) and
[Recyclarr templates](https://github.com/recyclarr/config-templates)
repositories, syncs quality profiles, custom formats and settings into each
configured instance (Sonarr, then Radarr, then Prowlarr), and exits. The image
is built from [spnngl/images](https://github.com/spnngl/images): distroless,
non-root, no shell.

## Install

```sh
kubectl create namespace media
helm install configarr oci://ghcr.io/spnngl/charts/configarr --version <version> -n media \
  --set-file config=config.yml
```

The default `config` is `{}`: a run clones the repositories and syncs nothing.

## Configuration

`config` is the content of Configarr's
[`config.yml`](https://configarr.de/docs/configuration/config-file), as a
string. It is a string, not a map, because Helm would drop Configarr's YAML
tags (`!env`, `!secret`, `!file`) from a map. The chart copies it verbatim into
a ConfigMap and fails the install when it does not parse as a YAML mapping.

```yaml
config: |
  radarr:
    main:
      base_url: http://radarr.media.svc:7878
      api_key: !env RADARR_API_KEY
      quality_profiles: []
```

Settings as code: each run reverts what `config` manages, and deletes
unmanaged items (custom formats, quality profiles, tags) where a
`delete_unmanaged_*` key is on. Change these settings in `config`, not in the
Servarr UI.

The chart sets two variables:

- `STOP_ON_ERROR=true`: the run stops at the first instance that fails, and the
  Job fails. Upstream only logs the failure and exits 0. `extraEnv` cannot
  change it.
- `CONFIGARR_ENFORCE_CONFIG_VALIDATION=true`: an unknown key or a wrong type in
  `config` fails the run. Upstream only logs a warning, so a typo goes
  unnoticed. An `extraEnv` entry with this name replaces the chart's value.

Other upstream variables go in `extraEnv`: `LOG_LEVEL`, `LOG_FORMAT=json`,
`DRY_RUN=true` (log the changes without applying them),
`CONFIGARR_ENABLE_MERGE=true` (YAML `<<` merge keys), `TZ`.

## Secrets

Never write API keys in `config`: it is a ConfigMap. Two ways in:

- `!env NAME` reads an environment variable. Set it with `extraEnv` from a
  Secret. An unset or empty variable fails the run.

  ```yaml
  extraEnv:
    - name: RADARR_API_KEY
      valueFrom:
        secretKeyRef:
          name: radarr-api
          key: api-key
  ```

- `!secret NAME` reads a key of Configarr's `secrets.yml`. Store that file in
  a Secret and set `secrets.existingSecret.name` (and `key`, default
  `secrets.yml`). The chart mounts it at `/app/config/secrets.yml`, and fails
  the install when `config` uses `!secret` without it. A missing key resolves
  to nothing: the run fails on validation or on the API call.

  ```sh
  kubectl -n media create secret generic configarr-secrets --from-file=secrets.yml
  ```

`!file PATH` reads a file: mount it with `extraVolumes` and
`extraVolumeMounts`. The value keeps the file's trailing newline. The chart
never creates a Secret.

## Schedule and runs

`schedule` is a cron expression in the time zone of kube-controller-manager
(usually UTC), hourly by default. The CronJob is fixed:

- `concurrencyPolicy: Forbid`: one run at a time, one writer of the Servarr
  settings and of the repositories cache.
- `activeDeadlineSeconds: 600`: a run that takes longer than 10 minutes is
  killed, so a hung run cannot block every later one.
- `backoffLimit: 1` with `restartPolicy: Never`: one retry, in a new pod; the
  failed pod keeps its logs.
- `startingDeadlineSeconds: 600`: a run the controller missed by up to 10
  minutes still starts.
- History: the last successful Job and the last 3 failed ones.

A failed run is only a failed Job: alert on it. With kube-state-metrics,
`kube_job_status_failed{job_name=~"configarr-.*"} > 0` catches a failed run and
`time() - kube_cronjob_status_last_successful_time{cronjob="configarr"}` the time
since the last success.

Run a sync now and follow it:

```sh
JOB=configarr-manual-$(date +%s)
kubectl -n media create job --from=cronjob/configarr "$JOB"
kubectl -n media logs -f "job/$JOB"
```

A Job created by hand ignores `concurrencyPolicy`: do not start one while a
scheduled run is active. Pause the schedule with
`kubectl -n media patch cronjob configarr -p '{"spec":{"suspend":true}}'`
(the next `helm upgrade` resumes it).

## Storage

- `/app/config`: a read-only projected volume with `config.yml` and, when set,
  `secrets.yml`. Each run is a new pod: it reads the current ConfigMap and
  Secret, no restart needed.
- `/app/repos`: the TRaSH-Guides and Recyclarr clones, sparse by default
  (about 11 MB; `enableFullGitClone: true` in `config` clones everything). An
  `emptyDir` by default: each run clones again. `persistence.repos.enabled:
  true` keeps them in a PVC between runs, so a run only pulls. The chart's PVC
  is a cache: `helm uninstall` deletes it. `existingClaim` uses yours. Turning
  it off leaves the PVC `Terminating` until the finished Job pods that mount
  it are gone: delete those Jobs.

Nothing else is writable: Configarr writes no temporary files.

Local custom formats and templates (`localCustomFormatsPath`,
`localConfigTemplatesPath`, conventionally `/app/cfs` and `/app/templates`) go
in `extraVolumes` and `extraVolumeMounts`.

## Image

The default image is `appVersion`, pinned by the digest recorded in the
`artifacthub.io/images` annotation of `Chart.yaml` (Renovate updates tag and
digest together). Setting `image.tag` drops that digest; add `image.digest` to pin
the tag again (a digest without a tag is an error).

The image is signed with cosign (keyless, GitHub Actions OIDC) and carries SLSA
provenance. See the repository README, "Verifying what you install".

## Security

Defaults satisfy the `restricted` Pod Security Standard: non-root uid/gid 65532,
read-only root filesystem (writes go to `/app/repos` only), all
capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp, no
ServiceAccount token, no Service environment variables.

### User namespaces

`hostUsers: false` (default) runs the pod in a user namespace: uid 65532 in the
pod maps to an unprivileged host uid, which limits what a container escape
gains. Nodes need a container runtime with user namespace support (containerd
2.0+ or CRI-O), runc 1.2+ or crun, and a Linux kernel 6.3+. On other nodes the
pod sandbox cannot be created: set `hostUsers: true`. Volumes without idmapped
mounts (NFS, SMB) need it too.

## Network

- The NetworkPolicy (`networkPolicy.enabled`, on by default) denies all
  ingress: the pod has no port.
- `networkPolicy.egress.enabled` (off by default) allows DNS, `peers.to` (the
  internet except private, CGNAT and link-local ranges: GitHub, so a
  compromised process cannot move sideways) and `extraEgress`. Add
  `extraEgress` rules for Sonarr, Radarr and Prowlarr: they sit in a private
  range.

Configarr sends no telemetry unless `telemetry: true` in `config` or
`TELEMETRY_ENABLED`.

## Compatibility

The values schema is strict: unknown keys fail the install. A breaking change to
values bumps the chart MAJOR version; deprecations are announced one MINOR
version ahead. Requires Kubernetes 1.33 or later.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| spnngl |  | <https://github.com/spnngl> |

## Source Code

* <https://github.com/spnngl/charts>
* <https://github.com/raydak-labs/configarr>
* <https://github.com/spnngl/images>

## Requirements

Kubernetes: `>=1.33.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| config | string | `"{}"` | Configarr's `config.yml`, as a string: Configarr's `!env`, `!secret` and `!file` tags would be dropped silently in a values map. Copied verbatim into a ConfigMap; the chart checks that it parses as a YAML mapping. The default `{}` syncs nothing. Never write API keys here: use `!env` with `extraEnv`, or `!secret` with `secrets.existingSecret`. |
| dnsConfig | object | `{"options":[{"name":"ndots","value":"2"}]}` | DNS config. |
| dnsConfig.options | list | `[{"name":"ndots","value":"2"}]` | DNS options (fewer search-list lookups for external host names such as github.com; Service names need their namespace or FQDN). |
| extraEnv | list | `[]` | Extra environment variables (`EnvVar` list) for the Configarr container: the variables `!env` tags read (API keys from a Secret by `secretKeyRef`), `LOG_LEVEL`, `LOG_FORMAT`, `DRY_RUN`, `CONFIGARR_ENABLE_MERGE`, `TZ`. `CONFIGARR_ENFORCE_CONFIG_VALIDATION` (the chart sets `true`: a typo in `config` fails the run) is overridden by this list. Names the chart sets are rejected: `STOP_ON_ERROR`, `CONFIG_LOCATION`, `SECRETS_LOCATION`, `ROOT_PATH`, `CUSTOM_REPO_ROOT`. Names are case-sensitive. |
| extraInitContainers | list | `[]` | Extra init containers, rendered as given. The Configarr image has no shell: use another image. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Configarr container. |
| extraVolumes | list | `[]` | Extra volumes: local custom formats and templates (`localCustomFormatsPath`, `localConfigTemplatesPath`, conventionally `/app/cfs` and `/app/templates`), files read by `!file`. |
| fullnameOverride | string | `""` | Override the full resource name (default `<release>-<chart>`). |
| hostUsers | bool | `false` | Run the pod in a user namespace (`false`: uid 65532 maps to an unprivileged host uid). Needs node support (containerd 2.0+ or CRI-O, runc 1.2+, kernel 6.3+) and idmapped mounts on every volume's file system (not NFS/SMB); pods fail to start otherwise. `true` uses host users. |
| image.digest | string | `""` | Image digest, only valid together with `image.tag`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/spnngl/images/configarr"` | Image repository. |
| image.tag | string | `""` | Image tag. Empty: the tag and digest recorded for `image.repository` in the `artifacthub.io/images` annotation of `Chart.yaml`. When set, the chart digest is not applied; add `image.digest` to pin it. |
| imagePullSecrets | list | `[]` | Image pull secrets (list of `{name: <secret>}`). |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.egress.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | DNS peers (port 53 TCP/UDP). Override for NodeLocal DNSCache or non-standard labels. |
| networkPolicy.egress.enabled | bool | `false` | Restrict egress (DNS, GitHub for the TRaSH-Guides and Recyclarr repositories, `extraEgress`). |
| networkPolicy.egress.extraEgress | list | `[]` | Extra `NetworkPolicyEgressRule`s: Sonarr, Radarr and Prowlarr (they are in the private ranges `peers` excludes). |
| networkPolicy.egress.peers.to | list | `[{"ipBlock":{"cidr":"0.0.0.0/0","except":["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16"]}},{"ipBlock":{"cidr":"::/0","except":["fc00::/7","fe80::/10"]}}]` | GitHub and other internet hosts (any port). Default: the internet, not the private, CGNAT and link-local ranges, so a compromised process cannot move sideways. |
| networkPolicy.enabled | bool | `true` | Create a NetworkPolicy. Ingress: none (the pod has no port). |
| nodeSelector | object | `{"kubernetes.io/os":"linux"}` | Node selector. |
| persistence.repos.accessModes | list | `["ReadWriteOnce"]` | Access modes of the chart's PVC. `ReadWriteOnce` is enough: `concurrencyPolicy: Forbid` runs one Job at a time. |
| persistence.repos.enabled | bool | `false` | Keep the TRaSH-Guides and Recyclarr clones (`/app/repos`) in a PersistentVolumeClaim between runs. `false`: an `emptyDir`, each run clones again. |
| persistence.repos.existingClaim | string | `""` | Existing PVC to use when `enabled`. Empty: the chart creates one (deleted on uninstall: it is a cache). |
| persistence.repos.size | string | `"1Gi"` | Size of the chart's PVC. |
| persistence.repos.storageClassName | string | `""` | StorageClass of the chart's PVC. Empty: the cluster default. |
| podAnnotations | object | `{}` | Pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Overrides are merged onto these defaults. |
| priorityClassName | string | `""` | Priority class name. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"50m","memory":"128Mi"}}` | Resources of the Configarr container. No CPU limit on purpose. |
| schedule | string | `"0 * * * *"` | Cron schedule of the sync, in the time zone of kube-controller-manager (usually UTC). Each run reverts what `config` manages. |
| secrets.existingSecret.key | string | `"secrets.yml"` | Key of the Secret holding the `secrets.yml` content. |
| secrets.existingSecret.name | string | `""` | Secret holding Configarr's `secrets.yml` (the values of `!secret` tags), mounted at `/app/config/secrets.yml`. Empty: none, and a `!secret` tag in `config` fails the install. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"privileged":false,"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context of the Configarr container (read-only root filesystem: it writes only to the `/app/repos` volume). Overrides are merged onto these defaults. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create the ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: `<fullname>` (or `default` when `create` is false). |
| tolerations | list | `[]` | Tolerations. |

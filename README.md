# spnngl/charts

Public Helm charts, published as OCI artifacts on GHCR, signed with cosign,
with SBOM and provenance attestations, listed on
[Artifact Hub](https://artifacthub.io/packages/search?user=lola.2lannoy).

Two kinds of charts live here:

- **CRD charts** (`*-crds`): the CustomResourceDefinitions of an upstream
  project, packaged on their own so you can install and upgrade CRDs
  independently from the operator. They are generated and kept in sync with
  upstream automatically — no human edits, no lag.
- **Application charts**: hand-written charts maintained in this repo.

## Charts

| Chart | Upstream | Contents |
|-------|----------|----------|
| [`external-dns-crds`](./charts/external-dns-crds) | [kubernetes-sigs/external-dns](https://github.com/kubernetes-sigs/external-dns) | DNSEndpoint, DNSRecord |
| [`external-secrets-crds`](./charts/external-secrets-crds) | [external-secrets/external-secrets](https://github.com/external-secrets/external-secrets) | stores, (Cluster)ExternalSecret, (Cluster)PushSecret, generators |
| [`gateway-api-crds`](./charts/gateway-api-crds) | [kubernetes-sigs/gateway-api](https://github.com/kubernetes-sigs/gateway-api) | standard channel |
| [`gateway-api-exp-crds`](./charts/gateway-api-exp-crds) | [kubernetes-sigs/gateway-api](https://github.com/kubernetes-sigs/gateway-api) | experimental channel (mutually exclusive with the standard chart) |
| [`agentgateway-crds`](./charts/agentgateway-crds) | [agentgateway/agentgateway](https://github.com/agentgateway/agentgateway) | backends, models, parameters, policies |
| [`argo-cd-crds`](./charts/argo-cd-crds) | [argoproj/argo-cd](https://github.com/argoproj/argo-cd) | Application, ApplicationSet, AppProject |
| [`cert-manager-crds`](./charts/cert-manager-crds) | [cert-manager/cert-manager](https://github.com/cert-manager/cert-manager) | certificates, (Cluster)Issuer, ACME orders and challenges |
| [`chaos-mesh-crds`](./charts/chaos-mesh-crds) | [chaos-mesh/chaos-mesh](https://github.com/chaos-mesh/chaos-mesh) | chaos experiments, schedules, workflows |
| [`cilium-crds`](./charts/cilium-crds) | [cilium/cilium](https://github.com/cilium/cilium) | cilium.io v2 + v2alpha1 |
| [`cluster-api-crds`](./charts/cluster-api-crds) | [kubernetes-sigs/cluster-api](https://github.com/kubernetes-sigs/cluster-api) | core CRDs (clusters, machines, ClusterClass, IPAM, runtime) |
| [`kyverno-api-crds`](./charts/kyverno-api-crds) | [kyverno/kyverno](https://github.com/kyverno/kyverno) | CEL policies and exceptions (policies.kyverno.io) |
| [`kyverno-crds`](./charts/kyverno-crds) | [kyverno/kyverno](https://github.com/kyverno/kyverno) | kyverno.io policies and exceptions, reports, wgpolicyk8s.io policy reports |
| [`orc-crds`](./charts/orc-crds) | [k-orc/openstack-resource-controller](https://github.com/k-orc/openstack-resource-controller) | OpenStack resources |
| [`topolvm-crds`](./charts/topolvm-crds) | [topolvm/topolvm](https://github.com/topolvm/topolvm) | LogicalVolume |
| [`traefik-crds`](./charts/traefik-crds) | [traefik/traefik](https://github.com/traefik/traefik) | traefik.io (IngressRoutes, Middlewares, TLS options, transports) |
| [`velero-crds`](./charts/velero-crds) | [vmware-tanzu/velero](https://github.com/vmware-tanzu/velero) | backups, restores, schedules, locations, data movers |
| [`vertical-pod-autoscaler-crds`](./charts/vertical-pod-autoscaler-crds) | [kubernetes/autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) | VerticalPodAutoscaler, VerticalPodAutoscalerCheckpoint |

Each chart README lists the exact CRDs, versions and the pinned upstream tag/commit.
Versions follow upstream (`gateway-api-crds 1.6.2` ships gateway-api `v1.6.2`).

## Usage

```sh
helm install <release> oci://ghcr.io/spnngl/charts/<chart> --version <version> -n <namespace>
```

Browse versions: `https://github.com/spnngl/charts/pkgs/container/charts%2F<chart>`
or the chart's Artifact Hub page.

### CRD charts

- CRDs are regular templates, so `helm upgrade` updates them (unlike Helm's
  `crds/` directory).
- Chart `version` equals the upstream version (e.g. `gateway-api-crds 1.6.2`
  ships gateway-api `v1.6.2` CRDs). If the chart had to be rebuilt without an
  upstream change, the patch number is one higher; `appVersion` always tells
  you the exact upstream version.
- Values (same for every CRD chart):

  | Key | Default | Meaning |
  |-----|---------|---------|
  | `annotations` | `{}` | extra annotations on every CRD |
  | `labels` | `{}` | extra labels on every CRD |
  | `keepOnUninstall` | `true` | keep CRDs (and therefore all their custom resources) on `helm uninstall` |

- Already have the CRDs installed (by the operator chart or `kubectl apply`)?
  Adopt them instead of failing with "resource already exists":

  ```sh
  helm install <release> oci://ghcr.io/spnngl/charts/<chart> --version <version> --take-ownership   # Helm >= 3.17
  ```

  Each chart README contains the exact `kubectl annotate`/`kubectl label`
  commands for older Helm versions.
- `gateway-api-crds` (standard channel) and `gateway-api-exp-crds`
  (experimental channel) define the same CRD names and cannot be installed
  together.
- `kyverno-crds` up to 1.19.1 also shipped the policies.kyverno.io CRDs; they
  moved to `kyverno-api-crds` so each release fits Helm's 1 MiB release Secret
  (mirroring upstream's `crds` and `kyverno-api` subcharts). Upgrading
  `kyverno-crds` removes them from its release, and Helm deletes them (and
  every CEL policy) unless they carry `helm.sh/resource-policy: keep`:

  ```sh
  # only if you set keepOnUninstall=false: re-add the keep annotation first
  helm upgrade <release> oci://ghcr.io/spnngl/charts/kyverno-crds --version 1.19.1 --reuse-values --set keepOnUninstall=true
  helm upgrade <release> oci://ghcr.io/spnngl/charts/kyverno-crds --version <version> --reuse-values
  helm install <release>-api oci://ghcr.io/spnngl/charts/kyverno-api-crds --version <version> --take-ownership   # Helm >= 3.17
  ```

## Verifying what you install

Every chart version is signed with cosign keyless (Sigstore): the signing
certificate is issued by Fulcio to this repository's `release.yml` workflow
through GitHub Actions OIDC, and the signature is logged in Rekor. No
long-lived key exists. Each version also carries SBOM and SLSA provenance
attestations.

```sh
REF=ghcr.io/spnngl/charts/<chart>:<version>

# signature
cosign verify \
  --certificate-identity-regexp '^https://github\.com/spnngl/charts/\.github/workflows/release\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  $REF

# SBOM attestation (cosign, keyless)
cosign verify-attestation --type spdxjson \
  --certificate-identity-regexp '^https://github\.com/spnngl/charts/\.github/workflows/release\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  $REF

# build provenance (GitHub artifact attestations, Sigstore)
gh attestation verify oci://$REF --owner spnngl
```

Versions published before the switch to keyless were signed with the retired
key [`cosign.pub`](./cosign.pub); see [`SECURITY.md`](./SECURITY.md#previous-keys).

## How CRD charts are built

`sources/<chart>.yaml` declares where an upstream keeps its CRDs (a directory
of files, a bundled manifest, a kustomize base, a Helm chart, a release
asset — every project does it differently). A generator fetches the pinned
upstream tag, extracts only `CustomResourceDefinition` objects, strips
build noise, adds Helm labels, and writes the chart. A scheduled workflow
checks upstream tags daily, regenerates, and merges automatically once CI
(lint, schema validation, install and upgrade in a real cluster) passes.
Details in [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Contributing

- Want a CRD chart for another project? Open an issue with the upstream
  repo and where its CRDs live, or send a PR adding `sources/<name>-crds.yaml`
  (see `CONTRIBUTING.md`).
- Do not edit `charts/*-crds/` directly; those files are generated.

## Licensing

This repository is licensed under [Apache-2.0](./LICENSE). CRD charts
redistribute upstream CRD manifests under the upstream project's license,
included verbatim in each chart (`LICENSE`, `NOTICE`), with attribution in
the chart README. See [`NOTICE`](./NOTICE) for the list of upstream
projects.

## Security

See [`SECURITY.md`](./SECURITY.md).

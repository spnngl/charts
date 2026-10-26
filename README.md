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
| [`artifacthub-exporter`](./charts/artifacthub-exporter) | [spnngl/artifacthub-exporter](https://github.com/spnngl/artifacthub-exporter) | Artifact Hub package and repository metrics exporter Deployment (ServiceMonitor/PodMonitor/PrometheusRule, VPA) |
| [`cinny`](./charts/cinny) | [cinnyapp/cinny](https://github.com/cinnyapp/cinny) | Matrix web client Deployment (Ingress/HTTPRoute, NetworkPolicy, HPA/PDB, VPA, ServiceMonitor/PodMonitor) |
| [`cloudflared`](./charts/cloudflared) | [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) | Cloudflare Tunnel connector Deployment (HPA, VPA, ServiceMonitor/PodMonitor) |
| [`cryptgeon`](./charts/cryptgeon) | [cupcakearmy/cryptgeon](https://github.com/cupcakearmy/cryptgeon) | Encrypted self-destructing notes Deployment, external Redis (Ingress/HTTPRoute, NetworkPolicy, VPA) |
| [`cs-firewall-bouncer`](./charts/cs-firewall-bouncer) | [crowdsecurity/cs-firewall-bouncer](https://github.com/crowdsecurity/cs-firewall-bouncer) | CrowdSec firewall bouncer DaemonSet (nftables, PodMonitor/PrometheusRule) |
| [`ghcr-exporter`](./charts/ghcr-exporter) | [d0ugal/ghcr-exporter](https://github.com/d0ugal/ghcr-exporter) | GHCR package metrics exporter Deployment (ServiceMonitor/PodMonitor/PrometheusRule) |
| [`github-exporter`](./charts/github-exporter) | [d0ugal/github-exporter](https://github.com/d0ugal/github-exporter) | GitHub repository and build status exporter Deployment (ServiceMonitor/PodMonitor/PrometheusRule, VPA) |
| [`mailpit`](./charts/mailpit) | [axllent/mailpit](https://github.com/axllent/mailpit) | SMTP testing server with web UI Deployment, emptyDir or PVC storage, Secret-mounted auth/TLS/relay (Ingress/HTTPRoute, NetworkPolicy, ServiceMonitor/PodMonitor/PrometheusRule, VPA) |
| [`mjolnir`](./charts/mjolnir) | [matrix-org/mjolnir](https://github.com/matrix-org/mjolnir) | Matrix moderation bot StatefulSet, Secret-mounted credentials, optional web API (NetworkPolicy, ServiceMonitor/PodMonitor/PrometheusRule, VPA) |
| [`nftables-exporter`](./charts/nftables-exporter) | [metal-stack/nftables-exporter](https://github.com/metal-stack/nftables-exporter) | nftables ruleset exporter DaemonSet (counters, chains, rules; PodMonitor/PrometheusRule) |
| [`numa-dns`](./charts/numa-dns) | [razvandimescu/numa](https://github.com/razvandimescu/numa) | DNS forwarder with caching and ad blocking Deployment (DoT/DoH through Ingress, NetworkPolicy, PDB, HPA, VPA) |
| [`sable-next`](./charts/sable-next) | [SableClient/sable-next](https://github.com/SableClient/sable-next) | Matrix web client Deployment on static-web-server, config.json from values (Ingress/HTTPRoute, NetworkPolicy, PDB, VPA) |
| [`transmission`](./charts/transmission) | [transmission/transmission](https://github.com/transmission/transmission) | BitTorrent daemon and web UI StatefulSet (Ingress/HTTPRoute, peer hostPort/Service/TCPRoute/UDPRoute, exporter sidecar, ServiceMonitor/PodMonitor/PrometheusRule, VPA) |
| [`tuwunel`](./charts/tuwunel) | [matrix-construct/tuwunel](https://github.com/matrix-construct/tuwunel) | Matrix homeserver StatefulSet, optional Cinny web client, optional LiveKit and lk-jwt-service for calls (Ingress/HTTPRoute with `.well-known` delegation, NetworkPolicy, VPA) |
| [`agent-router-crds`](./charts/agent-router-crds) | [theagentrouter/agent-router](https://github.com/theagentrouter/agent-router) | AIGatewayRoute, AIServiceBackend, MCPRoute, policies |
| [`agent-substrate-crds`](./charts/agent-substrate-crds) | [agent-substrate/substrate](https://github.com/agent-substrate/substrate) | SandboxConfig, WorkerPool, CSIDriverConfig |
| [`agentgateway-crds`](./charts/agentgateway-crds) | [agentgateway/agentgateway](https://github.com/agentgateway/agentgateway) | backends, models, parameters, policies |
| [`argo-cd-crds`](./charts/argo-cd-crds) | [argoproj/argo-cd](https://github.com/argoproj/argo-cd) | Application, ApplicationSet, AppProject |
| [`cert-manager-crds`](./charts/cert-manager-crds) | [cert-manager/cert-manager](https://github.com/cert-manager/cert-manager) | certificates, (Cluster)Issuer, ACME orders and challenges |
| [`chaos-mesh-crds`](./charts/chaos-mesh-crds) | [chaos-mesh/chaos-mesh](https://github.com/chaos-mesh/chaos-mesh) | chaos experiments, schedules, workflows |
| [`cilium-crds`](./charts/cilium-crds) | [cilium/cilium](https://github.com/cilium/cilium) | cilium.io v2 + v2alpha1 |
| [`cloudnative-pg-crds`](./charts/cloudnative-pg-crds) | [cloudnative-pg/cloudnative-pg](https://github.com/cloudnative-pg/cloudnative-pg) | PostgreSQL clusters, backups, poolers, databases |
| [`cluster-api-crds`](./charts/cluster-api-crds) | [kubernetes-sigs/cluster-api](https://github.com/kubernetes-sigs/cluster-api) | core CRDs (clusters, machines, ClusterClass, IPAM, runtime) |
| [`external-dns-crds`](./charts/external-dns-crds) | [kubernetes-sigs/external-dns](https://github.com/kubernetes-sigs/external-dns) | DNSEndpoint, DNSRecord |
| [`external-snapshotter-crds`](./charts/external-snapshotter-crds) | [kubernetes-csi/external-snapshotter](https://github.com/kubernetes-csi/external-snapshotter) | VolumeSnapshot, VolumeGroupSnapshot (+ classes and contents) |
| [`external-secrets-crds`](./charts/external-secrets-crds) | [external-secrets/external-secrets](https://github.com/external-secrets/external-secrets) | stores, (Cluster)ExternalSecret, (Cluster)PushSecret, generators |
| [`flux-crds`](./charts/flux-crds) | [fluxcd/flux2](https://github.com/fluxcd/flux2) | all controllers: sources, Kustomization, HelmRelease, notifications, image automation, ArtifactGenerator |
| [`gateway-api-crds`](./charts/gateway-api-crds) | [kubernetes-sigs/gateway-api](https://github.com/kubernetes-sigs/gateway-api) | standard channel |
| [`gateway-api-exp-crds`](./charts/gateway-api-exp-crds) | [kubernetes-sigs/gateway-api](https://github.com/kubernetes-sigs/gateway-api) | experimental channel (mutually exclusive with the standard chart) |
| [`kagent-crds`](./charts/kagent-crds) | [kagent-dev/kagent](https://github.com/kagent-dev/kagent) | agents, model configs, memories, tool and MCP servers |
| [`kargo-crds`](./charts/kargo-crds) | [akuity/kargo](https://github.com/akuity/kargo) | Projects, Warehouses, Freight, Stages, Promotions, PromotionTasks |
| [`kmcp-crds`](./charts/kmcp-crds) | [kagent-dev/kmcp](https://github.com/kagent-dev/kmcp) | MCPServer (used by kagent) |
| [`kubemod-crds`](./charts/kubemod-crds) | [kubemod/kubemod](https://github.com/kubemod/kubemod) | ModRule |
| [`kyverno-crds`](./charts/kyverno-crds) | [kyverno/kyverno](https://github.com/kyverno/kyverno) | kyverno.io and CEL (policies.kyverno.io) policies, exceptions, policy reports (schema docs stripped, see below) |
| [`orc-crds`](./charts/orc-crds) | [k-orc/openstack-resource-controller](https://github.com/k-orc/openstack-resource-controller) | OpenStack resources |
| [`topolvm-crds`](./charts/topolvm-crds) | [topolvm/topolvm](https://github.com/topolvm/topolvm) | LogicalVolume |
| [`traefik-crds`](./charts/traefik-crds) | [traefik/traefik](https://github.com/traefik/traefik) | traefik.io (IngressRoutes, Middlewares, TLS options, transports) |
| [`trivy-operator-crds`](./charts/trivy-operator-crds) | [aquasecurity/trivy-operator](https://github.com/aquasecurity/trivy-operator) | security reports (vulnerability, config audit, RBAC, infra, exposed secrets, SBOM, compliance) |
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
- `kyverno-crds` ships its CRDs without field-level schema documentation
  (descriptions, titles, examples): with it, the release exceeds Helm's default release
  storage (one Secret, 1 MiB). Validation is unchanged; `kubectl explain`
  shows field types only.
- `flux-crds` is for Flux installs that leave CRDs alone. `flux install`,
  `flux bootstrap` and the Flux Operator apply their own CRDs: do not combine
  them with this chart. Its CRDs carry `app.kubernetes.io/part-of: flux`, which
  `flux check` needs, so `flux uninstall` deletes them too.

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
checks upstream tags every 6 hours, regenerates, and merges automatically once CI
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

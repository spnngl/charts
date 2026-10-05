# Security

## Verifying artifacts

Every chart version published to `oci://ghcr.io/spnngl/charts/<chart>` is:

- signed with cosign using the key whose public half is [`cosign.pub`](./cosign.pub);
- accompanied by an SPDX SBOM, attested with the same key (`cosign attest --type spdxjson`);
- accompanied by SLSA build provenance and an SBOM attestation issued by GitHub
  (`actions/attest-build-provenance`, `actions/attest-sbom`), bound to the
  `release.yml` workflow identity of this repository.

```sh
REF=ghcr.io/spnngl/charts/<chart>:<version>
cosign verify --key https://raw.githubusercontent.com/spnngl/charts/main/cosign.pub $REF
cosign verify-attestation --key https://raw.githubusercontent.com/spnngl/charts/main/cosign.pub --type spdxjson $REF
gh attestation verify oci://$REF --owner spnngl
```

Published versions are immutable: a version is never re-pushed or deleted. If a
problem is found, a new version is published.

## What the CRD charts contain

CRD charts contain `CustomResourceDefinition` objects copied from the upstream
project at a pinned tag (the exact commit is recorded in each chart's
`Chart.yaml` annotation `charts.spnngl.io/upstream-commit`, `NOTICE` and
README), plus Helm labels/annotations. No workloads, RBAC, webhooks or other
resources. The generator refuses to publish a chart with zero CRDs.

## Reporting a vulnerability

- **In the upstream CRDs themselves**: report to the upstream project; this
  repository redistributes them unchanged apart from Helm metadata.
- **In this repository** (generator, workflows, signing, publishing): open a
  private report via GitHub Security Advisories on this repository, or email
  the maintainer listed in the GitHub profile of `spnngl`. Please do not open a
  public issue for suspected key compromise.

Expect an acknowledgement within a week. If the signing key is compromised, a
new `cosign.pub` is committed, all charts are republished with a bumped patch
version, and the previous key is listed as revoked in the README.

## Previous keys

None.

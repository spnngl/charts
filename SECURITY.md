# Security

## Verifying artifacts

Every chart version published to `oci://ghcr.io/spnngl/charts/<chart>` is:

- signed with cosign keyless (Sigstore): the short-lived signing certificate is
  issued by Fulcio to the `release.yml` workflow of this repository through
  GitHub Actions OIDC, and the signature is recorded in the Rekor transparency
  log. There is no long-lived signing key;
- accompanied by an SPDX SBOM, attested the same way (`cosign attest --type spdxjson`);
- accompanied by SLSA build provenance and an SBOM attestation issued by GitHub
  (`actions/attest`, provenance and SBOM modes), bound to the
  `release.yml` workflow identity of this repository.

```sh
REF=ghcr.io/spnngl/charts/<chart>:<version>
cosign verify \
  --certificate-identity-regexp '^https://github\.com/spnngl/charts/\.github/workflows/release\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  $REF
cosign verify-attestation --type spdxjson \
  --certificate-identity-regexp '^https://github\.com/spnngl/charts/\.github/workflows/release\.yml@' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  $REF
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
  public issue for a suspected compromise of the release workflow.

Expect an acknowledgement within a week. Signing identity is the release
workflow itself, so a compromise means a malicious `release.yml` run on this
repository: affected versions (found through the Rekor log) are listed in the
advisory and superseded by new versions built from a clean commit.

## Previous keys

- [`cosign.pub`](./cosign.pub): key-based signing, retired when releases moved
  to keyless signing. Not compromised; only valid for versions published
  before the switch:

  ```sh
  cosign verify --key https://raw.githubusercontent.com/spnngl/charts/main/cosign.pub $REF
  ```

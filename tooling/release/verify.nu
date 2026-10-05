#!/usr/bin/env nu
# Post-publish smoke test: run exactly the verification commands documented in
# the chart READMEs against the published artifact. Needs no secrets.
#   nu tooling/release/verify.nu <chart-name> <version>

use ../crdgen/config.nu [OCI_BASE OCI_HOST_PATH OWNER COSIGN_IDENTITY_REGEXP COSIGN_OIDC_ISSUER]

def step [what: string, cmd: closure] {
  print $"--> ($what)"
  let out = (do $cmd | complete)
  if $out.exit_code != 0 {
    error make {msg: $"($what) failed:\n($out.stdout)\n($out.stderr)"}
  }
  if not ($out.stdout | str trim | is-empty) { print $out.stdout }
}

def main [chart: string, version: string]: nothing -> nothing {
  let id = [--certificate-identity-regexp $COSIGN_IDENTITY_REGEXP --certificate-oidc-issuer $COSIGN_OIDC_ISSUER]
  let ref = $"($OCI_HOST_PATH)/($chart):($version)"
  let dir = (mktemp -d -t verify.XXXXXX)

  step $"helm pull ($OCI_BASE)/($chart) ($version)" { ^helm pull $"($OCI_BASE)/($chart)" --version $version -d $dir }
  step "chart renders" { ^helm template smoke ($dir | path join $"($chart)-($version).tgz") }
  step "cosign verify (keyless)" { ^cosign verify ...$id $ref }
  step "cosign verify-attestation (SBOM, keyless)" { ^cosign verify-attestation ...$id --type spdxjson $ref }
  step "gh attestation verify (provenance)" { ^gh attestation verify $"oci://($ref)" --owner $OWNER }
  step "gh attestation verify (SBOM)" { ^gh attestation verify $"oci://($ref)" --owner $OWNER --predicate-type https://spdx.dev/Document/v2.3 }
  print $"OK ($ref)"
}

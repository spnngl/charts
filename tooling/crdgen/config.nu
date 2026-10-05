# Repository-wide constants. Everything that identifies *this* repo lives here.

export const REPO_URL = "https://github.com/spnngl/charts"
export const REPO_SLUG = "spnngl/charts"
export const OWNER = "spnngl"
export const OCI_BASE = "oci://ghcr.io/spnngl/charts"
export const OCI_HOST_PATH = "ghcr.io/spnngl/charts"
export const COSIGN_PUB_URL = "https://raw.githubusercontent.com/spnngl/charts/main/cosign.pub"
export const ANNOTATION_PREFIX = "charts.spnngl.io"

# Licenses the generator accepts without a human decision (SPDX ids).
export const LICENSE_ALLOWLIST = ["Apache-2.0" "MIT" "BSD-2-Clause" "BSD-3-Clause"]
export const SOURCE_KINDS = ["git-path" "kustomize" "helm-template" "release-asset"]
export const ALLOW_VALUES = ["all" "minor" "patch"]

# Labels/annotations injected by the chart template; stripped from upstream
# input (sanitize) and from rendered output before round-trip comparison (validate).
export const INJECTED_LABEL_PATTERNS = [
  '^helm\.sh/'
  '^meta\.helm\.sh/'
  '^app\.kubernetes\.io/(managed-by|instance|version|name)$'
]
export const INJECTED_ANNOTATION_PATTERNS = [
  '^helm\.sh/'
  '^meta\.helm\.sh/'
]

# Helm stores the release (chart files base64-encoded inside JSON + rendered manifest)
# gzipped then base64-encoded in one Secret; Kubernetes caps Secret data at 1 MiB.
export const SIZE_BUDGET_FAIL = 1_000_000
export const SIZE_BUDGET_WARN = 800_000
